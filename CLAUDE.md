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

## Event Styles

- `info` / `success` / `warning` / `error` — standard notifications
- `claude` — warm orange, default for Claude Code tool events
- `action` — persistent, pulsing blue, expanded view with Allow/Deny buttons; used for `PermissionRequest`
- `reminder` — pulsing blue, no buttons; used when attention is needed but there's nothing to decide

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

`PermissionRequest` hook POSTs an `action`-style event (Permission title + tool detail), then long-polls `GET /response` for up to 25s. The UI buttons call `LocalServer.setResponse("allow"|"deny")`, which resumes the waiter. If no waiter is present the value is stored in `pendingResponse` for the next poll — but never persisted past a single delivery, to avoid stale clicks leaking into future requests. On timeout the hook exits silently and Claude Code falls back to its normal permission prompt.

The matcher in `settings.json` intentionally limits `PermissionRequest` to risky tools (`Bash|Edit|Write|MultiEdit|NotebookEdit`) — read-only tools like `Read`/`Grep`/`Glob` skip the island so subagents don't spam Allow/Deny.

### FIFO context correlation

`PreToolUse` for Edit/Write/Bash/MultiEdit/NotebookEdit caches its full payload to `/tmp/di_pretool_${PROJECT}.json`. The next `PermissionRequest` reads it to enrich the dialog: Edit/MultiEdit shows a colored diff (red `-` / green `+`), Write shows a content preview, Bash backfills the command/description if `tool_input` arrived empty. Keyed by project name, single-slot (the next PreToolUse overwrites) — works because PreToolUse and PermissionRequest fire serially per Claude session.

## Conventions

- Pure Swift, no external dependencies — only Foundation, AppKit, SwiftUI, Network frameworks
- SPM executable target (not Xcode project)
- Animations use SwiftUI `.spring(response:dampingFraction:)`
