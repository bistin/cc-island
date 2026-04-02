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
- Event queue in `IslandStateManager` — events are processed sequentially with spring animations between them

## Notch Dimensions (14" MBP)

- `notchWidth = 180pt`
- `notchHeight = 32pt`
- Concave corner radius: `10pt`
- Outer corner radius: `16pt`

## Hook Integration

`hooks/claude-hook.sh` reads JSON from stdin (Claude Code hook format), extracts relevant fields per tool type, and POSTs formatted events to `localhost:9423`. The script must exit 0 to not block Claude.

## Conventions

- Pure Swift, no external dependencies — only Foundation, AppKit, SwiftUI, Network frameworks
- SPM executable target (not Xcode project)
- Animations use SwiftUI `.spring(response:dampingFraction:)`
