# Claude Session HUD

一個懸浮在螢幕上、置頂顯示**所有正在執行的 Claude Code session** 的小視窗 —— 不分專案、不分 VS Code 視窗。

```
┌────────────────────────────────────────┐
│ Claude Sessions (4)                  ✕ │
├────────────────────────────────────────┤
│ ● 重構認證中介層                 閒置 │
│   my-api · my-api-a1 · 3h12            │
│ ● 修掉 CI 的快取失效問題       執行中 │
│   my-api · my-api-7c · 48m             │
│ ● 調整結帳頁的響應式版面         等你 │
│   web-client · web-client-b4 · 1h05    │
│ ● 規劃資料庫遷移步驟             閒置 │
│   notes-app · notes-app-e9 · 22m       │
└────────────────────────────────────────┘
```

每一列顯示：**對話標題**、所屬專案、session 代號、已開啟時間，以及狀態圓點與文字。
點任一列會把對應的編輯器視窗帶到前景。

## 需求

- **Windows**（用 WPF + Win32 API，不支援 macOS / Linux）
- Claude Code CLI 在 PATH 上
- Node.js（狀態 hooks 用）
- Windows PowerShell 5.1（系統內建；**不是** PowerShell 7 —— PS7 沒有 WinRT/WPF 的相同行為）

## 安裝

```bash
claude plugin marketplace add yam4863245/claude-session-hud
claude plugin install session-hud
```

安裝後 hooks 立即生效，但 **HUD 視窗要自己啟動**：

```
/session-hud
```

或直接雙擊外掛目錄裡的 `scripts/start-hud.vbs`。

### 開機自動啟動（可選）

按 `Win+R` 輸入 `shell:startup`，把 `scripts/start-hud.vbs` 的**捷徑**丟進去。
注意：外掛更新會換掉快取目錄，捷徑可能失效 —— 若要長期自啟，建議把 `scripts/` 複製到固定位置再建捷徑。

## 運作方式

| 元件 | 做什麼 |
|---|---|
| `scripts/session-hud.ps1` | HUD 本體。背景 runspace 每 3 秒跑 `claude agents --json`，UI 執行緒只負責繪製 |
| `scripts/status-hook.cjs` | 由 hooks 呼叫，把狀態寫到 `~/.claude/session-status/<sessionId>.json` |
| `hooks/hooks.json` | 四個全域事件 → 狀態：`UserPromptSubmit`=執行中、`Notification`=等你、`Stop`=閒置、`SessionEnd`=刪除 |
| `scripts/start-hud.vbs` | 無主控台啟動器 |

**對話標題**取自轉錄檔 `~/.claude/projects/<正規化cwd>/<sessionId>.jsonl` 裡最後一筆
`{"type":"ai-title","aiTitle":...}` 記錄。為了效能只讀檔案尾端 256KB，並用「檔案長度＋修改時間」當快取鍵。

執行期檔案都放在 `~/.claude/`，不寫回外掛目錄，所以外掛更新不會弄丟視窗位置：

```
~/.claude/session-status/<sessionId>.json   各 session 狀態
~/.claude/session-hud/hud-pos.json          視窗位置
~/.claude/session-hud/layout-diag.log       排版診斷（每次啟動重建）
```

## 已知限制

- **僅 Windows**。
- **點擊聚焦靠視窗標題比對**：找標題含 `- <專案資料夾名> -` 或 `- <專案資料夾名> (` 的視窗。VS Code、Cursor 這類會把資料夾名寫進標題的編輯器可用；純終端機的 session 通常找不到對應視窗。
- **同一個編輯器視窗裡的多個 session 無法區分** —— 點擊只能帶你到那個視窗，不能切到特定的終端機分頁。
- **已開著的 session 一開始顯示「未知」**，要等它下次送出提示或結束回合才會有狀態。
- 介面為繁體中文。

## 開發筆記

這個 host（Windows PowerShell 5.1 + WPF + `AllowsTransparency`）有幾個踩過的坑，改動前建議先看程式碼裡的註解：

- `Window.Width/Height` 是**實體像素**，但版面量測值（`ExtentHeight`／`ViewportHeight`／`ActualWidth`）是 **DIP**。在 125% 縮放下兩者差 1.25 倍，**兩軸都要換算**。
- WPF 的**命中測試座標也對不上**（點第 5 列會觸發第 6 列），所以列的點擊改用實體螢幕座標自己算索引，沒有綁在列元素上。
- 跨 runspace 傳回的陣列會被包成「單一元素、內容是整個陣列」：`.Count` 回 1、`foreach` 只跑一圈，但走管線卻會展開成 N 筆。用 `Expand-Sessions` 攤平。
- `SizeToContent="Height"` 在 `AllowsTransparency` + `NoResize` 下首次排版後就不再跟著內容變高。
- PowerShell 的 WPF 事件處理器會**靜默吞掉例外**，所以處理器內都自己包 try/catch 並寫 log。
- `.vbs` 必須是 **ASCII 且無 BOM**（cscript 不吃 UTF-8 BOM）；`.ps1` 反之必須**有 BOM**，否則 PS 5.1 會把中文讀成亂碼。

## 授權

MIT
