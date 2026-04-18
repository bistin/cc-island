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

`hooks/island-hook.sh` is the canonical universal hook — handles Claude Code, GitHub Copilot, and OpenAI Codex by sniffing payload shape (`hook_event_name` vs `toolName`). Reads JSON from stdin, extracts fields per tool, and POSTs formatted events to `127.0.0.1:9423/event`. Must exit 0 so it never blocks the caller. `hooks/claude-hook.sh` is a legacy Claude-only version kept for reference.

Project label: derived from `cwd` basename; subagent events override it with `↳ <agent_type>`. A deterministic hash picks one of 8 palette colors so concurrent sessions are visually distinguishable.

## Permission Flow

`PermissionRequest` hook POSTs an `action`-style event (Permission title + tool detail), then long-polls `GET /response` for up to 25s. The UI buttons call `LocalServer.setResponse("allow"|"deny")`, which resumes the waiter. If no waiter is present the value is stored in `pendingResponse` for the next poll — but never persisted past a single delivery, to avoid stale clicks leaking into future requests. On timeout the hook exits silently and Claude Code falls back to its normal permission prompt.

The matcher in `settings.json` intentionally limits `PermissionRequest` to risky tools (`Bash|Edit|Write|MultiEdit|NotebookEdit`) — read-only tools like `Read`/`Grep`/`Glob` skip the island so subagents don't spam Allow/Deny.

## Conventions

- Pure Swift, no external dependencies — only Foundation, AppKit, SwiftUI, Network frameworks
- SPM executable target (not Xcode project)
- Animations use SwiftUI `.spring(response:dampingFraction:)`
