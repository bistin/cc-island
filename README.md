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
- **Progress 即時更新** — 長任務串流進度到瀏海，同 title POST 就會就地更新、不會重新動畫；附 `swift build` wrapper
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

### Claude Code（推薦：自動安裝）

第一次啟動 app 時會跳出對話框問你要不要設定 Claude Code hooks。按 **Install** 就好，會自動：

- 把 `island-hook.sh` 複製到 `~/.claude/hooks/dynamic-island-hook.sh`
- 在 `~/.claude/settings.json` 註冊所有 hook 事件
- 保留你其他工具的 hook（例如 gemini-bridge）不會被動到

之後升級重新打開 app，hooks 會自動同步到最新版（idempotent，沒變動就不寫）。

也可以從 terminal 手動執行：

```bash
DynamicIsland --install-hooks       # 安裝 / 升級
DynamicIsland --uninstall-hooks     # 移除
```

> 註冊的事件涵蓋 PreToolUse / PostToolUse / PostToolUseFailure / PermissionRequest / PermissionDenied / Notification / Stop / StopFailure / SubagentStart / SubagentStop / UserPromptSubmit / SessionStart / SessionEnd / PreCompact / PostCompact。`PermissionRequest` matcher 限制在危險工具（`Bash|Edit|Write|MultiEdit|NotebookEdit`），唯讀工具不會跳 Allow/Deny。

### GitHub Copilot CLI

Copilot hooks 是 **per-repo** 的（寫進 `.github/hooks/hooks.json`），所以每個專案各自安裝：

```bash
cd /path/to/your/repo
DynamicIsland --install-copilot-hooks    # 預設使用 cwd
# 或明確指定路徑
DynamicIsland --install-copilot-hooks /path/to/repo
```

會在 `{repoPath}/.github/hooks/hooks.json` 寫入 Copilot 的 hook 設定（camelCase 事件、`version: 1`、`bash`/`timeoutSec` 欄位），並把腳本部署到全域的 `~/.copilot/hooks/dynamic-island-hook.sh`。

移除：

```bash
DynamicIsland --uninstall-copilot-hooks /path/to/repo
```

> ⚠️ `.github/hooks/hooks.json` 預設會被 git 追蹤。如果不想 commit 給隊友，加進 `.gitignore`。

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
| Long task with progress | title | `N/M` + ring (updates in place) | claude |
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
| `progress` | number | `null` | 0.0–1.0 progress bar / ring |
| `persistent` | bool | `false` | Don't auto-dismiss (`true` for `action` / `reminder`, or when `progress < 1.0`) |
| `type` | string | `"custom"` | `thinking_start` / `thinking_stop` for glow control |

### Progress updates

POST with the same `title` and `progress` swaps the progress in place without re-animating — use it to stream updates for a single long-running task. When `progress` reaches `1.0`, the event shows briefly then auto-dismisses.

```bash
for i in 0 25 50 75 100; do
  curl -s -X POST http://127.0.0.1:9423/event \
    -d "{\"title\":\"Upload\",\"subtitle\":\"$i/100\",\"progress\":$(awk "BEGIN{print $i/100}")}"
  sleep 0.5
done
```

`scripts/island-progress.sh` wraps this — pipe any command that prints `[N/M]` lines through it (e.g. `swift build 2>&1 | scripts/island-progress.sh Build`).

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
├── App.swift                # NSApplication entry, CLI parsing, NSAlert prompt
├── HookInstaller.swift      # Auto-install hooks for Claude Code & Copilot
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
