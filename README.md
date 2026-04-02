# cc-island

把 iPhone 的 Dynamic Island 帶到 Mac 上。利用 MacBook 的瀏海（notch），在兩側顯示即時通知與狀態。

支援 **Claude Code**、**GitHub Copilot**、**OpenAI Codex** — 一個 hook 腳本三家通吃。

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

## Features

- **瀏海融合** — 自動偵測螢幕瀏海尺寸，凹弧貼合圓角，無縫銜接
- **Thinking 脈動** — AI 思考中時瀏海下方呼吸光暈
- **Action 提醒** — 需要你操作時藍色閃爍，不會自動消失
- **三家 AI 整合** — Claude Code / GitHub Copilot / OpenAI Codex hooks
- **HTTP API** — `POST http://127.0.0.1:9423/event`，任何工具都能整合
- **自動適配** — 有瀏海用耳朵模式，沒瀏海用膠囊模式

## Quick Start

```bash
swift build -c release
.build/release/DynamicIsland
```

### Install as App

```bash
swift build -c release
mkdir -p build/DynamicIsland.app/Contents/{MacOS,Resources}
cp .build/release/DynamicIsland build/DynamicIsland.app/Contents/MacOS/
cp hooks/island-hook.sh build/DynamicIsland.app/Contents/Resources/
cp Info.plist build/DynamicIsland.app/Contents/

codesign --force --deep --sign - build/DynamicIsland.app
cp -R build/DynamicIsland.app /Applications/
```

## Hook Integration

一個 `island-hook.sh` 通用腳本，自動偵測 Claude Code / Copilot / Codex。

### Claude Code

加入 `~/.claude/settings.json`：

```json
{
  "hooks": {
    "PreToolUse": [{ "matcher": "", "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/island-hook.sh", "timeout": 5 }] }],
    "PostToolUse": [{ "matcher": "Bash|Edit|Write", "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/island-hook.sh", "timeout": 5 }] }],
    "Notification": [{ "matcher": "", "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/island-hook.sh", "timeout": 5 }] }],
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/island-hook.sh", "timeout": 5 }] }],
    "UserPromptSubmit": [{ "matcher": "", "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/island-hook.sh", "timeout": 5 }] }],
    "SubagentStart": [{ "matcher": "", "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/island-hook.sh", "timeout": 5 }] }],
    "SubagentStop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/island-hook.sh", "timeout": 5 }] }]
  }
}
```

### GitHub Copilot

放到 `~/.copilot/hooks/hooks.json` 或 `.github/hooks/hooks.json`，格式參考 `hooks/copilot-hooks.json`。

### OpenAI Codex

放到 `~/.codex/hooks.json` 或 `.codex/hooks.json`，同樣格式。需在 `config.toml` 啟用：

```toml
[features]
codex_hooks = true
```

## What It Shows

| Event | Left Ear | Right Ear |
|-------|----------|-----------|
| User sends prompt | | Thinking glow |
| Read | Reading | filename |
| Grep / Glob | Searching | pattern |
| Edit | Editing | filename |
| Write saved | Saved | filename |
| Bash | Terminal | command |
| Agent spawned | Agent | description |
| Needs action | Action needed | message (pulsing blue) |
| Done | Done | |

## HTTP API

```bash
curl -X POST http://127.0.0.1:9423/event \
  -H "Content-Type: application/json" \
  -d '{"title":"Deploy","subtitle":"v1.2.3","style":"success","duration":5}'
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `title` | string | required | Left ear text |
| `subtitle` | string | `""` | Right ear text |
| `style` | string | `"claude"` | `info` / `success` / `warning` / `error` / `claude` / `action` |
| `duration` | number | `4.0` | Display seconds |
| `detail` | string | `null` | Expanded view content |
| `progress` | number | `null` | 0.0–1.0 progress bar |
| `persistent` | bool | `false` | Don't auto-dismiss (true for `action` style) |
| `type` | string | `"custom"` | `thinking_start` / `thinking_stop` for glow control |

## Architecture

```
Sources/DynamicIsland/
├── App.swift                # NSApplication entry, AppDelegate
├── IslandPanel.swift        # NSPanel, auto-detect notch dimensions
├── IslandState.swift        # State manager, immediate event display
├── IslandView.swift         # SwiftUI views (ears, thinking pulse, expanded)
├── LocalServer.swift        # HTTP server (Network framework, port 9423)
└── NotificationMonitor.swift # macOS system notification listener

hooks/
├── island-hook.sh           # Universal hook (Claude Code + Copilot + Codex)
├── claude-hook.sh           # Legacy Claude Code hook
├── claude-settings-example.json
└── copilot-hooks.json       # Copilot hook config example
```

## Requirements

- macOS 13.0+
- MacBook with notch (any M-series) — auto-detects notch dimensions
- Also works without notch as a floating pill
- `jq` required for hook scripts

## License

MIT
