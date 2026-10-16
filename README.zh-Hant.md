# claude-memory

[![License](https://img.shields.io/github/license/howar31/claude-memory?style=flat-square)](LICENSE)
[![Built for Claude Code](https://img.shields.io/badge/built%20for-Claude%20Code-D77655?style=flat-square)](https://claude.com/claude-code)
[![Made with Bash](https://img.shields.io/badge/made%20with-bash-4EAA25?style=flat-square&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Conventional Commits](https://img.shields.io/badge/conventional%20commits-1.0.0-yellow?style=flat-square)](https://www.conventionalcommits.org)
[![Last Commit](https://img.shields.io/github/last-commit/howar31/claude-memory?style=flat-square)](https://github.com/howar31/claude-memory/commits/main)
[![Stars](https://img.shields.io/github/stars/howar31/claude-memory?style=flat-square)](https://github.com/howar31/claude-memory/stargazers)
[![Open Issues](https://img.shields.io/github/issues/howar31/claude-memory?style=flat-square)](https://github.com/howar31/claude-memory/issues)
[![Sponsor](https://img.shields.io/badge/%E8%B4%8A%E5%8A%A9-donate.howar31.com-b4532c?style=flat-square&logo=data:image/svg%2Bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZmlsbD0iI2ZmZiIgZD0iTTIwLjg0IDQuNjFhNS41IDUuNSAwIDAgMC03Ljc4IDBMMTIgNS42N2wtMS4wNi0xLjA2YTUuNSA1LjUgMCAwIDAtNy43OCA3Ljc4bDEuMDYgMS4wNkwxMiAyMS4yM2w3Ljc4LTcuNzggMS4wNi0xLjA2YTUuNSA1LjUgMCAwIDAgMC03Ljc4eiIvPjwvc3ZnPg==)](https://donate.howar31.com/)

[English](README.md) | 正體中文

給 [Claude Code](https://claude.com/claude-code) 內建 auto-memory 用的三個 skill：**讀取**用的 skill 跨專案查詢記憶，**寫入**用的 skill 依需求稽核當前對話，**維護**用的 skill 讓每個專案的記憶 index 維持在自動載入上限內。三者都直接操作既有的 `~/.claude/projects/<project>/memory/` 檔案，不需要 vector database、MCP server 或任何外部服務。

## 功能

### 讀取：`/recall` skill

Claude Code 的 auto-memory 以專案區分：每個 git repo 一個記憶資料夾，repo 內所有子目錄和 worktree 共用；不在 git repo 裡時，每個專案目錄一個。在某個 repo 寫下的記憶，從其他 repo、或從包含多個 repo 的上層資料夾都看不到，即使主題相同也一樣。Claude Code 啟動時只會自動載入**目前**專案的 `MEMORY.md`。

`/recall` 在需要時補上這一塊：它對每個 `~/.claude/projects/*/memory/`（以及 subagent 記憶、設定中找到的 `autoMemoryDirectory`）grep 主題、讀取相關記憶，並根據內容回答，同時註明每筆記憶來自哪個專案。

```text
/recall <主題>      → 在所有專案的記憶中搜尋主題並回報
/recall             → 從對話推斷主題（不明確時先詢問）
```

查詢發生在**提問當下**（grep 只回傳符合的部分），而不是在啟動時注入完整 index，所以它占用的 context 不會隨記憶總量增加。這個 skill 可由模型自動呼叫，description 要求模型經常呼叫它：提到其他專案的過往工作時、詢問記得什麼時，以及開始一件跟過去相似的工作時。它只讀不寫。

### 寫入：`/memorize` skill

Claude Code 的 auto-memory 寫入由提示驅動：模型在對話中自行判斷內容值不值得保存，有時會沒注意到。`/memorize` 是明確的觸發方式：它依四種記憶類別（`user`、`feedback`、`project`、`reference`）稽核目前的 session，並寫入記憶。

預設直接寫入。加上 `dry` 會先預覽，確認後才寫入：

```text
/memorize                          → 稽核並直接寫入
/memorize <重點提示>               → 寫入，優先處理符合提示的內容
/memorize dry                      → 列出擬寫入的記憶，等待確認
/memorize dry <重點提示>           → 預覽，並聚焦在提示內容
```

這個 skill 也可由模型自動呼叫，description 要求模型在對話可能產生值得保存的內容時執行（修正、確認過的選擇、新的領域脈絡、專案狀態變更）。它會先讀取既有記憶，有重複就更新而不新增；稽核後沒有寫入任何東西也是正常結果。

### 維護：`/tidy` skill

Claude Code 在 session 開始時只載入專案 `MEMORY.md` 的前 200 行或前 25KB，超過的部分會直接被捨棄，不會有任何提示。另外，如果 session 通常開在包含多個 repo 的上層資料夾，記憶會集中累積在那裡，而在其中某個 repo 裡開的 session 看不到這些記憶。

`/tidy` 會量測 index 大小、檢查失效連結和沒有列在 index 的記憶，並對每筆記憶提出一個處理方式：

- **archive（封存）**：已結案的項目移出 index；檔案保留並標記 `archived:`，`/recall` 仍查得到
- **group（合併）**：同一類的多筆記錄（例如每個人的存取權限授予）收進一個總覽記憶，index 只留一行
- **move（搬移）**：跟單一 repo 程式碼有關的記憶搬到該 repo 的記憶資料夾，上層資料夾的 index 留一行指標，列出那裡有哪些主題
- **shorten / fix（縮短／修正）**：過長的 index 行、失效連結、沒有列在 index 的檔案

你核准提案之前不會有任何變更。檔案不會被刪除，動到的資料夾會在變更前先備份。

```text
/tidy               → 量測、分類、提案；核准後執行
/tidy <重點提示>    → 同上，優先處理指定的 repo 或主題
/tidy check         → 唯讀健康檢查
```

三個 skill 都是補強內建的 auto-memory，不是取代它。設計理由、先前的 SessionStart hook 為何移除、評估過的替代方案（mem-palace、Obsidian、OpenClaw、muse-crystal-seed、Letta、Mem0、Zep），以及跟 Anthropic Memory Tool（2025-09-29 為 API 推出）的關係，請見 [SPEC.md](SPEC.md)。

## 架構

```
/recall skill    -->  在 ~/.claude/projects/*/memory/ grep 主題
                      讀取符合的記憶；回答時註明來源專案

/memorize skill  -->  依四種記憶類別稽核目前 session；
                      寫入記憶並更新 MEMORY.md

/tidy skill      -->  依載入上限量測 MEMORY.md；對每筆記憶
                      提出封存／合併／搬移；核准後執行
```

安裝的檔案：

```
~/.claude/skills/recall/      /recall skill     (symlink → repo)
~/.claude/skills/memorize/    /memorize skill   (symlink → repo)
~/.claude/skills/tidy/        /tidy skill       (symlink → repo)
~/.claude/system/memory       symlink → repo    (operational pointer)
```

不會安裝 hook，也不會修改 `settings.json`。如果你裝過舊的 hook 版本，`setup.sh` 會移除舊 hook 和它在 `settings.json` 裡的設定（見〈快速開始〉）。

## 快速開始

### 1. Clone repo

```bash
git clone https://github.com/howar31/claude-memory
```

位置可以自訂，安裝程式會自己解析所在路徑，放在哪裡都能執行。

### 2. 安裝

```bash
cd claude-memory && ./setup.sh
```

安裝程式是冪等的，可以重複執行。它會：

- 移除舊版安裝留下的 `SessionStart` hook（symlink 和 `settings.json` 設定，移除前先備份）
- 把 `recall`、`memorize`、`tidy` 三個 skill 目錄 symlink 到 `~/.claude/skills/`（原本若有實體目錄會先備份）
- 建立 `~/.claude/system/memory` → repo
- 執行驗證，確認 skill symlink、`SKILL.md` frontmatter 都正確，且沒有殘留舊 hook

遇到無法安全自動處理的情況（skill 路徑上已有實體目錄），安裝程式會停下來並說明處理方式，備份也已經先做好。

### 3. 驗證

```bash
./setup.sh           # 隨時可重新執行；回報檢查結果或指出問題
./setup.sh --dry-run # 預覽，不實際執行
./setup.sh --force   # 取代 ~/.claude/skills/ 下不符的目錄
```

更新時在 clone 目錄執行 `git pull` 即可：已安裝的 skill 是 symlink，Claude Code 會直接讀到新檔案。只有新版本加入新的 skill 目錄，或 symlink 不見時，才需要重新執行 `setup.sh`。

### 4. 開始使用

Skill 會動態載入；如果 `/recall`、`/memorize`、`/tidy` 沒有馬上出現，在進行中的 session 執行 `/reload-plugins`。不需要重新啟動（沒有 hook 要載入）。

## 以 plugin 安裝（替代方式）

如果你偏好用 Claude Code 的 plugin manager，而不是 symlink 安裝程式，同一組 skill 也以 `mem` plugin 發布。plugin 管理的 skill 會加上**命名空間**，名稱是 `/mem:recall`、`/mem:memorize`、`/mem:tidy`（上面的 `setup.sh` 方式名稱較短：`/recall`、`/memorize`、`/tidy`；比較見下表）。

兩種註冊方式安裝的是同一個 plugin，擇一即可。

**獨立 marketplace**（這個 repo 本身就是 marketplace）：

```bash
claude plugin marketplace add howar31/claude-memory
claude plugin install mem@claude-memory
```

**中央 marketplace**（howar31 的所有 plugin；註冊一次，之後的新 plugin 會自動出現）：

```bash
claude plugin marketplace add howar31/howar31-marketplace
claude plugin install mem@howar31
```

### 該用哪種安裝方式？

| | `setup.sh`（symlink） | plugin（`mem`） |
|---|---|---|
| 指令名稱 | `/recall`、`/memorize`、`/tidy`（最短） | `/mem:recall`、`/mem:memorize`、`/mem:tidy` |
| 安裝／更新 | clone 後執行 `setup.sh`；更新用 `git pull` | `claude plugin install` / `update` |
| 可在 marketplace 找到 | 否 | 是 |
| 非 Claude 的 harness | 可用（一般 skill 目錄） | 取決於該 harness 是否支援 plugin |

兩種方式擇一安裝；同時安裝會讓同一組 skill 出現兩個名稱。

這三個 skill 不透過 `npx skills` 發布：它們都操作 Claude Code 自己的記憶資料夾，裝到其他 agent 沒有東西可以處理。

## 使用情境

當你提到其他專案的過往工作（「我們在另一個 repo 怎麼解決 X 的？」「找一下我對 Y 的偏好」），Claude 會呼叫 `/recall`，grep 每個專案的記憶，根據符合的內容回答並註明來源專案。你也可以直接執行 `/recall <主題>`。

想把 session 內容留給以後時，執行 `/memorize`（或用 `/memorize dry` 先看提案）。記憶會寫進 Claude Code 為目前專案使用的記憶資料夾（預設是 `~/.claude/projects/<project>/memory/`，`<project>` 是 repo 路徑把非英數字元換成 `-`），目前 session 的自動載入和之後的 `/recall` 搜尋都會用到。

當某個專案的 `MEMORY.md` 超過載入上限的約 60%，或 Claude Code 提示已接近上限時，執行 `/tidy`（或用 `/tidy check` 取得唯讀報告）。

## 備份

`~/.claude/skills/` 下的 skill 目錄和 `~/.claude/system/memory` 都是指回 repo 的 symlink，所以 repo 是唯一的資料來源，只要備份涵蓋這個 clone 就包含在內。

如果你也用 [`claude-backup`](https://github.com/howar31/claude-backup) 備份 `~/.claude/`，這些 symlink 也會一併備份。

## 解除安裝

```bash
# 移除 skill symlink（若曾取代實體目錄，備份在 ~/.claude/skills/.bak/<timestamp>/）
rm ~/.claude/skills/recall
rm ~/.claude/skills/memorize
rm ~/.claude/skills/tidy
rm ~/.claude/system/memory
```

如果是用 plugin 安裝：

```bash
claude plugin uninstall mem@claude-memory   # 或 mem@howar31
```

`settings.json` 不需要還原；目前的版本不會寫入它。

## 參考

- [SPEC.md](SPEC.md)：架構、設計決策、評估過的替代方案、skill 規格、未來擴充
- [CLAUDE.md](CLAUDE.md)：在這個 repo 工作的 agent 索引

## 授權

MIT
