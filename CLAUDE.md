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
- The two ears are fixed at `IslandPanel.earWidth` and the window is `earWidth * 2 + notchWidth`, so the gap stays centred regardless of ear text width
- **LSUIElement = true** hides app from Dock
- `IslandStateManager` shows an incoming event immediately *unless* somebody is mid-decision. `decideEventDisposition` then either queues it (`pendingActions`, drained one at a time by `dismiss()`) or drops it as transient noise — see "Waiting for a person". This line used to say there was no backlog at all, which was true before the decision guard and has been the opposite of the code since
- Notch dimensions auto-detected via `NSScreen.auxiliaryTopLeftArea/RightArea`; fallback constants in `IslandPanel.swift` target 14" MBP (`notchWidth` 185, `notchHeight≈32`, concave radius 10, outer radius 16). Sub-pixel compensation (`-1pt`) keeps the right edge flush
- **`DynamicIslandCore` SPM library** houses pure-logic pieces reachable from unit tests without AppKit: `ScreenResolver` (point-in-rect screen lookup) and `HTTPParser` (RFC 7230 request framing). Mirrors the `IslandHookCore` pattern

## Multi-display (follow cursor)

The panel follows the user's cursor across screens. `ScreenFollower` polls `NSEvent.mouseLocation` every 50 ms with a 200 ms dwell debounce; `IslandPanel.relocate(to:)` fades out (0.15s), re-runs `applyScreenMetrics` for the target screen, `setFrame`s, and fades in (0.20s). Relocation triggers: `/event` POST (instant, via `IslandStateManager.pushEvent → panel?.relocateToCursorScreen`), cursor dwell ≥200 ms on a new screen, or `NSApplication.didChangeScreenParametersNotification`. Per-screen layout switches between notch and capsule (non-notch displays use `fallbackLayout`); mid-event state (permission dialogs, progress) survives the move. `NSScreen+Display` extracts `displayID` / `containing(_:)` so the formula lives in one place. Single-screen setups are unaffected — the dwell loop short-circuits every tick.

## Where the server listens

`LocalServer` names a **required local endpoint** rather than binding and filtering:

```swift
params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: …)
```

Without it, `NWParameters.tcp` listens on every interface. It did, for a long time, while every
comment in that file, the README and this page all said `127.0.0.1`. Measured: `lsof` reported
`TCP *:9423 (LISTEN)`, and a TCP handshake from this Mac's own LAN address succeeded. A listener
that accepts from the local network is one coffee shop away from accepting from the coffee shop.

The `application/json` gate on `/event` did **not** cover this. It is a CORS defence: it forces a
browser through a preflight that then fails, which is worth having and stops a malicious tab.
`curl` sets whatever header it likes, so it stopped nothing from a machine on the same network.
Neither did the user's firewall, which is off by default on macOS and is not this app's doing
either way.

The log line reads the endpoint back out of the listener rather than restating it, because "it
says 127.0.0.1 in the source" is exactly what was true throughout.

**A tmux reveal has three outcomes, not two.** `DynamicIslandCore.TmuxRevealOutcome` is
`notAPane` or `selected(emulatorTTY:)`, where the emulator tty is nil for a *detached* session.
That distinction was originally an optional return, which made "selected a pane nobody is looking
at" indistinguishable from "found no pane" — so selecting a pane on a detached server logged
`is not a tmux pane` while having just moved the selection. Caught end to end by a test whose
`tmux attach` had quietly exited: the message said nothing was found and `window_active` moved
anyway. The modelling lives in the core because conflating two facts in one optional is what a
type can prevent and a test can catch.

**Taps have one implementation each, on the state manager.** `handleCompactTap()` for the ears,
`handleExpandedTap(for:)` for the panel, and the decisions behind them —
`shouldTapJumpToTerminal`, `expandedTapAction` — in `DynamicIslandCore` where they can be checked
without a window. The expanded one was inline in two views and the copies had already drifted: the
notch panel learned to take the tap to the terminal and the capsule did not, so on a display
without a notch the panel never reached the session it was pointing at. Found by an audit that was
looking for exactly this shape, having just seen it in the jump button.

**Focusing a terminal goes through the state manager, never straight to `TerminalActivator`.**
`IslandStateManager.focusTerminal(tty:tmuxSocket:)` focuses and leaves the island alone;
`jumpToTerminal(for:)` is that plus a dismiss, and applies the tap policy. The permission dialog's
"Jump to terminal tab" needs the first: the decision is still outstanding and a hook is still
long-polling for it, so walking away from the island is fine but taking the buttons with you is
not.

That button used to call `TerminalActivator.activate(tty:)` in its own closure, and so never
learned about the tmux socket — a pane on a `tmux -L` server was unreachable from it for as long
as the socket support had existed. A closure is where policy goes to be forgotten. No view
calls `activate(tty:)` directly any more — though `Reply.swift` still asks the activator
`hasRunningTerminal()` to decide whether to draw the button, which is the visibility half of the
same policy and has not been collected yet.

## HTTP framing

`LocalServer.handleConnection` used to call `connection.receive()` once and assume the bytes were one complete request. That's wrong for any TCP stream: `URLSession` on loopback routinely delivers headers in one chunk and body in the next, so `island-hook` POSTs silently failed with 400 `missing_body` (~80% drop rate measured in practice). Fixed in v1.6: the server now loops `receive()` until the full request is buffered (1 MiB cap; fail-fast 413 on declared oversize). Parsing is extracted into `DynamicIslandCore.HTTPParser`, covered by its own test class. Hardening per RFC 7230: duplicate/conflicting `Content-Length` → 400, `Transfer-Encoding` (no chunked decoder) → 400.

## Event Styles

- `info` / `success` / `warning` / `error` — standard notifications
- `claude` — warm orange, default for Claude Code tool events
- `action` — persistent, pulsing blue, expanded view with Allow/Deny buttons; used for `PermissionRequest`
- `reminder` — pulsing blue. The `PreToolUse` waiting event carries no buttons because the menu is in the terminal; a `Stop` reminder can carry quick replies or a freeform field, which render off `replyMode` rather than off the style

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

**Only the tail is read, and how much was measured.** Transcripts grow without bound — 44 MB and
31 MB on the development machine — and parsing every line of one cost 281 ms and 518 ms. Nothing
in the verdict needs any of that: a turn ending, an interrupted turn, the newest entry, are all at
the end. `read(fileAt:)` starts at 64 KB and widens eightfold until something significant turns up,
the file runs out, or 4 MB is reached. Across all 31 transcripts on that machine the tail read
agreed with the full read on every verdict and every `lastActivityAt`, at a worst case of 18.5 ms
against 529.6 ms. A window that lands inside one record — records reach a megabyte — holds no
complete line, so it yields nothing and the caller widens rather than treating half a record as
evidence.

**Locating the file: every character that is not an ASCII letter or digit becomes a dash, not just
the separators.** `projectSlug(for:)` counts UTF-16 code units, so one ideograph is one dash and an
emoji is two. This is proven on the development machine rather than taken on trust:
`/Users/bistin/Desktop/毒` is on disk as `~/.claude/projects/-Users-bistin-Desktop--`, and the
naive rule's `-Users-bistin-Desktop-毒` does not exist. Getting it wrong fails in the worst way —
a missing transcript is an ordinary state, so a wrong slug raises nothing and simply makes the
session look like one Claude Code never wrote about. The map is many-to-one (`-a-b-c` is `a/b/c`
and `a/b-c`), so it is only ever used forwards.

`transcriptURL(cwd:sessionID:)` returns nil for a session id that is not a plain filename. `cwd`
cannot hold a separator once slugged; the session id is not slugged and arrives in an HTTP payload,
and `appendingPathComponent` treats a `/` in it as structure, so `..` would climb out of the tree.
Refused rather than slugged: mangling it would look up the wrong file and say nothing about it.

Stale `working` decays to `unknown`, never to `idle` (default `staleAfter` 300s — appends happen
once per completed tool and a single `Bash` step may run for ten minutes). A session that stopped
writing mid-turn was killed, or slept, or is on a very long tool; none of those is a finished turn,
and only a finished turn writes `turn_duration`. `unknown` is a real answer throughout: a
transcript that cannot be read is not a session that ended.

Validated against all 30 transcripts on the development machine: 25 idle, 3 unknown (each ending
mid-turn with no `turn_duration`), 2 working — one of them the session doing the validation, the
other confirmed live by its mtime and a matching `claude` process.

**Nothing calls any of it.** No production path reads a transcript; outside its own file and tests
the only references are doc comments and `Compat.dependencies` rows. So the hole this section opens
by naming it — a session started before the hook was installed is invisible — is still open, and
`docs/compatibility.md` ships the symptom "Session state is always `unknown`" for something with no
runtime. It was built and tested first so the reading could be judged on its own; wiring it is a
decision nobody has made yet.

## Jumping to the right terminal tab

A click on the island focuses the pane running that session. `TerminalActivator` tries three
routes in order: tmux, then AppleScript against Terminal.app / iTerm2, then "bring whatever
terminal is running to the front".

**A session under tmux has two ttys, and confusing them was the bug.** The hook reports the
*pane's* tty — it walks to its parent and asks `ps` for the controlling terminal, which inside a
pane is the pane's pty. The emulator knows that tab by the *client's* tty instead. Measured on a
live server: `pane_tty=/dev/ttys005` while `client_tty=/dev/ttys007`. Every AppleScript lookup
compares against the reported tty, so for anybody running tmux none of them could ever match; the
whole thing fell through to the last route and landed on whatever tab happened to be showing.

`DynamicIslandCore.TmuxTargetResolver` resolves one into the other by joining `list-panes -a` and
`list-clients` on the session name, and `TmuxBridge` runs the two `select` calls. Two independent
things come out of it:

- the **pane id**, which `select-pane` + `select-window` move to — the only route to the right
  pane for Ghostty, WezTerm, Warp, Hyper, kitty and Alacritty, none of which expose a tab model
  to AppleScript at all
- the **client tty**, handed to the AppleScript route, which is what makes it land on the right
  tab for Terminal.app and iTerm2

**It needs no permission of any kind** — no accessibility, no automation, no TCC prompt. tmux is
an ordinary subprocess and asking it to change its own selection is not cross-app automation. It
runs off the main thread for the same reason; only the AppleScript half needs a run loop.

One limit worth knowing before debugging a report that it did nothing:

- **Which app comes forward is still a guess** when the terminal has no AppleScript tab model.
  tmux puts the right pane in front inside its own window, but with both Terminal.app and Ghostty
  running, the fallback picks by `knownTerminalBundleIDs` order rather than by which one is
  actually drawing that client.

**Non-default servers are addressed too, and only the hook can make that possible.** `tmux` with no
`-S` finds `/tmp/tmux-<uid>/default` and nothing else, so a server started with `tmux -L work` was
invisible — the pane was simply never found, with no indication why. The hook is the one part of
this that runs *inside* the pane, so it is the only part that can see `TMUX`, which tmux sets there
to `<socket-path>,<server-pid>,<session-index>`. `IslandHookCore.tmuxSocketPath` takes the first
field, the payload carries it as `tmux_socket`, and `TmuxBridge` prepends `-S`. The app validates it
with the same parser the hook used — an absolute path, nothing else; it reaches `Process` as argv
with no shell, so that is a shape check rather than a quoting one.

Verified end to end against a live server: with focus parked on a second window,
`TmuxBridge.reveal` on the first window's pane tty returned the client tty and moved
`window_active` from the second window to the first. Repeated on a named socket, as an A/B in one
run: without the socket the same call answered `not a pane`; with it, the pane was selected and
`window_active` moved. `--reveal-tty <tty> --tmux-socket <path>` is how that was measured.

`--reveal-tty <tty>` runs the same two routes synchronously and says which one answered — it
exists because the click path otherwise had no way to be exercised without a person clicking, and
"hand the user a build and ask them to try it" is the shape of testing this project tries not to
do. Unlike `--login-item-status` it is deliberately an action rather than a status: what it does
is exactly what the user was about to do by clicking. Output from a real run, focus parked on the
second window:

```
$ DynamicIsland --reveal-tty /dev/ttys005
reveal /dev/ttys005
tmux: selected the pane, emulator tty /dev/ttys007
applescript: no tab matched /dev/ttys007 — expected for a terminal with no tab model; tmux already aimed the pane
```

A tty that fails `decodeTTY` is refused with exit 1 rather than passed on.

## Hook Integration

`Sources/island-hook/main.swift` is the canonical universal hook entry point — a Foundation-only Swift binary (~170 KB) that handles Claude Code, GitHub Copilot, and OpenAI Codex by sniffing payload shape (`hook_event_name` casing vs `toolName` at root). Reads JSON from stdin, dispatches via `IslandHookCore` (pure-logic library, fully unit-tested), and POSTs formatted events to `127.0.0.1:9423/event`. Must exit 0 so it never blocks the caller. Two events write stdout: `PermissionRequest` (provider-specific allow/deny JSON) and `Stop`, when the payload carried quick replies or a freeform field and the user answered — `encodeStopBlockResponse` turns that into `decision: block` with the reply as the reason.

Project label: derived from `cwd` basename; subagent events override it with `↳ <agent_type>`. A deterministic hash picks one of 8 palette colours for the session-tree rows. The ears do not use it: `decorate` always sets `source`, and `projectColor` prefers the source colour, so every Claude session's ears are the same orange.

### Auto-install (HookInstaller.swift)

Hooks are auto-installed on first launch via an NSAlert (Install / Skip / Never), with the choice persisted in `UserDefaults["hookInstallChoice"]`. Subsequent launches silently sync via `syncIfOutdated`, which is idempotent and only writes when the deployed script or settings actually drift.

The binary is deployed to `~/.claude/hooks/dynamic-island-hook` (stable path independent of the .app location), and `~/.claude/settings.json` is updated non-destructively — entries from other tools (gemini-bridge etc.) are preserved by detecting "ours" as exact membership of `knownOwnedHookPaths` — the three current deploy paths plus two frozen legacy `.sh` literals. Deliberately not substring matching: `DynamicIsland` as a marker would claim any unrelated path that happened to contain it. The cost is that a settings entry pointing straight at a `DynamicIsland` binary is not recognised as ours, and uninstall leaves it. Drift detection: `currentlyInSync` byte-compares the deployed binary against the bundled source, so upgrading the .app triggers a redeploy on next launch.

CLI:
- `--install-hooks` / `--uninstall-hooks` — Claude Code (writes `~/.claude/settings.json`)
- `--install-copilot-hooks [repoPath]` / `--uninstall-copilot-hooks [repoPath]` — Copilot (writes `{repo}/.github/hooks/hooks.json`, defaults to cwd)
- `--install-codex-hooks` / `--uninstall-codex-hooks` — Codex (writes `~/.codex/hooks.json`; migrates deprecated `[features].codex_hooks` to `[features].hooks` when present). New or changed definitions must be reviewed in Codex via `/hooks`.

Copilot uses a different schema: top-level `version: 1`, camelCase events (`preToolUse`, `postToolUse`, `userPromptSubmitted`, `sessionStart`, `sessionEnd`, `errorOccurred`), no matcher, fields `{type, bash, timeoutSec}`.

Safety: `writeSettings` refuses to overwrite the file if existing JSON is invalid, to avoid clobbering user config. `currentlyInSync` checks the deployed script exists, not just the settings entries.

### Registered events (Claude Code)

PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest, PermissionDenied, Notification, Stop, StopFailure, SubagentStart, SubagentStop, UserPromptSubmit, SessionStart, SessionEnd, PreCompact, PostCompact. `PostToolUseFailure` / `StopFailure` replace fragile grep-based error detection; `PreCompact` / `PostCompact` show context compaction progress.

## Waiting for a person

`AskUserQuestion` and `ExitPlanMode` are the tools whose *execution is a person answering*.
Everything else the island shows is something that happened; these are something that has not
happened yet and will not until somebody looks — which makes them the only events where every
second of going unnoticed costs something. Across the transcripts on the development machine, 58
of them were answered at a median of 71 seconds and a maximum of **10.9 hours**. Ten hours is not
deliberation, it is nobody knowing they were being asked.

**The waiting is visible only through the hook, and both halves of that were measured.** The
transcript cannot show it: Claude Code writes an assistant `tool_use` and its `tool_result`
together *after* the tool returns, so a pending question never reaches disk (see "Session state
from the transcript"). `PreToolUse` can, because it fires before the tool runs — which for these
tools means before the person answers. Confirmed by standing a capture server on 9423 and
triggering a real `AskUserQuestion`: the POST arrived **18.3 seconds before the answer**, while the
menu was still on screen. cc-island had been receiving that event all along and throwing it away
as an ordinary `claude` event that auto-dismissed after two seconds.

`PreToolUse` raises a `reminder` — pulsing, and deliberately **without buttons**: the answer is a
menu in the terminal, and a second place to answer it would be a second source of truth. The
question becomes the subtitle and its options the detail.

**It opens expanded, and the rule generalised.** `DynamicIslandCore.shouldOpenExpanded` says that
something that pulses, and has something to show, shows it: the detail is what tells a person
whether this is worth crossing the room for, and making them click first asks them to act on
"something wants you" alone. That covers a question with its options, a plan with its body, and a
turn that ended on a question with the message that ended it, while the bare `Notification` ping —
a `reminder` with no detail — stays as ears, because expanding an empty panel would cover the
screen to say nothing.

**Tapping it goes to the terminal, not away.** `shouldTapJumpToTerminal` says a tap means "I want
to deal with this", and where that leads depends on whether the island can do anything about it:
when it holds the decision — Allow/Deny, or quick-reply buttons — the answer is right there and
walking away would be wrong; when it does not, the island is a pointer, and the useful thing a
pointer does is take you to what it points at. A waiting event is the second kind, so both the ears
and the expanded panel now focus that session's pane (via the tty the hook already sends, and the
tmux route where one applies) instead of dismissing the only sign that somebody is waiting.

Answering *on* the island is possible in principle — `PreToolUse` can deny with a reason, and the
`quick_replies` long-poll machinery already exists for `Stop` — but it is not this. A denial with a
reason reaches Claude as "blocked, and here is why" rather than as an answer, and for
`ExitPlanMode` "blocked because the user approved it" is a contradiction.

**A persistent reminder counts as "mid-decision" for dispatch**, which it did not at first and
that was a real hole: `isDecisionShape` only recognised `action` and reminders carrying a reply
mode, so the very next tool call from *any* session — a `Bash` in another project, a `Read` from a
subagent — replaced the waiting event and the question vanished from the island while it was still
on screen in the terminal. Found by watching it happen during testing. Cross-session traffic is now
dropped while somebody is being asked; **same-session** events still take over, which is deliberate
and is also the clearing path for a tool the user cancelled, since that never reaches `PostToolUse`.

Deliberately **not** paired with an expiry. `action` expires because its hook stops long-polling
and a late click cannot land; a question has no such horizon, and dismissing the marker while it is
still on screen would defeat the point. What clears it instead is arrival — the matching
`PostToolUse`, the session's next event, or its `Stop`, any of which replaces it. That also covers
the case `PostToolUse` alone does not: a tool the user cancels never reaches it. `persistent` is stated explicitly rather
than left to the style's default, because the payload crosses a version boundary and an older
island that did not infer it would dismiss the one event that must not be dismissed.

**Clearing is the half that had to be built.** `PostToolUse`'s matcher was `Bash|Edit|Write`, so
nothing fired when the question was answered — a "waiting for you" left on the island afterwards is
worse than never having shown it, because it teaches the reader to ignore the one state that
matters. `IslandHookCore.InteractiveTools` is the single list: `HookInstaller` appends
`InteractiveTools.matcher` to the `PostToolUse` registration, and the payload builder tests the
same names. Two lists would agree for exactly as long as nobody edited either, and the failure
mode is the bad one.

Changing the matcher makes `settings.json` drift, so the launch-time `syncIfOutdated` reinstalls
the hooks on its own — nothing for the user to do.

## The expanded panel's height

`DynamicIslandCore.expandedPanelExtraHeight(sessionRows:detailLines:decisionRows:)` decides how far
the panel grows past its base, and the third argument exists because leaving it out cost the
permission dialog the diff it exists to show.

The base reserves room for about three lines of detail **and nothing else**. An `action` stacks two
further rows under that detail — Allow/Deny, and the jump-to-terminal row — and neither was in the
sum, so the space came out of the detail. That would merely have been ugly if the detail clipped;
it does not. It renders in a `ScrollView` with a maximum height and no minimum, and a `ScrollView`
squeezed to nothing **collapses silently**. The dialog looked deliberate, and the colored diff this
file has described since v1.7 was simply absent. Nobody would report it, because it looks like the
dialog was always that shape.

Two changes, and the second is the one that matters more:

- rows of controls are **counted**, not folded into the base, so a layout that grows a third row
  cannot quietly take the space back out of the detail again
- the detail's ScrollView has a **minimum** height as well as a maximum: squeezed, it should clip,
  because a detail that vanishes leaves nothing on screen to say anything is missing

Found while taking README screenshots, by noticing that one payload rendered its diff as a
`reminder` and rendered nothing as an `action`.

## The session tree

One row per agent, keyed by `agent_id` — main plus any subagents. Two things about it were wrong
in a way that only showed up under a workflow spawning agents in a loop, and were found from a
screenshot of fourteen rows with the question the user was being asked pushed off the top.

**Nothing ever closed a row.** `SubagentStop` sends `{"type": "subagent_stop"}`, and the app's
handler reads `agent_id` from it to know which row to close — but the hook was not putting one in,
so the handler returned early every time. That made the message dead code. Worse, the `Agent done`
event that follows carries an `agent_id` like every other event, so it *re-created* the row and
refreshed its idle clock. Every finished subagent therefore sat in the tree for the full 90-second
sweep, minimum, with no way to leave sooner.

Fixed on both sides: the close message carries the id, and the event carries `closes_agent`, which
routes it to `removeSession` instead of `updateSession`. It still shows — "Agent done" flashes in
the ears — it just does not leave a row.

**The tree had no ceiling.** `sessionRowsToShow(total:limit:)` now bounds it at five, the last of
which is "and N more". The cap is applied in `IslandPanel.size(for:hasNotch:)`, which is the only
place the panel's size is computed — three call sites used to assemble those arguments separately
and two of them were wrong: `relocate` passed the raw session count, so moving the island to
another screen undid the cap, and `refreshLayoutForCurrentScreen` did that *and* omitted
`decisionRows`, which is the omission that cost the permission dialog its diff, still live on the
display-change path days after being fixed elsewhere. That is a floor under correctness rather than a substitute for it: what put
fourteen rows there was the close path above. The cap is what keeps the next leak from being
unbounded, since rows are 18 points each and the height arithmetic multiplied by however many
there were.

Verified against the running app with fourteen synthetic subagents *and* a live session's real
ones arriving alongside: the panel stayed at four rows plus a count, and closing dropped the tree
from 23 rows to 14 within two seconds — well inside the sweep interval, which is what says the
removal happened rather than the timer.

## Permission Flow

`PermissionRequest` hook POSTs an `action`-style event (Permission title + tool detail), then long-polls `GET /response` for up to the permission-timeout setting (default 300s / 5 min). The UI buttons call `LocalServer.setResponse("allow"|"deny")`, which resumes the waiter. If no waiter is present the decision is parked in `DynamicIslandCore.ResponseWaiterStore` keyed by event id, and handed only to a poll carrying that same `event_id`; a poll without one, or with a different one, gets `timeout`. Never persisted past a single delivery, so a stale click cannot leak into a later request. On timeout the hook exits silently and Claude Code falls back to its normal permission prompt.

The horizon is one tunable value (`permissionTimeoutKey` UserDefault, default `PermissionTimeoutSeconds` = 300) read in three places that must agree: the hook long-poll (`CC_ISLAND_PERMISSION_TIMEOUT` env injected by `HookInstaller.commandString`, parsed into `HookPlan.permissionTimeoutSeconds`), the server long-poll (`LocalServer.handleResponsePoll`), and the UI expired-dim mirror (`IslandState.expirationTimeout`). `HookInstaller.events` registers the `PermissionRequest` entry timeout at `ceil(setting + 5)` so Claude Code doesn't SIGKILL the hook mid-poll. Changing the value requires reinstalling hooks (Settings → General → Timings → Permission timeout); the auto-sync on launch picks up the drift since the command string and entry timeout both change. Raised from the original hard-coded 25s — five minutes lets the user step away and still return to live Allow/Deny buttons instead of a dimmed, expired dialog.

The matcher in `settings.json` intentionally limits `PermissionRequest` to risky tools (`Bash|Edit|Write|MultiEdit|NotebookEdit`) — read-only tools like `Read`/`Grep`/`Glob` skip the island so subagents don't spam Allow/Deny.

### FIFO context correlation

`PreToolUse` for Edit/Write/Bash/MultiEdit/NotebookEdit/apply_patch caches its full payload under `~/Library/Caches/cc-island/pretool/<key>.json`. The next `PermissionRequest` reads it to enrich the dialog: Edit/MultiEdit shows a colored diff (red `-` / green `+`), Write shows a content preview, Bash backfills the command/description if `tool_input` arrived empty. Single-slot per key (the next PreToolUse overwrites) — works because PreToolUse and PermissionRequest fire serially per session. Key resolves via `IslandHookCore.preToolCacheKey`: `session_id` first, then `agent-<agentId>-<project>` for subagents, then `<project>`, then `default`. Pre-v1.7.x layout was `/tmp/di_pretool_${PROJECT}.json` — the old path is world-readable on multi-user machines and predictable across processes, so the cache moved into the per-user `~/Library/Caches/` tree.

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

## What this depends on

`DynamicIslandCore.Compat.dependencies` lists the things this app reads that nobody promised would
stay the same: Claude Code's hook payload shape and firing order, its transcript layout and the
`turn_duration` marker, the names of the tools that ask a person, `ps -o tty=` output, tmux's
format strings and `TMUX`, `SMAppService` status semantics, the notch rectangles macOS reports.
Almost none of it is an API.

**The symptom column is the point.** Every one of these failures is quiet, and every one of them
looks like a bug in this app rather than a change underneath it — an island that never lights up, a
click that goes nowhere, a toggle that lies. Somebody debugging one of those should be able to read
the page and recognise what they are seeing.

`docs/compatibility.md` is **generated** by `DynamicIsland --compat-table`, and
`scripts/check-compatibility-doc.sh` fails CI when the page and the table have drifted. A page like
that maintained by hand is wrong by the second release: somebody adds a dependency in code, nobody
remembers the page, and it quietly starts describing an older build while looking authoritative.
The check also verifies every file the table names still exists, so a rename cannot leave the page
pointing at nothing. Regenerate with `scripts/check-compatibility-doc.sh --write`.

`confirmed` is either a measurement somebody wrote down — the measurements themselves are in this
file — or the plain word "assumed", which means it has been true for as long as anyone looked and
nobody went back to find where it started. Inventing a version number would make the column mean
"probably", so the tests enforce that it is one or the other.

## The README's source tree

`scripts/check-source-tree.sh` fails CI when the `Sources/` tree in the README and the files on
disk disagree, in either direction. That tree is what somebody reads to find their way around
before they know the name of anything, which makes being wrong about it expensive in a way most
stale docs are not: a file missing from it is a whole area of the app a newcomer never learns
exists, and a file renamed away sends them looking for something that is not there.

It listed **19 of 44 files** when the check was added — not by decision, just by nobody going
back. The tree is complete now, and complete is the point: "the important ones" is a rule no
script can check, while "all of them" is one it can.

## The log file

`~/Library/Logs/CLI Island.log`. An app with no window and no Dock icon says nothing at all when
something goes wrong, and often the diagnosis already exists and is simply unreachable:
`LocalServer` has always printed "Server failed" on a bind error, and an `LSUIElement` app launched
from Finder has no stdout anybody will read. That exact case came up during development — the app
running, nothing listening on 9423, and no way to tell from outside except noticing that events had
stopped arriving.

**Routes and outcomes, never payloads.** What a session asked, what a file contained, what a command
was — none of that belongs in a file that outlives the moment and that somebody may paste into an
issue. What belongs is which path the code took and what it got back: bound or failed, tmux or
AppleScript or neither, hooks rewritten or already in sync. That covers the failures that are
otherwise invisible from outside, including the one where a click lands on the right *app* by luck
and the wrong tab — which looks identical to success unless something says no tab matched.

`DynamicIslandCore.LogLine` holds the format and the trim so both are testable without a disk.
Stamps carry milliseconds, because the questions this file answers are about order and latency and
second resolution collapses exactly the gaps worth seeing. The file is trimmed to its most recent
half at 1 MiB, cut at a line boundary — half rather than all so trimming is rare, and at a boundary
so the first surviving line is not a fragment that reads like corruption. Writes are queued off the
caller's thread: a logger that can break the thing it is observing is worse than no logger.

## Where view logic lives

The rule the `Views/` split is drifting toward: **the view owns what things look like, the core
owns what things are.** `DiffDetailView` is the worked example — `DynamicIslandCore.DiffLines`
decides whether a block is a diff and what kind each line is, and the view maps a kind to a colour.

That boundary is not tidiness. The one rule in there with a real edge case is that a block is only
read as a diff if it contains an **addition**: a detail made of markdown bullets (`- one`,
`- two`) is perfectly ordinary, and taking a leading `- ` as authoritative would paint every one
of them in delete-red as though the agent were removing them. An addition has no such collision.
While that lived in the view it could only be checked by looking at a screenshot.

**Verifying a refactor that must not change the picture:** capture the same UI before and after
and compare pixels — and then capture the *same build twice* as a control. Two captures of one
build differ, because text inside a `ScrollView` lands on a different sub-pixel offset each time.
On this one the control was noisier than the comparison (0.83% of pixels against 0.56%, in the
same bounding box), which says the remaining difference is the camera rather than the code.

## Conventions

- Pure Swift, no external dependencies — system frameworks only (Foundation, AppKit, SwiftUI, Network, ServiceManagement, Combine, CoreGraphics)
- SPM executable target (not Xcode project)
- Animations use SwiftUI `.spring(response:dampingFraction:)`
