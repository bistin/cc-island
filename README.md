# cc-island

把 iPhone 的 Dynamic Island 帶到 Mac 上。利用 MacBook 的瀏海（notch），在兩側即時顯示 AI coding agent 的動態。

支援 **Claude Code**、**GitHub Copilot**、**OpenAI Codex** — 一個 hook binary 三家通吃，零外部依賴。

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

## Features

- **瀏海融合** — 自動偵測螢幕瀏海尺寸，凹弧貼合圓角，無縫銜接
- **Source 配色** — Claude Code 暖橘 / Copilot 紫 / Codex 綠，左右兩側色條 + 呼吸燈一眼分辨來源
- **Thinking 脈動** — AI 思考中時瀏海下方呼吸光暈
- **Action 按鈕** — Claude Code 要你批准 Bash/Edit 時，直接在瀏海上 Allow/Deny，不用跳回 terminal；展開預覽顯示真實 diff
- **Reminder 提醒** — Claude 問問題時把實際問題秀在右耳，不只是 "Your turn"
- **Progress 即時更新** — 長任務串流進度到瀏海，同 title POST 就會就地更新、不會重新動畫；附 `swift build` wrapper
- **多 session 色標** — 同時跑多個 session，依 project 名稱自動配色區分；subagent 顯示為 `↳ agent_type`
- **三家 AI 整合** — Claude Code / GitHub Copilot / OpenAI Codex hooks，自動偵測來源
- **Menu bar icon** — 從選單列直接 Quit / Reinstall Hooks，不用 `pkill`
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

> App 不會出現在 Dock，但會在 menu bar 顯示一個小 island icon — 點開可以 Quit / Reinstall Hooks。

### Option B: From Source

需要 Xcode Command Line Tools（`xcode-select --install`）：

```bash
git clone https://github.com/bistin/cc-island.git
cd cc-island

# Build (produces both DynamicIsland app and the hook binary)
swift build -c release

# Run unit tests (68 tests covering hook payload formatting)
swift test

# Assemble .app bundle
mkdir -p build/DynamicIsland.app/Contents/{MacOS,Resources}
cp .build/release/DynamicIsland build/DynamicIsland.app/Contents/MacOS/
cp .build/release/island-hook   build/DynamicIsland.app/Contents/Resources/
chmod +x build/DynamicIsland.app/Contents/Resources/island-hook
cp Info.plist build/DynamicIsland.app/Contents/
codesign --force --deep --sign - build/DynamicIsland.app
cp -R build/DynamicIsland.app /Applications/

# Launch
open /Applications/DynamicIsland.app
```

### Prerequisites

- macOS 13.0+

> 從 v1.5.0 起 hook 改成 Swift binary，**不再需要 `jq`**。

---

## Setup Hooks

### Claude Code（推薦：自動安裝）

第一次啟動 app 時會跳出對話框問你要不要設定 Claude Code hooks。按 **Install** 就好，會自動：

- 把 `island-hook` binary 部署到 `~/.claude/hooks/dynamic-island-hook`
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

會在 `{repoPath}/.github/hooks/hooks.json` 寫入 Copilot 的 hook 設定（camelCase 事件、`version: 1`、`bash`/`timeoutSec` 欄位），並把 binary 部署到全域的 `~/.copilot/hooks/dynamic-island-hook`。

移除：

```bash
DynamicIsland --uninstall-copilot-hooks /path/to/repo
```

> ⚠️ `.github/hooks/hooks.json` 預設會被 git 追蹤。如果不想 commit 給隊友，加進 `.gitignore`。

### OpenAI Codex

目前沒有 auto-install，需要手動設定。先把 hook binary 取出來：

```bash
mkdir -p ~/.codex/hooks
cp /Applications/DynamicIsland.app/Contents/Resources/island-hook ~/.codex/hooks/dynamic-island-hook
chmod +x ~/.codex/hooks/dynamic-island-hook
```

然後建立 `~/.codex/hooks.json`（指向上面的 binary，並設 `ISLAND_SOURCE=codex` 讓 island 用綠色配色）：

```json
{
  "hooks": {
    "PreToolUse":       [{ "matcher": "", "hooks": [{ "type": "command", "command": "ISLAND_SOURCE=codex ~/.codex/hooks/dynamic-island-hook", "timeout": 5 }] }],
    "PostToolUse":      [{ "matcher": "", "hooks": [{ "type": "command", "command": "ISLAND_SOURCE=codex ~/.codex/hooks/dynamic-island-hook", "timeout": 5 }] }],
    "UserPromptSubmit": [{ "matcher": "", "hooks": [{ "type": "command", "command": "ISLAND_SOURCE=codex ~/.codex/hooks/dynamic-island-hook", "timeout": 5 }] }],
    "Stop":             [{ "matcher": "", "hooks": [{ "type": "command", "command": "ISLAND_SOURCE=codex ~/.codex/hooks/dynamic-island-hook", "timeout": 5 }] }],
    "SessionStart":     [{ "matcher": "", "hooks": [{ "type": "command", "command": "ISLAND_SOURCE=codex ~/.codex/hooks/dynamic-island-hook", "timeout": 5 }] }]
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
| Permission needed (Bash/Edit/Write) | Permission | tool: detail + Allow/Deny buttons + diff preview | action |
| Claude asks a question | Waiting | the actual question text (full text in expanded view) | reminder |
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

最常用的 Quit / Reinstall Hooks 直接從 menu bar icon 點。CLI 操作：

```bash
# Launch
open /Applications/DynamicIsland.app

# Restart
pkill DynamicIsland; open /Applications/DynamicIsland.app

# Quit (or use menu bar icon)
pkill DynamicIsland

# Hook management (auto-prompt also runs on first launch)
DynamicIsland --install-hooks                    # Claude Code
DynamicIsland --install-copilot-hooks [path]     # Copilot, defaults to cwd
DynamicIsland --uninstall-hooks
DynamicIsland --uninstall-copilot-hooks [path]
DynamicIsland --help
```

## Architecture

```
Sources/
├── DynamicIsland/                  # The app — AppKit + SwiftUI
│   ├── App.swift                       # entry, CLI, NSAlert install prompt, menu bar
│   ├── HookInstaller.swift             # auto-install hooks for Claude Code & Copilot
│   ├── IslandPanel.swift               # NSPanel, auto-detect notch dimensions
│   ├── IslandState.swift               # state manager, immediate event display
│   ├── IslandView.swift                # SwiftUI views (ears, thinking pulse, source stripe)
│   ├── LocalServer.swift               # HTTP server (Network framework, port 9423)
│   └── NotificationMonitor.swift       # macOS system notification listener
├── IslandHookCore/                 # Pure-logic library (Foundation only, fully tested)
│   ├── Format.swift                    # truncate, basename, diffLines, buildEditDiff
│   ├── HookPlan.swift                  # parseHookPlan + extension methods
│   └── PayloadBuilder.swift            # build{PreToolUse,PostToolUse,...}Payload
└── island-hook/                    # Tiny CLI binary deployed to ~/.claude/hooks/
    └── main.swift                      # I/O shell — reads stdin, dispatches via core, POSTs

Tests/
└── IslandHookCoreTests/            # 68 unit tests (`swift test`)

hooks/
└── claude-settings-example.json    # Reference config for manual setup
```

## License

MIT
