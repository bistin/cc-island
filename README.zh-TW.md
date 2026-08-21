<div align="center">

# CLI Island

**讓 MacBook 的瀏海告訴你，你的 coding agent 在做什麼。**

Claude Code、GitHub Copilot、OpenAI Codex 把正在做的事推上瀏海——而且，在你同時開超過一個之後
才會發現真正重要的那件事：**哪一個 session 正在等你。**

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black.svg)](#安裝)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange.svg)](Sources)
[![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen.svg)](#安裝)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[English](README.md) · 繁體中文

<img src="docs/assets/waiting.png" width="720" alt="展開的瀏海：左耳 cc-island、右耳是問題，底下面板列出被問的選項。">

</div>

---

## 這是拿來解決什麼的

一個停下來問你問題的 agent，**每一秒沒被注意到都在付代價**。在一台機器的 transcript 裡量過：
58 次這種提問，回答時間**中位數 71 秒**，**最久 10.9 小時**。十小時不是在思考，是沒有人知道
它在問。

其餘的功能是同一件事的較輕版本：某個 session 現在在做什麼、你開的四個裡面是哪一個結束了、
它要的是一個權限還是一個答案。

**它只往你的 agent hook 目錄裝一個小 binary，沒別的**——沒有你沒啟動過的常駐程式、不用帳號、
除了 `127.0.0.1` 之外不連任何地方。

## 它會做什麼

### 說出哪個 session 在等你

<img src="docs/assets/waiting.png" width="640" alt="展開面板顯示一個問題和它的選項。">

`AskUserQuestion` 和 `ExitPlanMode` 是「執行等於有人在回答」的兩個工具。島會顯示問題和選項、
持續脈動，而且**不會自己消失**——一個到時間就不見的提醒比沒有更糟，因為它報告的事情並沒有
因此結束。點它會跳到那個 session 的終端機分頁，你用 tmux 的話會走 tmux 那條路。

它也擋得住你其他的 session：在有人被問的期間，另一個專案裡跑的 `Bash` 沒辦法把問題埋掉。

### 不用離開編輯器就能回答權限

<img src="docs/assets/permission.png" width="640" alt="展開面板顯示彩色 diff、Allow / Deny 按鈕，以及跳到終端機的那一列。">

Claude Code 要跑 `Bash` 或改檔案時，島會顯示**真正的 diff**，Allow / Deny 就在上面按。hook 會
長輪詢最多五分鐘，所以你可以走開再回來，按鈕還是活的；你一直不理它的話，它會讓開，Claude Code
照原本的方式問你。

### 其他的，簡單講

| 事件 | 左耳 | 右耳 |
|---|---|---|
| 你送出 prompt | | thinking 光暈 |
| Read / Grep / Glob | Reading、Searching | 檔名或 pattern |
| Edit / Write | Editing | 檔名，展開時附 diff |
| Bash | Terminal | 指令 |
| Subagent | `↳ agent_type` | 它在做什麼 |
| 長時間任務 | 標題 | `N/M` 和進度環，就地更新 |
| 結束 | Done | |

配色依來源分——Claude 橘、Copilot 紫、Codex 綠——同一個來源開多個時再依專案名稱分色。沒有瀏海
的螢幕改用膠囊，島也會跟著你的游標在螢幕之間搬家。

## 安裝

### 用 release

到 [Releases](https://github.com/bistin/cc-island/releases) 下載 `DynamicIsland.zip`，解壓後拖進
`/Applications`。它是 ad-hoc 簽名，第一次要**右鍵 → 打開**。

### 從原始碼

英文版有完整的建置步驟：[Build from source](README.md#from-source)。簡短版：

```bash
git clone https://github.com/bistin/cc-island.git
cd cc-island
swift build -c release
swift test
```

需要 macOS 13 以上和 Swift 5.9。**沒有任何第三方依賴**：只用 Foundation、AppKit、SwiftUI、
Network。

## Hooks

### Claude Code

第一次啟動會問你要不要裝。按 **Install** 就會把 hook binary 放到
`~/.claude/hooks/dynamic-island-hook`，並在 `~/.claude/settings.json` 註冊事件，**不會動到你
其他工具的 hook**。之後升級 app 再打開時會自動同步，沒變動就不寫。

```bash
DynamicIsland --install-hooks     # 安裝或升級
DynamicIsland --uninstall-hooks   # 移除
```

註冊的事件涵蓋 session 生命週期、工具使用、權限和 context 壓縮。`PermissionRequest` 刻意只限
會改動東西的工具——`Bash|Edit|Write|MultiEdit|NotebookEdit`——這樣 subagent 讀個檔案不會讓你
的瀏海塞滿 Allow / Deny。

### GitHub Copilot CLI

Copilot 的 hook 是**每個 repo 各自**的：

```bash
cd /path/to/your/repo
DynamicIsland --install-copilot-hooks           # 預設用目前目錄
DynamicIsland --uninstall-copilot-hooks [path]
```

會寫入 `{repo}/.github/hooks/hooks.json`，binary 放到 `~/.copilot/hooks/dynamic-island-hook`。
**那個 JSON 預設會被 git 追蹤**——不想 commit 給隊友就加進 `.gitignore`。

### OpenAI Codex

```bash
DynamicIsland --install-codex-hooks
DynamicIsland --uninstall-codex-hooks
```

放到 `~/.codex/hooks/dynamic-island-hook` 並寫 `~/.codex/hooks.json`；`config.toml` 裡如果還有
已淘汰的 `codex_hooks`，會一併遷移。裝完之後在 Codex 打 `/hooks` review 並 trust。Codex 是用
definition 的 hash 管信任，內容一改就會再問一次。

註冊範圍聚焦在 shell、檔案修改和生命週期，而不是每一個 MCP 呼叫，這樣瀏海才有用。

## 確認它有在動

```bash
curl -s -X POST http://127.0.0.1:9423/event \
  -H "Content-Type: application/json" \
  -d '{"title":"Hello","subtitle":"It works!","style":"success","duration":3}'
```

兩邊耳朵應該會滑出來。Settings → Diagnostics 有同樣的東西做成按鈕，還有權限流程測試和每個 hook
的安裝狀態。

## 開機自動啟動

Settings → General → Startup，或選單列的 **Open at Login**。用的是 `SMAppService`，開關由 macOS
持有，你隨時可以在「系統設定 → 一般 → 登入項目」關掉。

```bash
/Applications/DynamicIsland.app/Contents/MacOS/DynamicIsland --login-item-status
```

`enabled`、`notFound`（還沒開，全新安裝回報這個是正常的）、`requiresApproval`（已註冊但你在系統
設定關掉了，只有系統設定能解）、`unavailable`（你在跑 `swift build` 的裸 binary，沒有 bundle
就沒有登入項目）。

這個指令**唯讀**：註冊登入項目應該是一次刻意的點擊，不是腳本裡手滑的一行。

## HTTP API

任何能 POST 的東西都能用這個島。欄位表在[英文版](README.md#http-api)。

```bash
curl -X POST http://127.0.0.1:9423/event \
  -H "Content-Type: application/json" \
  -d '{"title":"Deploy","subtitle":"v1.2.3","style":"success","duration":5}'
```

用同一個 `title` 搭配新的 `progress` 再 POST 一次會**就地更新**而不是重新動畫，長任務就是這樣
串進度而不閃爍。

## 出問題的時候

`~/Library/Logs/CLI Island.log` 記下這個 app 原本沒辦法告訴你的事：listener 有沒有綁成功、hook
是被重寫還是本來就是最新的、一次點擊走了哪條路。它**只記路徑和結果**，不記某個 session 問了
什麼、檔案裡有什麼。

```bash
tail -f ~/Library/Logs/"CLI Island.log"

# 為什麼點了跳到錯的分頁？
DynamicIsland --reveal-tty /dev/ttys004 [--tmux-socket /path/to/socket]

# 這個版本對 Claude Code、tmux、macOS 做了哪些假設？
DynamicIsland --compat-table
```

[`docs/compatibility.md`](docs/compatibility.md) 就是最後那個做成頁面。**這個 app 讀的東西幾乎
沒有一樣是 API**——transcript 的排版、hook 的觸發順序、tmux 的 format string——而它們任何一個
改變，看起來都會像是這個 app 壞了。那一頁列出每一個從外面看起來會是什麼樣子。

## 架構

兩個不含 AppKit 的純邏輯 library、一個負責畫的 app、一個小到可以在每次工具呼叫都跑的 hook
binary。完整的檔案樹在[英文版](README.md#architecture)。

有三支腳本會在文件和程式碼不一致時讓 CI 紅燈，而且每一支都是**用破壞測試過**的，不是「看起來
會動」：`check-claimed-numbers.sh`（文件裡引用的數字）、`check-compatibility-doc.sh`（上面那一
頁，以及它指的檔案是否還存在）、`check-source-tree.sh`（那棵樹，雙向檢查）。

[`CLAUDE.md`](CLAUDE.md) 是長版：為什麼瀏海要那樣畫、為什麼 tmux 底下的 session 有兩個 tty、
哪些是實測出來的而不是假設的。

## 待辦

- 加固本機的 `/event` 與 `/response` API——每次啟動產生的 token 由 hook 帶上，並移除過寬的
  `Access-Control-Allow-Origin`。
- **在島上直接回答問題**，而不是跳去終端機。長輪詢的機制已經有了；卡住的是 `PreToolUse` 只能
  准或擋，所以選擇會以「被擋了，原因是⋯」的形式抵達 Claude，而不是一個答案。
- 繼續拆 `IslandView.swift`，把非渲染的邏輯往純邏輯 library 收。

## 授權

MIT — 見 [LICENSE](LICENSE)。
