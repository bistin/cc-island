# Dynamic Island for Mac

把 iPhone 的 Dynamic Island 帶到 Mac 上。利用 MacBook 的瀏海（notch），在兩側顯示即時通知與狀態，支援 Claude Code hooks 深度整合。

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

## Features

- **瀏海融合** — 黑色耳朵從瀏海兩側滑出，凹弧貼合圓角，視覺上與瀏海無縫銜接
- **Claude Code 整合** — 透過 hooks 即時顯示 Claude 正在讀檔、編輯、搜尋、跑指令等狀態
- **HTTP API** — `POST http://localhost:9423/event` 接收任意事件，可與任何工具整合
- **系統通知** — 音量變化、螢幕鎖定/解鎖、sleep/wake
- **動畫** — Spring 動畫滑入/滑出，點擊展開詳細內容

## Quick Start

```bash
# Build
swift build -c release

# Run
.build/release/DynamicIsland
```

### Install as App

```bash
# Build .app bundle
swift build -c release
mkdir -p build/DynamicIsland.app/Contents/{MacOS,Resources}
cp .build/release/DynamicIsland build/DynamicIsland.app/Contents/MacOS/
cp hooks/claude-hook.sh build/DynamicIsland.app/Contents/Resources/
cp Info.plist build/DynamicIsland.app/Contents/

# Sign and install
codesign --force --deep --sign - build/DynamicIsland.app
cp -R build/DynamicIsland.app /Applications/
```

## Claude Code Integration

將以下 hooks 加入 `~/.claude/settings.json`：

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/Applications/DynamicIsland.app/Contents/Resources/claude-hook.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash|Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "/Applications/DynamicIsland.app/Contents/Resources/claude-hook.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/claude-hook.sh", "timeout": 5 }]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/claude-hook.sh", "timeout": 5 }]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/claude-hook.sh", "timeout": 5 }]
      }
    ],
    "SubagentStart": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/claude-hook.sh", "timeout": 5 }]
      }
    ],
    "SubagentStop": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/claude-hook.sh", "timeout": 5 }]
      }
    ]
  }
}
```

設定後，Claude Code 的每個動作都會即時顯示在瀏海旁：

| Hook | 顯示 |
|------|------|
| 💬 UserPromptSubmit | Thinking... |
| 📖 Read | Reading → filename |
| 🔍 Grep / Glob | Searching → pattern |
| ✏️ Edit | Editing → filename |
| ✅ PostToolUse (Edit/Write) | Saved → filename |
| 💻 Bash | Terminal → command |
| 🤖 Agent | Agent → description |
| 🚀 SubagentStart | Agent spawned |
| ✨ Stop | Done |

## HTTP API

發送自訂事件到 Dynamic Island：

```bash
curl -X POST http://localhost:9423/event \
  -H "Content-Type: application/json" \
  -d '{
    "icon": "🚀",
    "title": "Deploy",
    "subtitle": "Production v1.2.3",
    "style": "success",
    "duration": 5,
    "detail": "All 42 tests passed",
    "progress": 0.75
  }'
```

### Event Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `title` | string | required | 左耳文字 |
| `subtitle` | string | `""` | 右耳文字 |
| `icon` | string | auto | Emoji icon |
| `style` | string | `"claude"` | `info` / `success` / `warning` / `error` / `claude` |
| `duration` | number | `4.0` | 顯示秒數 |
| `detail` | string | `null` | 展開後的詳細內容 |
| `progress` | number | `null` | 0.0–1.0 進度條 |

## Architecture

```
Sources/DynamicIsland/
├── App.swift               # NSApplication entry, AppDelegate
├── IslandPanel.swift        # NSPanel floating window (above menu bar)
├── IslandState.swift        # State manager, event queue, animations
├── IslandView.swift         # SwiftUI views (ears, expanded, fallback)
├── LocalServer.swift        # HTTP server (Network framework, port 9423)
└── NotificationMonitor.swift # macOS system notification listener

hooks/
├── claude-hook.sh           # Claude Code hook → Dynamic Island bridge
└── claude-settings-example.json
```

## Requirements

- macOS 13.0+
- MacBook with notch (14"/16" M-series) — also works without notch as a floating pill

## License

MIT
