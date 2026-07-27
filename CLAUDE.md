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

Decision logic lives in `DynamicIslandCore.LoginItemState` so it's unit-testable without a live registration: `loginItemAction(for:desired:)` (what to call) and `loginItemPresentation(for:)` (what to render). Two states carry the non-obvious rules:

- `requiresApproval` — registered, but the user switched it off in System Settings. Calling `register()` again returns success and changes nothing, so the action is `.none` and the UI points at System Settings instead of leaving a toggle that silently springs back.
- `notFound` — despite the name, this is the ordinary never-registered state for a fresh `.app` on macOS 26 (verified on 26.5.2, unchanged by `lsregister -f`). Presented as a plain "off"; treating it as an error would fire a false alarm on every first launch.

Surfaces: Settings → General → Startup, the menu bar's "Open at Login" item, and `--login-item-status` (read-only; registration stays a deliberate user action so a stray CLI call can't add a login item). Running a bare `swift build` binary reports `unavailable` and disables the toggle — `Bundle.main` isn't an `.app` there, so there's nothing for `SMAppService` to register.

## Hook Integration

`Sources/island-hook/main.swift` is the canonical universal hook entry point — a Foundation-only Swift binary (~109KB) that handles Claude Code, GitHub Copilot, and OpenAI Codex by sniffing payload shape (`hook_event_name` casing vs `toolName` at root). Reads JSON from stdin, dispatches via `IslandHookCore` (pure-logic library, fully unit-tested), and POSTs formatted events to `127.0.0.1:9423/event`. Must exit 0 so it never blocks the caller. PermissionRequest is the only event that emits stdout (Claude Code's allow/deny JSON).

Project label: derived from `cwd` basename; subagent events override it with `↳ <agent_type>`. A deterministic hash picks one of 8 palette colors so concurrent sessions are visually distinguishable.

### Auto-install (HookInstaller.swift)

Hooks are auto-installed on first launch via an NSAlert (Install / Skip / Never), with the choice persisted in `UserDefaults["hookInstallChoice"]`. Subsequent launches silently sync via `syncIfOutdated`, which is idempotent and only writes when the deployed script or settings actually drift.

The binary is deployed to `~/.claude/hooks/dynamic-island-hook` (stable path independent of the .app location), and `~/.claude/settings.json` is updated non-destructively — entries from other tools (gemini-bridge etc.) are preserved by detecting "ours" via command path markers (`dynamic-island-hook` / `island-hook.sh` / `claude-hook.sh` / `DynamicIsland`). Drift detection: `currentlyInSync` byte-compares the deployed binary against the bundled source, so upgrading the .app triggers a redeploy on next launch.

CLI:
- `--install-hooks` / `--uninstall-hooks` — Claude Code (writes `~/.claude/settings.json`)
- `--install-copilot-hooks [repoPath]` / `--uninstall-copilot-hooks [repoPath]` — Copilot (writes `{repo}/.github/hooks/hooks.json`, defaults to cwd)

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

## Conventions

- Pure Swift, no external dependencies — only Foundation, AppKit, SwiftUI, Network frameworks
- SPM executable target (not Xcode project)
- Animations use SwiftUI `.spring(response:dampingFraction:)`
