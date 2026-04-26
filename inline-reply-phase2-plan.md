# Inline Text Reply for Stop Events — Implementation Plan

Closes #36 (Phase 2 of #20). Branch: `feat/inline-reply-phase2`.

Pre-requisite: PR #38 (#35 audit). Plan assumes #38 is merged so the
test count baseline is current + new tests below.

## Goals

- Render an inline `TextField + Send` in expanded Stop reminders so the
  user can reply with free-form text without leaving the island.
- Cover the case Phase 1 (#29) skipped: questions that don't match any
  yes/no pattern.

## Non-goals

- Multi-line / shift+Enter newline.
- Wider pattern recognition (numbered options, multi-select).
- Settings UI (#11). UserDefaults flag with a `TODO(settings)` marker
  so #11 picks it up.
- Server long-poll timeout parameterization. The existing 25 s server
  timeout vs 30 s quick-reply UI horizon mismatch is pre-existing and
  out of scope; **#36 reuses the same 25 s horizon**, does not widen
  the mismatch.

## Two-flag staged rollout — single source of truth

App-flag-off + hook always emitting `freeform_replyable: true` would
make every free-form Stop hang 25 s before falling back. To avoid
that regression, both sides gate from the **same** UserDefaults flag.

| Layer | What it controls | How it reads the flag |
|------|------------------|------------------------|
| Hook | Whether to emit `freeform_replyable: true` and long-poll | Env var `CC_ISLAND_INLINE_REPLY=1`, set in the hook command line by `HookInstaller` when the UserDefault is true |
| App  | Whether to render `InlineReplyField` | `@AppStorage("enableInlineReply")` |

**Single user-facing toggle:**

```bash
defaults write com.bistin.dynamic-island enableInlineReply -bool true
# Then via menu: Reinstall Claude Code Hooks  ← required, see below
```

The `defaults write` flips:
- App side **immediately** (`@AppStorage` is reactive).
- Hook side **only** after the user reinstalls hooks. The hook
  command in `~/.claude/settings.json` doesn't auto-update on a
  `defaults write` — `syncIfOutdated` runs on launch, but the user
  is changing flags while the app is already running. Without
  reinstall, the App renders a TextField that fires into nothing on
  the hook side.

When we ship default-on, both gates removed in the same PR.

## Architecture

### Hook side

- `HookPlan` gains `inlineReplyEnabled: Bool`, derived from
  `env["CC_ISLAND_INLINE_REPLY"] == "1"` in `parseHookPlan`.
- `PayloadBuilder.buildStopPayload`: when `containsQuestion(lastMsg)`
  is true and `extractYesNoOptions` returns nil **and**
  `plan.inlineReplyEnabled` is true, emit
  `freeform_replyable: true, persistent: true`.
- `island-hook/main.swift` Stop case: long-poll when *either*
  `quick_replies` is set *or* `freeform_replyable: true`.

### Hook command — `HookInstaller.Target.commandString(for:)`

Only `claudeCode` reads the flag. Final shape:

```swift
fileprivate func commandString(for path: String) -> String {
    switch self {
    case .claudeCode:
        if UserDefaults.standard.bool(forKey: "enableInlineReply") {
            return "CC_ISLAND_INLINE_REPLY=1 \(shellQuote(path))"
        }
        return path
    case .copilot:
        return path
    case .codex:
        return "ISLAND_SOURCE=codex \(shellQuote(path))"
    }
}
```

Notes:
- All Claude hook entries share the same command — the env var only
  matters to `Stop` but is harmless on the others. Keeps the change
  to a single `commandString(for:)` site.
- `currentlyInSync` already byte-compares the generated command
  against the on-disk command. When the flag flips, the generated
  command differs and a redeploy fires naturally — no extra plumbing.
- `isOurs` continues matching by command-path substring; the env
  prefix doesn't break it because the path is still in the string.
- Codex unchanged (already has its `ISLAND_SOURCE=codex` prefix).
- The flag read happens **only** inside `commandString(for:)`. Do
  not scatter the read into `writeSettings` or other paths — keeps
  behaviour testable through the one accessor.

### Conflict awareness with #37

#37 is reworking `HookInstaller`'s settings write path (atomic
write + `.bak`). #36 only touches `commandString(for:)`, not the
write path. If #37 lands first, #36 rebases cleanly. If #36 lands
first, #37 sees a slightly altered command but still on the same
write code.

### Server side

- `LocalServer.processEvent`: decode `quick_replies` (existing path)
  or `freeform_replyable: Bool` into a single new field
  `IslandEvent.replyMode: ReplyMode?`.
- Long-poll horizon for free-form replies: **stays at 25 s** (same
  hardcoded value as today's `PermissionRequest`).

### App side — `ReplyMode` enum (replaces `quickReplies: [String]?`)

```swift
enum ReplyMode: Equatable {
    case quickReplies([String])
    case freeformText
}
```

`IslandEvent.replyMode: ReplyMode?` replaces the existing
`quickReplies: [String]?`. Render side switches on the enum.

**Refactor risk:** ~8 callsites across `IslandState.swift`,
`IslandView.swift`, `LocalServer.swift`. Each needs a careful
rewrite — most are `event.quickReplies != nil` checks (now
`event.replyMode != nil`); a few destructure the array (now
`case .quickReplies(let labels)`). UI guards in particular need
review so a `.freeformText` event isn't accidentally swallowed by
an "is yes/no?" check.

**Invariant for `LocalServer`:** `.freeformText` is produced *only*
when `freeform_replyable == true` is in the payload. Don't
infer it from `style == .reminder` or presence of `event_id` —
that would let manual-POST reminders accidentally render a
TextField with no hook waiting.

### UI

- New `InlineReplyField` SwiftUI view: single-line `TextField` + Send.
  **Dumb component** — does not read `@AppStorage` itself. Parent
  decides whether to render it based on the flag.
- `@AppStorage("enableInlineReply")` is read in the **parent** views
  (`ExpandedContentView` / `ExpandedPillView`), used to gate the
  `case .freeformText:` arm of the switch.
- The standard `UserDefaults` suite maps to the bundle's
  CFBundleIdentifier `com.bistin.dynamic-island` — verified from
  `Info.plist`.
- Mounted in `ExpandedContentView` (notch) and `ExpandedPillView`
  (capsule), case-matching on `event.replyMode`:
  - `.quickReplies(let labels)` → `QuickReplyButtons` (today's path)
  - `.freeformText` → if `inlineReplyEnabled` is true,
    `InlineReplyField`; else nothing
- Submit non-empty → `stateManager.server?.setResponse(text, eventID:
  event.id)` + `dismiss()`.
- Empty submit → no-op.
- Esc / outside-click → existing dismiss path; hook times out, falls
  back to native Stop behaviour.

## File-by-file changes

### `Sources/IslandHookCore/HookPlan.swift`
- Add `public let inlineReplyEnabled: Bool` field.
- Update `init` + `parseHookPlan` to set it from
  `env["CC_ISLAND_INLINE_REPLY"] == "1"`.
- Bump `init` callers (constructor signature change).

### `Sources/IslandHookCore/PayloadBuilder.swift`
- `buildStopPayload`, around line 232: after the
  `extractYesNoOptions` check, add an `else if plan.inlineReplyEnabled`
  branch that sets `p["freeform_replyable"] = true; p["persistent"]
  = true`.

### `Sources/island-hook/main.swift`
- Stop case, line 173: condition becomes
  `(stopPayload["quick_replies"] is [String]) ||
   (stopPayload["freeform_replyable"] as? Bool == true)`.

### `Sources/DynamicIsland/HookInstaller.swift`
- `Target.commandString(for:)` (line 76-83): in `.claudeCode` case,
  read `UserDefaults.standard.bool(forKey: "enableInlineReply")`.
  When true, return `"CC_ISLAND_INLINE_REPLY=1 \(shellQuote(path))"`.
  Otherwise unchanged.
- No changes to `writeSettings`, `currentlyInSync`, or `isOurs` —
  they read through `commandString(for:)` already.

### `Sources/DynamicIsland/IslandState.swift`
- Add `enum ReplyMode: Equatable { case quickReplies([String]); case freeformText }`.
- `IslandEvent`:
  - Replace `quickReplies: [String]?` (line 34) with
    `replyMode: ReplyMode?`.
  - Init param + assignment (lines 90, 106) updated.
- `IslandStateManager`:
  - line 321: `currentEvent?.quickReplies != nil` →
    `currentEvent?.replyMode != nil`
  - line 324: `event.quickReplies != nil` → `event.replyMode != nil`
  - line 358: `event.quickReplies != nil` → `event.replyMode != nil`
  - line 405: `event.quickReplies != nil` → `event.replyMode != nil`

### `Sources/DynamicIsland/LocalServer.swift`
- Lines 410–419: build `replyMode` instead of `quickReplies`.
  - `quick_replies` → `.quickReplies(labels)`
  - else if `json["freeform_replyable"] as? Bool == true` →
    `.freeformText`
  - **Invariant:** `.freeformText` only when payload explicitly
    sets `freeform_replyable: true`. Do not infer.
- Line 440: pass `replyMode:` instead of `quickReplies:`.

### `Sources/DynamicIsland/IslandView.swift`
- Line 389 (`needsFullContext`): `event.quickReplies != nil` →
  `event.replyMode != nil`.
- Lines 401–403 (notch): replace `if let labels = event.quickReplies`
  with a `switch event.replyMode` rendering `QuickReplyButtons` or
  `InlineReplyField`. Read `@AppStorage("enableInlineReply")` here
  to gate `.freeformText`.
- Lines 589–591 (capsule): same change, same `@AppStorage` read.
- Lines 431, 622 (collapse guard): `event.quickReplies != nil` →
  `event.replyMode != nil`.
- New view `InlineReplyField` (no flag read, parent gates) with
  `// TODO(settings): expose enableInlineReply in #11 settings pane`
  next to the parent `@AppStorage` declaration.

### `Tests/IslandHookCoreTests/HookPlanTests.swift` (or equivalent)
- Add 1 test: `parseHookPlan(env: ["CC_ISLAND_INLINE_REPLY": "1"])`
  produces `HookPlan` with `inlineReplyEnabled == true`; without env
  → `false`.

### `Tests/IslandHookCoreTests/PayloadBuilderTests.swift`
- Existing 4 quick-reply tests untouched.
- Add 3 new tests:
  - `testStopPayload_freeformReplyable_whenENVSet_andNoYesNo_setsFlag`
  - `testStopPayload_freeformReplyable_whenENVUnset_omitsFlag`
  - `testStopPayload_yesNoMatch_setsQuickReplies_neverFreeform_evenWithENVSet`

## Acceptance

- [ ] `swift build` clean
- [ ] `swift test`: existing baseline + 4 new (3 PayloadBuilder + 1
  HookPlan) all green. Don't compare to a fixed total — the
  baseline shifts as #38 lands.
- [ ] Both flags off → behaviour byte-identical to today (no
  `freeform_replyable` in payload, no `InlineReplyField` ever
  rendered, no extra long-poll on hook side, hook command in
  `settings.json` unchanged from today)
- [ ] `defaults write ... enableInlineReply true` →
  `Reinstall Claude Code Hooks` from menu → hook command in
  `settings.json` becomes `CC_ISLAND_INLINE_REPLY=1 /path/...`
- [ ] Both flags on, real Claude session asks free-form question →
  TextField appears, submit sends `setResponse(text, eventID:)`,
  Claude receives the reply
- [ ] `defaults write ... enableInlineReply false` →
  `Reinstall Claude Code Hooks` from menu → hook command reverts
  to plain path

## Dogfood activation (full sequence)

```bash
# 1. Set the flag (App side flips immediately; hook side needs reinstall)
defaults write com.bistin.dynamic-island enableInlineReply -bool true
```

```
# 2. App menu → "Reinstall Claude Code Hooks"
#    This rewrites ~/.claude/settings.json with CC_ISLAND_INLINE_REPLY=1
#    prefixed on every Claude hook command.
```

```bash
# 3. Restart Claude Code so hooks are spawned with the new env.
```

To disable: `defaults write ... enableInlineReply false` + reinstall.

## Rollout

1. This PR ships with both gates default-off — zero regression.
2. ~2 weeks dogfood window.
3. If clean: a separate small PR flips defaults + removes both gates +
   strips the `TODO(settings)` markers (or folds them into #11 if
   that's already in flight). The HookInstaller change reverts to the
   pre-#36 `commandString(for:)`.

## Out of scope (will not do here)

- Removing the env var / UserDefaults gate.
- Multi-line text input.
- Auto-detect numbered / multi-select reply shapes.
- Telemetry on flag usage.
- Server long-poll timeout parameterization (separate cleanup,
  pre-existing UI/server horizon mismatch).
- Auto-reinstall on UserDefaults change (would need KVO /
  NotificationCenter wiring; menu reinstall is enough for dogfood).
- Touching `HookInstaller` write path / atomic-write logic — that's
  #37 territory.
