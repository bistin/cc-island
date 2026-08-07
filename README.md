# CLI Island

把 iPhone 的 Dynamic Island 帶到 Mac 上。利用 MacBook 的瀏海（notch），在兩側即時顯示 AI coding agent 的動態。

> repo 名稱仍是 `cc-island`，app 顯示名稱是 **CLI Island** — 因為它早就不只服務 Claude Code 了。bundle identifier、`.app` 檔名、hook 路徑都維持原樣，升級不會弄丟你的設定。

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
- **Menu bar icon** — 從選單列直接 Quit / Reinstall Claude Code Hooks / 切換開機自動啟動，不用 `pkill`
- **開機自動啟動** — Settings → General → Startup 打開後，登入 macOS 就在背景待命，不用記得手動開
- **HTTP API** — `POST http://127.0.0.1:9423/event`，任何工具都能整合
- **自動適配** — 有瀏海用耳朵模式，沒瀏海用膠囊模式
- **多螢幕跟隨游標** — 游標切到另一個螢幕停留 200ms，Island 會淡出淡入搬過去；`/event` 進來時也會立刻跳到游標所在螢幕。每個螢幕重新判斷 notch / 膠囊排版

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

# Run unit tests (264 tests: hook payload formatting, HTTP parser, screen resolver, and more)
swift test

# Render the app icon (AppKit only — no design tool needed)
swift scripts/render-app-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o AppIcon.icns

# Assemble .app bundle
mkdir -p build/DynamicIsland.app/Contents/{MacOS,Resources}
cp .build/release/DynamicIsland build/DynamicIsland.app/Contents/MacOS/
cp .build/release/island-hook   build/DynamicIsland.app/Contents/Resources/
chmod +x build/DynamicIsland.app/Contents/Resources/island-hook
cp AppIcon.icns build/DynamicIsland.app/Contents/Resources/
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

Codex hooks 也是全域安裝。現在可以直接用 CLI：

```bash
DynamicIsland --install-codex-hooks
```

它會自動：

- 把 `island-hook` binary 部署到 `~/.codex/hooks/dynamic-island-hook`
- 在 `~/.codex/hooks.json` 註冊 Codex 支援的事件
- Hooks 預設已啟用；若 `~/.codex/config.toml` 還有 deprecated 的 `codex_hooks`，會遷移成 canonical 的 `hooks`

安裝或更新 hook definition 後，在 Codex 輸入 `/hooks`，review 並 trust Dynamic Island hooks。Codex 會依 definition hash 管理信任，內容變更後需要重新確認。

移除：

```bash
DynamicIsland --uninstall-codex-hooks
```

產生的 `~/.codex/hooks.json` 會是官方 Codex hooks 文件格式，並透過 `ISLAND_SOURCE=codex` 讓 island 使用綠色配色。註冊事件如下：

- `SessionStart`（matcher: `startup|resume|clear|compact`）
- `PreToolUse`（matcher: `Bash|apply_patch`）
- `PermissionRequest`（matcher: `Bash|apply_patch`）
- `PostToolUse`（matcher: `Bash|apply_patch`）
- `PreCompact` / `PostCompact`
- `SubagentStart` / `SubagentStop`
- `UserPromptSubmit`
- `Stop`
- `SessionEnd`

> 預設聚焦 shell、檔案修改與生命週期事件，避免把所有 MCP/local tool activity 都推到瀏海造成干擾。Codex 目前也支援以 tool name matcher 監聽其他 local 與 MCP tools。

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

## 開機自動啟動

Settings → General → Startup 打開 **Open Dynamic Island at login**，或直接從 menu bar icon 點 **Open at Login**。用的是 macOS 13+ 的 `SMAppService`，登入項目由系統代管，你隨時可以在「系統設定 → 一般 → 登入項目」關掉。

想從終端機確認目前狀態：

```bash
/Applications/DynamicIsland.app/Contents/MacOS/DynamicIsland --login-item-status
```

- `enabled` — 登入時會自動啟動
- `notFound` / `notRegistered` — 還沒開啟（全新安裝回報 `notFound` 是正常的）
- `requiresApproval` — 已註冊但你在系統設定裡關掉了，只能回系統設定開，app 內的開關蓋不過去
- `unavailable` — 你在跑 `swift build` 出來的裸 binary，沒有 `.app` bundle 就沒有登入項目

> 這個指令是唯讀的。註冊動作只從 UI 觸發，避免手滑一行指令就多一個登入項目。

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

最常用的 Quit / Reinstall Claude Code Hooks 直接從 menu bar icon 點。CLI 操作：

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
DynamicIsland --install-codex-hooks              # Codex
DynamicIsland --uninstall-hooks
DynamicIsland --uninstall-copilot-hooks [path]
DynamicIsland --uninstall-codex-hooks
DynamicIsland --help
```

---

## Roadmap / Backlog

剩餘待辦，分三組。Done 的條目進 CHANGELOG，這裡只留 forward-looking 的 backlog。

### Reliability / Bugs

1. Harden local `/event` and `/response` API — 加 per-launch token 給 hooks 帶 header/env，並移除或限制 `Access-Control-Allow-Origin: *`。

### Refactor

2. Split `IslandView.swift` into smaller view files — 先拆 `NotchView` / `CapsuleView` / `DetailViews` / `ActionControls`，並把非 rendering logic 移出 view，對齊 view testability 的方向。
3. Extract testable event/state logic — `LocalServer` 專心做 HTTP framing/router，JSON → `IslandEvent` 轉換搬到 decoder；view 互動/queue 判斷則往 state manager 或 pure helper 收斂，方便 unit test。

### Features

4. Diagnostics menu/pane — 顯示 server port、hooks 是否 installed/current、deployed hook hash、最近 events。
5. Built-in self-test actions — Settings 加 `Send Test Event` / `Test Permission Flow` / `Test Codex Hook` 之類按鈕。

## Architecture

```
Sources/
├── DynamicIsland/                  # The app — AppKit + SwiftUI
│   ├── App.swift                       # entry, CLI, NSAlert install prompt, menu bar
│   ├── HookInstaller.swift             # installs Claude / Copilot / Codex hooks
│   ├── IslandPanel.swift               # NSPanel, per-screen notch detection, relocate()
│   ├── IslandState.swift               # state manager, immediate event display
│   ├── IslandView.swift                # SwiftUI views (ears, thinking pulse, source stripe)
│   ├── LocalServer.swift               # HTTP server (Network framework, port 9423)
│   ├── NotificationMonitor.swift       # macOS system notification listener
│   ├── NSScreen+Display.swift          # displayID / containing(_:) helpers
│   └── ScreenFollower.swift            # 50ms cursor poll + 200ms dwell debounce
├── IslandHookCore/                 # Pure-logic hook library (Foundation only)
│   ├── Format.swift                    # truncate, basename, diffLines, buildEditDiff
│   ├── HookPlan.swift                  # parseHookPlan + extension methods
│   └── PayloadBuilder.swift            # build{PreToolUse,PostToolUse,...}Payload
├── DynamicIslandCore/              # Pure-logic app library (Foundation only)
│   ├── HTTPParser.swift                # RFC 7230 request framing (duplicate CL / TE / oversize)
│   └── ScreenResolver.swift            # point-in-rect screen lookup
└── island-hook/                    # Tiny CLI binary deployed into each tool's hook dir
    └── main.swift                      # I/O shell — reads stdin, dispatches via core, POSTs

Tests/
├── IslandHookCoreTests/            # 68 tests — hook payload formatting
└── DynamicIslandCoreTests/         # 20 tests — HTTPParser (15) + ScreenResolver (5)

hooks/
└── claude-settings-example.json    # Reference config for manual setup
```

## License

MIT
