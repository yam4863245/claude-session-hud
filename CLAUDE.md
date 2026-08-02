# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 這是什麼

Claude Code 外掛：一個 Windows 懸浮視窗，列出**所有專案**正在跑的 Claude Code session。
沒有 build、沒有測試框架、沒有 `package.json` —— 只有三個直接執行的腳本（PowerShell 5.1 / VBScript / Node CJS）＋ 外掛 metadata。
「改完就能跑」，但也因此**沒有任何編譯期或測試期的防護網**，下面的宿主限制全都是執行期才會爆（而且常常是靜默的）。

## 常用指令

```powershell
# 直接跑（會顯示 stderr，除錯用這個）
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\scripts\session-hud.ps1

# 正常啟動（無主控台視窗）
Start-Process wscript.exe -ArgumentList '"<repo>\scripts\start-hud.vbs"' -WindowStyle Hidden

# 語法檢查（改完 .ps1 必跑，特別是確認 BOM 沒被 Edit 工具吃掉）
$errs = $null
[System.Management.Automation.Language.Parser]::ParseFile("$PWD\scripts\session-hud.ps1", [ref]$null, [ref]$errs); $errs

# 手動觸發狀態寫入（驗證 hook 腳本本身）
'{"session_id":"test-1234","cwd":"C:\\tmp"}' | node .\scripts\status-hook.cjs working
# 檢查 ~/.claude/session-status/test-1234.json

# 外掛安裝／更新
claude plugin install session-hud
claude plugin update session-hud
```

**關 HUD 不要用 `Where-Object { $_.CommandLine -like '*session-hud.ps1*' }` 搭 `Stop-Process`** —— 某些專案的 hook 會把 `$_.CommandLine` 誤判成寫入目標而擋下整個指令。改用「找視窗標題 `Claude Session HUD` → `GetWindowThreadProcessId` → `Stop-Process`」。
啟動／關閉／重啟／疑難排解的完整步驟見 [skills/session-hud/SKILL.md](skills/session-hud/SKILL.md)（或 `/session-hud`）。

## 架構

兩個彼此不知道對方存在的東西，靠檔案系統對接：

1. **HUD 行程**（[scripts/session-hud.ps1](scripts/session-hud.ps1)）—— 獨立桌面行程，與任何 Claude Code session 的生命週期無關。
   - 背景 runspace（MTA）每 3 秒跑 `claude agents --json`，並讀轉錄檔取對話標題；**所有磁碟 I/O 都在這裡**。
   - UI 執行緒的 `DispatcherTimer`（700ms）只讀共享的 synchronized hashtable `$Sync` 並重畫。
   - 「一輪加列、下一輪才依量到的高度調視窗」是刻意的兩段式，見 `Apply-PendingResize` 的註解。
2. **狀態 hooks**（[hooks/hooks.json](hooks/hooks.json) → [scripts/status-hook.cjs](scripts/status-hook.cjs)）—— 全域事件寫 / 刪 `~/.claude/session-status/<sessionId>.json`。
   `UserPromptSubmit`=working、`PreToolUse[AskUserQuestion]`=asking、`PostToolUse[AskUserQuestion]`=working、
   `Notification`=waiting、`Stop`=done、`SessionEnd`=gone。
   `asking`（需要我做決定）跟 `waiting`（等你）分開是刻意的：waiting 多半按個同意就過了，
   asking 是真的要你判斷，所以顏色不同、而且會出聲。用 `PreToolUse` 配 tool 名而不是解析
   `Notification` 的 message 字串——後者是給人看的文案，隨時會改。

串起兩邊的 key 是 `claude agents --json` 的 `sessionId`，也就是 hook payload 的 `session_id`。
沒有狀態檔 = `unknown`，不是錯誤。

**`claude agents --json` 不等於「使用者看得到的 session」。** VS Code 外掛會預先開好不帶
`--resume` 的 `claude` 行程等著用，它們有 `sessionId`、會被列出來，但沒有任何對話 ——
沒有轉錄檔、也不會觸發任何 hook，畫出來就是一列看不懂的代號。poller 用
「沒有轉錄檔 **且** 沒有狀態檔」把它們濾掉。兩個條件都要，不能只看轉錄檔：
轉錄檔路徑是從 cwd 推導的，推導失敗時真的 session 也會找不到檔案。
這個過濾是自我修正的 —— 使用者一在那個分頁開始對話，它就會自己冒出來。

**音效也在 HUD 這邊**（`Invoke-StatusSound`），不在 hook 裡 —— HUD 本來就有狀態機，
抓得到「上一輪不是 X、這一輪是 X」那一刻。兩個必要條件：**第一輪只記錄不發聲**
（否則 HUD 一開就把既有的 done 全部叫一遍），以及**比對的是降級前的原始狀態**
（回合跑完就是跑完，不該因為使用者剛好正看著就變成沒完成）。
done 用 Asterisk、asking 用 Exclamation，同一輪兩者都發生時只響 asking（它會卡住不動，比較急）。

驗證 hook 有沒有真的被觸發，用 `claude -p --plugin-dir <臨時副本>` 跑一個 headless session，
**不要**讓臨時 hook 也寫狀態檔 —— 已安裝的外掛還是全域生效，它的 `Stop` 會在最後蓋掉你剛寫的值，
看起來就像沒觸發。讓臨時 hook 寫獨立的標記檔才分得出來。
另外 `--allowedTools` 是可變長度參數，會把後面的 prompt 一起吃掉，prompt 要走 stdin。

**`idle` 不是 hook 寫的**（沒有「使用者看了」這種事件）。HUD 每輪比對前景視窗標題，
發現使用者正看著某個 `done` 的 session 就自己把檔案降級成 `idle` —— 這是唯一由 HUD 寫入狀態檔的地方。
判斷依據是 VS Code 標題的格式 `<作用中分頁名> - <資料夾> - <編輯器>`，而分頁名就是對話標題。

## 對話標題是三件事的共用 key

`ai-title` 同時被拿來當：HUD 第一行的顯示文字、**UIA 找編輯器分頁的比對值**、**判斷使用者有沒有在看**的依據。
所以沒有標題的新 session 會同時失去「點擊切分頁」與「已完成自動降級」兩個功能 —— 這是預期行為，不是 bug。

**分頁名不等於對話標題：超過約 24 個字會被截成「前綴 + `…`」（U+2026），視窗標題用的也是
截斷後那個字串。** 所以任何比對都得走 `Test-TabLabelMatch`（相等 or `…` 前綴），直接 `-eq`
會讓長標題的 session 永遠比不中 —— 症狀是那幾列點了不切分頁、而且「已完成」卡著降不了級，
但短標題的 session 一切正常，很容易誤以為功能是好的。

分頁切換用 UI Automation（Win32 看不到分頁）：`TabItem` 的 `Name` 等於（截斷後的）對話標題，
但畫面分成多個編輯器群組時會多一段 `, 編輯器群組 N` 後綴，兩種形式都要接 ——
後綴要**先切掉再判斷有沒有被截斷**，否則 `…, 編輯器群組 2` 看起來就不是以 `…` 結尾。
切換只有 `SelectionItemPattern.Select()` 可用；**讀 `IsSelected` 回來的值慢一拍**，
拿它驗證會誤判成沒切成功。UIA 掃一次樹 ~100ms，只准在點擊時做，不要放進輪詢迴圈。

底部的 5 小時用量讀 `~/.claude.json` 的 `cachedUsageUtilization.utilization.five_hour`，
那是唯一拿得到這個數字的地方（CLI 沒有 usage 指令，轉錄檔只有 per-message 的 token 數，換算不出百分比）。
**只能用 regex 挑出 `"five_hour":{...}` 那一段來解析，整份 `ConvertFrom-Json` 在 PS 5.1 會直接拋例外** ——
那個檔的 `projects` 底下會同時存在只差大小寫的重複鍵（`c:/...` 與 `C:/...`）。
它是 Claude Code 自己的快取，我們叫不動它更新（實測可落後兩小時以上），所以超過 15 分鐘要在畫面上標示「幾分鐘前」。

執行期檔案一律寫 `~/.claude/`（`session-status/`、`session-hud/hud-pos.json`、`session-hud/layout-diag.log`），**不寫回腳本目錄** —— 外掛更新會整個換掉快取目錄。

**hooks 跑的是已安裝的快取副本，不是這個 repo。** 改完 `hooks/` 或 `status-hook.cjs` 要 `claude plugin update session-hud` 才生效；HUD 本體則是你啟動哪個路徑就跑哪個。

## 宿主限制（Windows PowerShell 5.1 + WPF + AllowsTransparency）

這些是實測踩出來的，**改動前先讀 [README.md](README.md) 的「開發筆記」與程式碼裡的長註解**，不要重新推理：

- **DPI 單位錯配**：`Window.Width/Height` 是實體像素，`ExtentHeight`／`ActualWidth` 是 DIP，兩軸都要乘 `scale`。
- **版面裡不能有「填滿剩餘空間」的元素**（`Height="*"`、`VerticalAlignment="Stretch"`）。
  WPF 把 325（實體像素）當成 325 DIP 排版，但看得到的只有 260 DIP，多出來的 65 DIP
  會被那個元素吃掉，排在它下面的東西**整條被推到視窗外**——不是裁一半，是完全消失，
  而且 `IsVisible` 還是 `True`、`ActualHeight` 也正常，只有量 `TranslatePoint` 到視窗的 Y 才看得出來。
  全部改成 `Auto` + `MaxHeight`、根 Border 加 `VerticalAlignment="Top"`。
- **視窗高度不要用「剩餘空間」反推**（`win.ActualHeight - viewport`）：viewport 是 `win.Height` 決定的，
  拿結果推原因會震盪（實測 250↔400 來回）或崩塌（37.8 → 3.2 → 12.0 → 9.8）。
  改讀「靠上對齊、沒指定 Height 的根 Border」的 `ActualHeight`，那才是內容真正需要的高度。
- **命中測試偏移**：列的點擊不綁在列元素上，改由視窗層用實體螢幕座標算索引（`$RowsTopPx` / `$RowPitchPx`）。
- **WPF 事件處理器會靜默吞例外**：handler 內一律自己 try/catch 並 `Write-Diag`。
- **跨 runspace 陣列會被包成單一元素**：`.Count` 回 1、`foreach` 只跑一圈 —— 一律先過 `Expand-Sessions`。
- **編碼**：`.ps1` 必須有 UTF-8 BOM（否則 PS 5.1 讀中文成亂碼），`.vbs` 必須 ASCII 且**無** BOM（cscript 不吃）。Edit 工具可能移除 BOM，改完務必確認。
- **字型**：任何顯示中文的 `TextBlock` 都要指定 `$UI_FONT`；用 Segoe UI 的話中文是**整片空白**，不是豆腐字。
- **透明度只走 `BeginAnimation`**：`Window.Opacity` 一旦被動畫設過，之後直接指派就無效（動畫值優先），
  混用會讓滑鼠移開後變不回半透明。hover 用的 `MouseEnter/MouseLeave` 綁在 `RootBorder` 上，
  不要綁 `$win` —— 視窗背景是 `Transparent`，命中測試不一定吃得到。
- **列每 3 秒整批重建，動畫必須對齊全域相位**：新元件的動畫如果從 0 開始，使用者會看到週期性的跳動。
  用負的 `BeginTime`（`-(現在時刻 mod 週期)`）讓角度只跟絕對時間有關，重建就看不出來。
  分層視窗每幀都要整面重送，動畫記得用 `Timeline.SetDesiredFrameRate` 壓幀率。
- **驗證小圖示的動畫不要用肉眼或整窗像素差**：`PrintWindow` 拍得到 `RenderTransform`（拍不到 `Window.Opacity`，
  那個在合成層）。量旋轉相位要**只框圖示本身** —— 綠色的「執行中」文字就在圈圈左邊，
  多框幾欄進來就會把推算出的圓心整個推歪，量到的角度會被釘死不動，看起來像沒在轉。

## 驗證 HUD 的方式

- **一般截圖抓不到 HUD**（`CopyFromScreen` 走 BitBlt，連 `CAPTUREBLT` 也一樣，看不到 WPF layered 透明視窗，全螢幕截圖會是空的）。要看畫面用 `PrintWindow(hwnd, hdc, 2)`（`PW_RENDERFULLCONTENT`）。
- **但 PrintWindow 的像素「座標」不能拿來推點擊位置**。它是照 `TransformToDevice` 的 scale 重新渲染（125% 下 430px 寬、元素在 DIP×1.25 處）；實際的分層表面卻是 1:1 DIP 渲染 —— 用 `WindowFromPoint` 掃邊界實測，可命中區恰好是 `Width/scale × 內容DIP高`（430×471 的視窗矩形只有左上 344×338 可點）。憑 PrintWindow 截圖算出的「可見位置」去合成點擊，會點進矩形右側/下緣的穿透區、直接打到底下別的應用程式。要推元素的實際位置：拿 `TranslatePoint` 的 DIP 值「不乘 scale」，或用 `WindowFromPoint` 掃描驗證。
- **不要用肉眼估版面尺寸**。遇到排版問題先看 `~/.claude/session-hud/layout-diag.log`（每次啟動重建），需要更多數字就先加 `Write-Diag` 再說。
- **session 數量會一直變動**（使用者同時開很多個）。「掃描座標 → 點擊」這種驗證要放在同一次執行裡，否則座標會過期並得到誤導性的失敗。

## 慣例

- 註解、UI 文字、commit message 一律**繁體中文**；註解寫「為什麼」（尤其是宿主怪癖），不寫「做什麼」。
- 不要自動開 feature branch，未明講就在當前分支 commit。
