# Claude Session HUD

一個懸浮在螢幕上、置頂顯示**所有正在執行的 Claude Code session** 的小視窗 —— 不分專案、不分 VS Code 視窗。

```
┌────────────────────────────────────────┐
│ Claude Sessions (4)                ─ ✕ │
├────────────────────────────────────────┤
│ ● 重構認證中介層               已完成 │
│   my-api · my-api-a1 · 3h12            │
│ ● 修掉 CI 的快取失效問題       執行中 │
│   my-api · my-api-7c · 48m             │
│ ● 調整結帳頁的響應式版面         等你 │
│   web-client · web-client-b4 · 1h05    │
│ ● 規劃資料庫遷移步驟             閒置 │
│   notes-app · notes-app-e9 · 22m       │
├────────────────────────────────────────┤
│ 5 小時用量            9%  12:40 重置 │
│ ███░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
└────────────────────────────────────────┘
```

每一列顯示：**對話標題**、所屬專案、session 代號、已開啟時間，以及狀態圓點與文字。
點任一列會把對應的編輯器視窗帶到前景，**並切換到該 session 的分頁**。

平常視窗是半透明的，滑鼠移上去才會變清楚 —— 它永遠置頂，不該一直擋住底下的東西。

標題列的 **─ 可以把 HUD 縮小成只剩標題列**（還是看得到 session 數、也照樣播通知音），
再點一次（會變成 □）就展開回來。

底部顯示**目前 5 小時視窗的用量**（就是 `/usage` 的那個數字）與重置時間，60% 轉橙、85% 轉紅。

## 狀態

| 狀態 | 什麼時候 |
|---|---|
| **執行中** | 你送出提示後，Claude 正在跑（狀態文字右邊有持續旋轉的圈圈） |
| **需要我做決定** | Claude 丟了選項出來等你選 |
| **等你** | 卡在權限授權等一般提示上 |
| **已完成** | 回合跑完了，但你還沒回頭看 |
| **閒置** | 跑完而且你已經看過了 |
| **未知** | 這個 session 在 hooks 裝好之前就開著了 |

「已完成」會在你把那個 session 切到前景時自動變成「閒置」，所以掃一眼 HUD 就知道哪些回合還沒收。

**兩種情況會播 Windows 通知音**，而且用不同的音，不看畫面也分得出來：

| 什麼時候 | 音效 |
|---|---|
| 回合跑完（→ 已完成） | 系統「星號」 |
| Claude 丟問題出來（→ 需要我做決定） | 系統「驚嘆號」 |

音效跟著 Windows 的音效配置走，所以在「設定 → 系統 → 音效 → 更多音效設定」把配置改成「無音效」
就會全部安靜；只想關 HUD 這邊的話，把 `scripts/session-hud.ps1` 裡的 `$SOUND_ON_DONE` /
`$SOUND_ON_ASKING` 改成 `$false`。

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
| ↳ 佔位行程過濾 | VS Code 外掛會預先開好備用的 `claude` 行程，它們會出現在 `claude agents --json` 裡但沒有任何對話 —— 沒有轉錄檔也沒有狀態檔的一律不列出 |
| `scripts/status-hook.cjs` | 由 hooks 呼叫，把狀態寫到 `~/.claude/session-status/<sessionId>.json` |
| `hooks/hooks.json` | 全域事件 → 狀態：`UserPromptSubmit`=執行中、`PreToolUse[AskUserQuestion]`=需要我做決定、`PostToolUse[AskUserQuestion]`=執行中、`Notification`=等你、`Stop`=已完成、`SessionEnd`=刪除 |
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
- **切分頁與「已完成→閒置」都靠對話標題**：分頁名稱與視窗標題裡的都是對話標題，所以還沒產生標題的新 session 只會被帶到視窗、不會切分頁，狀態也不會自動降級。同一視窗裡兩個 session 標題剛好一樣時也分不出來。
- **切分頁會讓該 VS Code 視窗開啟完整無障礙樹**（跟裝了螢幕閱讀器一樣），那個視窗的記憶體與 CPU 會略微上升，直到 VS Code 重開。只有真的點了列才會發生。
- **已開著的 session 一開始顯示「未知」**，要等它下次送出提示或結束回合才會有狀態。
- **5 小時用量不是即時值**。它讀的是 Claude Code 自己寫在 `~/.claude.json` 的 `cachedUsageUtilization` 快取，更新時機由 Claude Code 決定（實測可能落後兩小時以上），HUD 沒有辦法叫它更新。所以超過 15 分鐘沒更新時，標籤會標上「幾分鐘前」。這個數字是**帳號層級**的，不是單一 session 的用量。
- 介面為繁體中文。

## 開發筆記

這個 host（Windows PowerShell 5.1 + WPF + `AllowsTransparency`）有幾個踩過的坑，改動前建議先看程式碼裡的註解：

- `Window.Width/Height` 是**實體像素**，但版面量測值（`ExtentHeight`／`ViewportHeight`／`ActualWidth`）是 **DIP**。在 125% 縮放下兩者差 1.25 倍，**兩軸都要換算**。
- 承上，**版面裡不能有「填滿剩餘空間」的元素**（`Height="*"`、`VerticalAlignment="Stretch"`）。WPF 會拿 325 這個實體像素的數字當成 325 DIP 來排版，但看得到的只有 260 DIP，多出來的 65 DIP 會被那個元素吃掉，排在它下面的東西**整條被推到視窗外**（不是裁一半，是完全消失）。全部改成 `Auto` + `MaxHeight` 就沒事。
- **視窗高度不要用「剩餘空間」反推**（`win.ActualHeight - viewport`）：viewport 本來就是 `win.Height` 決定的，拿結果推原因會震盪或崩塌。改成讀「靠上對齊、沒有指定 Height 的根 Border」的 `ActualHeight`，那才是內容真正需要的高度。
- WPF 的**命中測試座標也對不上**（點第 5 列會觸發第 6 列），所以列的點擊改用實體螢幕座標自己算索引，沒有綁在列元素上。
- 跨 runspace 傳回的陣列會被包成「單一元素、內容是整個陣列」：`.Count` 回 1、`foreach` 只跑一圈，但走管線卻會展開成 N 筆。用 `Expand-Sessions` 攤平。
- `SizeToContent="Height"` 在 `AllowsTransparency` + `NoResize` 下首次排版後就不再跟著內容變高。
- PowerShell 的 WPF 事件處理器會**靜默吞掉例外**，所以處理器內都自己包 try/catch 並寫 log。
- **標題列上的按鈕要綁 `PreviewMouseLeftButtonDown` 而不是 `MouseLeftButtonUp`**：標題列的 Down 會呼叫 `DragMove()`，它的模態移動迴圈會吃掉後續的 MouseUp，綁在 Up 上的處理器永遠不會被呼叫（按下去毫無反應、也沒有例外）。隧道階段攔下來並設 `Handled` 才行。
- `.vbs` 必須是 **ASCII 且無 BOM**（cscript 不吃 UTF-8 BOM）；`.ps1` 反之必須**有 BOM**，否則 PS 5.1 會把中文讀成亂碼。
- **切編輯器分頁走 UI Automation**：Win32 只看得到視窗。VS Code 的分頁是 `TabItem`，名稱等於對話標題，畫面分成多個編輯器群組時會多一段 `, 編輯器群組 N` 後綴。切換用 `SelectionItemPattern.Select()`（`InvokePattern` 不存在）；讀 `IsSelected` 驗證會**慢一拍**拿到上一次的值，別因此以為沒切成功。
- **透明度一律走 `BeginAnimation`**：混用直接指派 `Opacity` 會被動畫的保留值蓋掉，滑鼠移開後就變不回半透明。
- **列每 3 秒整批重建，所以動畫要對齊全域相位**：轉圈圈若都從 0 度開始，每次重建就會跳一下。用負的 `BeginTime`（`-(現在時刻 mod 週期)`）讓時間軸「從過去開始」，角度就只跟絕對時間有關，換掉元件也看不出來。
- **分層視窗的動畫要壓幀率**：每一幀都得把整面重新送進 `UpdateLayeredWindow`，轉圈圈用 `Timeline.SetDesiredFrameRate` 壓到 24fps，省下的 CPU 比看得出來的流暢度多。

## 授權

MIT
