# Dynamic Island for Mac

## Project Overview

A macOS app that brings iPhone's Dynamic Island to MacBook's notch. Shows real-time notifications as "ears" flanking the notch, with Claude Code hook integration as the primary use case.

## Build & Run

```bash
swift build          # debug
swift build -c release  # production
.build/debug/DynamicIsland   # run debug
.build/release/DynamicIsland # run release
```

The app listens on **port 9423** for HTTP POST events.

## Key Architecture Decisions

- **NSPanel** at `CGShieldingWindowLevel + 1` to render above menu bar at notch level
- **Custom Shape paths** (`LeftEarShape` / `RightEarShape`) with concave inner corners to hug the notch's rounded edges
- `HStack(spacing: notchWidth)` with `maxWidth: .infinity` on each half ensures the notch gap stays centered regardless of ear text width
- **LSUIElement = true** hides app from Dock
- `IslandStateManager` replaces the current event immediately on every push (no backlog) — rapid hook bursts don't queue up
- Notch dimensions auto-detected via `NSScreen.auxiliaryTopLeftArea/RightArea`; fallback constants in `IslandPanel.swift` target 14" MBP (`notchWidth≈180`, `notchHeight≈32`, concave radius 10, outer radius 16). Sub-pixel compensation (`-1pt`) keeps the right edge flush
- **`DynamicIslandCore` SPM library** houses pure-logic pieces reachable from unit tests without AppKit: `ScreenResolver` (point-in-rect screen lookup) and `HTTPParser` (RFC 7230 request framing). Mirrors the `IslandHookCore` pattern

## Multi-display (follow cursor)

The panel follows the user's cursor across screens. `ScreenFollower` polls `NSEvent.mouseLocation` every 50 ms with a 200 ms dwell debounce; `IslandPanel.relocate(to:animated:)` fades out (0.15s), re-runs `applyScreenMetrics` for the target screen, `setFrame`s, and fades in (0.20s). Relocation triggers: `/event` POST (instant, via `IslandStateManager.pushEvent → panel?.relocateToCursorScreen`), cursor dwell ≥200 ms on a new screen, or `NSApplication.didChangeScreenParametersNotification`. Per-screen layout switches between notch and capsule (non-notch displays use `fallbackLayout`); mid-event state (permission dialogs, progress) survives the move. `NSScreen+Display` extracts `displayID` / `containing(_:)` so the formula lives in one place. Single-screen setups are unaffected — the dwell loop short-circuits every tick.

## HTTP framing

`LocalServer.handleConnection` used to call `connection.receive()` once and assume the bytes were one complete request. That's wrong for any TCP stream: `URLSession` on loopback routinely delivers headers in one chunk and body in the next, so `island-hook` POSTs silently failed with 400 `missing_body` (~80% drop rate measured in practice). Fixed in v1.6: the server now loops `receive()` until the full request is buffered (1 MiB cap; fail-fast 413 on declared oversize). Parsing is extracted into `DynamicIslandCore.HTTPParser` with 15 unit tests. Hardening per RFC 7230: duplicate/conflicting `Content-Length` → 400, `Transfer-Encoding` (no chunked decoder) → 400.

## Event Styles

- `info` / `success` / `warning` / `error` — standard notifications
- `claude` — warm orange, default for Claude Code tool events
- `action` — persistent, pulsing blue, expanded view with Allow/Deny buttons; used for `PermissionRequest`
- `reminder` — pulsing blue, no buttons; used when attention is needed but there's nothing to decide

## App icon

`scripts/render-app-icon.swift` draws the icon with AppKit and writes an `.iconset`; `iconutil -c icns` turns that into `AppIcon.icns`, referenced from `Info.plist` via `CFBundleIconFile` and copied into `Contents/Resources` at bundle time. Keeping it as code rather than a checked-in binary means it stays regenerable and diffable, and it holds the same no-external-dependencies line as the app.

The mark is a black island pill holding a shell prompt — the pill is the notch, the `>` and block cursor say the events come from CLI agents — coloured in the app's own source palette (Claude orange, Codex green). Art is authored on a 1024 grid with the standard 100pt Big Sur margin and re-drawn as vectors at each size rather than downsampled. At 32px and below the cursor and chevron smudge together, so those sizes drop the cursor and enlarge the chevron (`drawIcon(simplified:)`).

## Launch at login

`LoginItemController` (app layer) wraps `SMAppService.mainApp` — macOS 13+, no helper bundle, no LaunchAgent plist. The system owns the state, so there is deliberately **no UserDefaults mirror**: every read goes back to `SMAppService.mainApp.status` and `refresh()` runs whenever a surface showing it appears (Settings `.onAppear`, `menuNeedsUpdate` for the menu bar item). A cached copy would let the UI claim "on" for an app macOS has already stopped launching.

Settings also refreshes on `NSApplication.didBecomeActiveNotification`, not just `.onAppear`. The window controller is retained by the `AppDelegate` with `isReleasedWhenClosed = false`, so the view stays mounted between opens — and the Login Items deep link doesn't close the window anyway, it sends it behind System Settings. Without the activation hook, the exact round trip the deep link invites (leave, change the setting, come back) lands on a stale toggle. Verified by A/B: with the hook, `refresh()` runs ~250 ms after re-activation; without it, re-activation produces no refresh at all.

Decision logic lives in `DynamicIslandCore.LoginItemState` so it's unit-testable without a live registration: `loginItemAction(for:desired:)` (what to call) and `loginItemPresentation(for:)` (what to render). Two states carry the non-obvious rules:

- `requiresApproval` — registered, but the user switched it off in System Settings. Calling `register()` again returns success and changes nothing, so the action is `.none`. The toggle renders **off and non-interactive**: it already reads off, so the only flip left is back on, and a live switch there would move and snap back. The two things that can actually be done get explicit affordances instead — "Open Login Items settings…" to lift the veto, and "Remove login item" to drop the registration. The Remove button is what makes `(.requiresApproval, false) → .unregister` reachable at all; with the toggle pinned off, nothing else in the UI can ask for `desired: false`. The menu bar carries both in its alert, and deliberately stays clickable in this state (`isInteractive || showsSystemSettingsButton`) — greying it out would hide the explanation along with the escape hatches.
- `notFound` — despite the name, this is the ordinary never-registered state for a fresh `.app` on macOS 26 (verified on 26.5.2, unchanged by `lsregister -f`). Presented as a plain "off"; treating it as an error would fire a false alarm on every first launch.

Surfaces: Settings → General → Startup, the menu bar's "Open at Login" item, and `--login-item-status` (read-only; registration stays a deliberate user action so a stray CLI call can't add a login item). Running a bare `swift build` binary reports `unavailable` and disables the toggle — `Bundle.main` isn't an `.app` there, so there's nothing for `SMAppService` to register.

## Session state from the transcript

`DynamicIslandCore.TranscriptState` derives what a session is doing from the JSONL Claude Code
already writes at `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. It exists because every
event the island shows arrives from a hook, and that has a hole shaped exactly like the hook: a
session started before the hook was installed is invisible, and between two pushes the island is
showing the last thing that happened rather than what is happening.

`read(lines:now:staleAfter:)` is pure and takes lines rather than a path, the same split
`HTTPParser` and `ScreenResolver` use. The markers, all confirmed against real transcripts:

- a turn ends with a `system` entry whose `subtype` is `turn_duration` — the cleanest marker in
  the file, and the only one that means "nothing is running" outright
- `assistant` with `stop_reason: end_turn` is the same fact one entry earlier; both are read
  because a file caught between them would otherwise report a finished turn as still running
- an interrupted turn writes no `turn_duration` at all, so a `user` entry carrying
  `interruptedMessageId` ends the turn instead
- roughly a third of the file is housekeeping (`file-history-snapshot`, `ai-title`, `pr-link`,
  `attachment`, …) written *between* the entries that matter, so "the last line" is the wrong
  question — those types decide nothing

**`waiting` is not in the transcript, and that was measured rather than assumed.** Claude Code
writes an assistant `tool_use` and its `tool_result` together, *after the tool returns*; the
pending window never reaches disk. Sampled three times from inside a live session with a tool call
demonstrably in flight, the transcript reported zero outstanding `tool_use` entries and its newest
entry predated the call by 26, 32 and 54 seconds. So an unanswered permission prompt and an
`AskUserQuestion` waiting on a person look from here exactly like a session that is quietly busy —
at that moment they are the same bytes. There is therefore no `waiting` case: the
`PermissionRequest` hook stays the source for that, and this file does not try to replace it.

Stale `working` decays to `unknown`, never to `idle` (default `staleAfter` 300s — appends happen
once per completed tool and a single `Bash` step may run for ten minutes). A session that stopped
writing mid-turn was killed, or slept, or is on a very long tool; none of those is a finished turn,
and only a finished turn writes `turn_duration`. `unknown` is a real answer throughout: a
transcript that cannot be read is not a session that ended.

Validated against all 30 transcripts on the development machine: 25 idle, 3 unknown (each ending
mid-turn with no `turn_duration`), 2 working — one of them the session doing the validation, the
other confirmed live by its mtime and a matching `claude` process.

## Hook Integration

`Sources/island-hook/main.swift` is the canonical universal hook entry point — a Foundation-only Swift binary (~109KB) that handles Claude Code, GitHub Copilot, and OpenAI Codex by sniffing payload shape (`hook_event_name` casing vs `toolName` at root). Reads JSON from stdin, dispatches via `IslandHookCore` (pure-logic library, fully unit-tested), and POSTs formatted events to `127.0.0.1:9423/event`. Must exit 0 so it never blocks the caller. PermissionRequest is the only event that emits stdout (provider-specific allow/deny JSON).

Project label: derived from `cwd` basename; subagent events override it with `↳ <agent_type>`. A deterministic hash picks one of 8 palette colors so concurrent sessions are visually distinguishable.

### Auto-install (HookInstaller.swift)

Hooks are auto-installed on first launch via an NSAlert (Install / Skip / Never), with the choice persisted in `UserDefaults["hookInstallChoice"]`. Subsequent launches silently sync via `syncIfOutdated`, which is idempotent and only writes when the deployed script or settings actually drift.

The binary is deployed to `~/.claude/hooks/dynamic-island-hook` (stable path independent of the .app location), and `~/.claude/settings.json` is updated non-destructively — entries from other tools (gemini-bridge etc.) are preserved by detecting "ours" via command path markers (`dynamic-island-hook` / `island-hook.sh` / `claude-hook.sh` / `DynamicIsland`). Drift detection: `currentlyInSync` byte-compares the deployed binary against the bundled source, so upgrading the .app triggers a redeploy on next launch.

CLI:
- `--install-hooks` / `--uninstall-hooks` — Claude Code (writes `~/.claude/settings.json`)
- `--install-copilot-hooks [repoPath]` / `--uninstall-copilot-hooks [repoPath]` — Copilot (writes `{repo}/.github/hooks/hooks.json`, defaults to cwd)
- `--install-codex-hooks` / `--uninstall-codex-hooks` — Codex (writes `~/.codex/hooks.json`; migrates deprecated `[features].codex_hooks` to `[features].hooks` when present). New or changed definitions must be reviewed in Codex via `/hooks`.

Copilot uses a different schema: top-level `version: 1`, camelCase events (`preToolUse`, `postToolUse`, `userPromptSubmitted`, `sessionStart`, `sessionEnd`, `errorOccurred`), no matcher, fields `{type, bash, timeoutSec}`.

Safety: `writeSettings` refuses to overwrite the file if existing JSON is invalid, to avoid clobbering user config. `currentlyInSync` checks the deployed script exists, not just the settings entries.

### Registered events (Claude Code)

PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest, PermissionDenied, Notification, Stop, StopFailure, SubagentStart, SubagentStop, UserPromptSubmit, SessionStart, SessionEnd, PreCompact, PostCompact. `PostToolUseFailure` / `StopFailure` replace fragile grep-based error detection; `PreCompact` / `PostCompact` show context compaction progress.

## Permission Flow

`PermissionRequest` hook POSTs an `action`-style event (Permission title + tool detail), then long-polls `GET /response` for up to the permission-timeout setting (default 300s / 5 min). The UI buttons call `LocalServer.setResponse("allow"|"deny")`, which resumes the waiter. If no waiter is present the value is stored in `pendingResponse` for the next poll — but never persisted past a single delivery, to avoid stale clicks leaking into future requests. On timeout the hook exits silently and Claude Code falls back to its normal permission prompt.

The horizon is one tunable value (`permissionTimeoutKey` UserDefault, default `PermissionTimeoutSeconds` = 300) read in three places that must agree: the hook long-poll (`CC_ISLAND_PERMISSION_TIMEOUT` env injected by `HookInstaller.commandString`, parsed into `HookPlan.permissionTimeoutSeconds`), the server long-poll (`LocalServer.handleResponsePoll`), and the UI expired-dim mirror (`IslandState.expirationTimeout`). `HookInstaller.events` registers the `PermissionRequest` entry timeout at `ceil(setting + 5)` so Claude Code doesn't SIGKILL the hook mid-poll. Changing the value requires reinstalling hooks (Settings → General → Timings → Permission timeout); the auto-sync on launch picks up the drift since the command string and entry timeout both change. Raised from the original hard-coded 25s — five minutes lets the user step away and still return to live Allow/Deny buttons instead of a dimmed, expired dialog.

The matcher in `settings.json` intentionally limits `PermissionRequest` to risky tools (`Bash|Edit|Write|MultiEdit|NotebookEdit`) — read-only tools like `Read`/`Grep`/`Glob` skip the island so subagents don't spam Allow/Deny.

### FIFO context correlation

`PreToolUse` for Edit/Write/Bash/MultiEdit/NotebookEdit caches its full payload under `~/Library/Caches/cc-island/pretool/<key>.json`. The next `PermissionRequest` reads it to enrich the dialog: Edit/MultiEdit shows a colored diff (red `-` / green `+`), Write shows a content preview, Bash backfills the command/description if `tool_input` arrived empty. Single-slot per key (the next PreToolUse overwrites) — works because PreToolUse and PermissionRequest fire serially per session. Key resolves via `IslandHookCore.preToolCacheKey`: `session_id` first, then `agent-<agentId>-<project>` for subagents, then `<project>`, then `default`. Pre-v1.7.x layout was `/tmp/di_pretool_${PROJECT}.json` — the old path is world-readable on multi-user machines and predictable across processes, so the cache moved into the per-user `~/Library/Caches/` tree.

## Numbers in the docs

`scripts/check-claimed-numbers.sh` reads every number the docs quote back out of the code it
describes, and CI fails on a disagreement. It ran red the first time it was pointed at `main`: the README
claimed 264 tests against a run of 277, and its per-target breakdown said 68 / 20 where the real
figures were 149 / 128, with `HTTPParserTests` alone at 25 against a claimed 15. Nothing had
broken — the numbers had simply been true once.

Two rules make it worth having rather than decorative:

- **Truth comes from the code, never from a second copy of the number.** Test counts come from
  `swift test --list-tests`, which is the list SwiftPM will actually run, so a test that is
  defined but not collected cannot inflate it. The port comes from `LocalServer.init`, the
  long-poll horizon from `PermissionTimeoutSeconds`.
- **A claim that cannot be found is a failure, not a skip.** The obvious shape — "if the pattern
  matched, compare it" — turns every reworded sentence into a check that quietly stops checking
  while still reporting green. So the lookup fails loudly instead, which also means a new test
  target under `Tests/` has to be written into the README before CI will go green with it: the
  per-target loop iterates over what is on disk rather than over a list kept in the script.

Verified by mutation, not by reading: a wrong number, a reworded sentence, docs that stop naming
the port, and an undocumented new test target each turn it red.

## Conventions

- Pure Swift, no external dependencies — only Foundation, AppKit, SwiftUI, Network frameworks
- SPM executable target (not Xcode project)
- Animations use SwiftUI `.spring(response:dampingFraction:)`
