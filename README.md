# cc-island

把 iPhone 的 Dynamic Island 帶到 Mac 上。利用 MacBook 的瀏海（notch），在兩側即時顯示 AI coding agent 的動態。

支援 **Claude Code**、**GitHub Copilot**、**OpenAI Codex** — 一個 hook 腳本三家通吃。

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

## Features

- **瀏海融合** — 自動偵測螢幕瀏海尺寸，凹弧貼合圓角，無縫銜接
- **Thinking 脈動** — AI 思考中時瀏海下方呼吸光暈
- **Action 按鈕** — Claude Code 要你批准 Bash/Edit 時，直接在瀏海上 Allow/Deny，不用跳回 terminal
- **Reminder 提醒** — 需要注意但沒選項時（例如 Claude 問問題）藍色脈動閃爍
- **多 session 色標** — 同時跑多個 Claude Code，依 project 名稱自動配色區分；subagent 顯示為 `↳ agent_type`
- **三家 AI 整合** — Claude Code / GitHub Copilot / OpenAI Codex hooks
- **HTTP API** — `POST http://127.0.0.1:9423/event`，任何工具都能整合
- **自動適配** — 有瀏海用耳朵模式，沒瀏海用膠囊模式

---

## Installation

### Option A: Download Release（推薦）

1. 到 [Releases](https://github.com/bistin/cc-island/releases) 下載最新的 `DynamicIsland.zip`
2. 解壓縮，把 `DynamicIsland.app` 拖到 `/Applications/`
3. 打開 app：
   ```bash
   open /Applications/DynamicIsland.app
   ```

> App 不會出現在 Dock，它在背景運行。要關閉用 `pkill DynamicIsland`。

### Option B: From Source

需要 Xcode Command Line Tools（`xcode-select --install`）：

```bash
git clone https://github.com/bistin/cc-island.git
cd cc-island

# Build
swift build -c release

# Install as .app
mkdir -p build/DynamicIsland.app/Contents/{MacOS,Resources}
cp .build/release/DynamicIsland build/DynamicIsland.app/Contents/MacOS/
cp hooks/island-hook.sh build/DynamicIsland.app/Contents/Resources/
cp Info.plist build/DynamicIsland.app/Contents/
codesign --force --deep --sign - build/DynamicIsland.app
cp -R build/DynamicIsland.app /Applications/

# Launch
open /Applications/DynamicIsland.app
```

### Prerequisites

- macOS 13.0+
- `jq`（hook 腳本需要）：`brew install jq`

---

## Setup Hooks

啟動 app 後，設定你使用的 AI tool 的 hooks。

### Claude Code

在 `~/.claude/settings.json` 加入（如果已有 `hooks` 區塊，合併進去）：

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/island-hook.sh", "timeout": 5 }] }
    ],
    "PostToolUse": [
      { "matcher": "Bash|Edit|Write", "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/island-hook.sh", "timeout": 5 }] }
    ],
    "Notification": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/island-hook.sh", "timeout": 5 }] }
    ],
    "Stop": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/island-hook.sh", "timeout": 5 }] }
    ],
    "UserPromptSubmit": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/island-hook.sh", "timeout": 5 }] }
    ],
    "SubagentStart": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/island-hook.sh", "timeout": 5 }] }
    ],
    "SubagentStop": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/island-hook.sh", "timeout": 5 }] }
    ],
    "PermissionRequest": [
      { "matcher": "Bash|Edit|Write|MultiEdit|NotebookEdit", "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/island-hook.sh", "timeout": 30 }] }
    ]
  }
}
```

> The `PermissionRequest` matcher intentionally excludes read-only tools (`Read`, `Grep`, `Glob`). This avoids Allow/Deny popping up for trivial subagent actions — Claude Code's default permission flow handles them silently.

### GitHub Copilot (VS Code)

複製設定到 `~/.copilot/hooks/hooks.json`：

```bash
mkdir -p ~/.copilot/hooks
cp /Applications/DynamicIsland.app/Contents/Resources/island-hook.sh ~/.copilot/hooks/
```

然後建立 `~/.copilot/hooks/hooks.json`（或放在 repo 的 `.github/hooks/hooks.json`）：

```json
{
  "hooks": {
    "PreToolUse": [{ "type": "command", "command": "~/.copilot/hooks/island-hook.sh", "timeout": 5 }],
    "PostToolUse": [{ "type": "command", "command": "~/.copilot/hooks/island-hook.sh", "timeout": 5 }],
    "UserPromptSubmit": [{ "type": "command", "command": "~/.copilot/hooks/island-hook.sh", "timeout": 5 }],
    "Stop": [{ "type": "command", "command": "~/.copilot/hooks/island-hook.sh", "timeout": 5 }],
    "SessionStart": [{ "type": "command", "command": "~/.copilot/hooks/island-hook.sh", "timeout": 5 }]
  }
}
```

### OpenAI Codex

建立 `~/.codex/hooks.json`：

```json
{
  "hooks": {
    "PreToolUse": [{ "matcher": "", "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/island-hook.sh", "timeout": 5 }] }],
    "PostToolUse": [{ "matcher": "", "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/island-hook.sh", "timeout": 5 }] }],
    "UserPromptSubmit": [{ "matcher": "", "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/island-hook.sh", "timeout": 5 }] }],
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/island-hook.sh", "timeout": 5 }] }],
    "SessionStart": [{ "matcher": "", "hooks": [{ "type": "command", "command": "/Applications/DynamicIsland.app/Contents/Resources/island-hook.sh", "timeout": 5 }] }]
  }
}
```

在 `~/.codex/config.toml` 啟用 hooks：

```toml
[features]
codex_hooks = true
```

---

## Verify It Works

設定好之後，測試一下：

```bash
# 確認 app 在跑
curl -s http://127.0.0.1:9423/event \
  -d '{"title":"Hello","subtitle":"It works!","style":"success","duration":3}'
```

瀏海兩側應該會滑出 "Hello" / "It works!"。

之後正常使用 Claude Code / Copilot / Codex，瀏海就會即時顯示 AI 正在做什麼。

---

## What It Shows

| Event | Left Ear | Right Ear | Style |
|-------|----------|-----------|-------|
| User sends prompt | | Thinking glow | pulse |
| Read | Reading | filename | claude |
| Grep / Glob | Searching | pattern | claude |
| Edit | Editing | filename | claude |
| File saved | Saved | filename | success |
| Bash | Terminal | command | claude |
| Agent spawned | Agent | description | claude |
| Subagent activity | `↳ agent_type` label | tool details | claude |
| Permission needed (Bash/Edit/Write) | Permission | tool: detail + Allow/Deny buttons | action |
| Claude asks a question | Waiting | Your turn | reminder |
| Notification (non-permission) | Claude Code | message | reminder |
| Done | Done | | success |

---

## HTTP API

任何工具都能透過 HTTP 發送事件：

```bash
curl -X POST http://127.0.0.1:9423/event \
  -H "Content-Type: application/json" \
  -d '{"title":"Deploy","subtitle":"v1.2.3","style":"success","duration":5}'
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `title` | string | required | Left ear text |
| `subtitle` | string | `""` | Right ear text |
| `style` | string | `"claude"` | `info` / `success` / `warning` / `error` / `claude` / `action` / `reminder` |
| `duration` | number | `4.0` | Display seconds |
| `detail` | string | `null` | Expanded view content |
| `progress` | number | `null` | 0.0–1.0 progress bar |
| `persistent` | bool | `false` | Don't auto-dismiss (`true` for `action` style) |
| `type` | string | `"custom"` | `thinking_start` / `thinking_stop` for glow control |

---

## Common Commands

```bash
# Launch
open /Applications/DynamicIsland.app

# Restart
pkill DynamicIsland; open /Applications/DynamicIsland.app

# Quit
pkill DynamicIsland
```

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
├── claude-hook.sh           # Legacy Claude Code only hook
├── claude-settings-example.json
└── copilot-hooks.json       # Copilot hook config example
```

## License

MIT
