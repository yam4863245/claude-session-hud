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
2. **狀態 hooks**（[hooks/hooks.json](hooks/hooks.json) → [scripts/status-hook.cjs](scripts/status-hook.cjs)）—— 四個全域事件寫 / 刪 `~/.claude/session-status/<sessionId>.json`。
   `UserPromptSubmit`=working、`Notification`=waiting、`Stop`=done、`SessionEnd`=gone。

串起兩邊的 key 是 `claude agents --json` 的 `sessionId`，也就是 hook payload 的 `session_id`。
沒有狀態檔 = `unknown`，不是錯誤。

**`idle` 不是 hook 寫的**（沒有「使用者看了」這種事件）。HUD 每輪比對前景視窗標題，
發現使用者正看著某個 `done` 的 session 就自己把檔案降級成 `idle` —— 這是唯一由 HUD 寫入狀態檔的地方。
判斷依據是 VS Code 標題的格式 `<作用中分頁名> - <資料夾> - <編輯器>`，而分頁名就是對話標題。

## 對話標題是三件事的共用 key

`ai-title` 同時被拿來當：HUD 第一行的顯示文字、**UIA 找編輯器分頁的比對值**、**判斷使用者有沒有在看**的依據。
所以沒有標題的新 session 會同時失去「點擊切分頁」與「已完成自動降級」兩個功能 —— 這是預期行為，不是 bug。

分頁切換用 UI Automation（Win32 看不到分頁）：`TabItem` 的 `Name` 等於對話標題，
但畫面分成多個編輯器群組時會多一段 `, 編輯器群組 N` 後綴，兩種形式都要接。
切換只有 `SelectionItemPattern.Select()` 可用；**讀 `IsSelected` 回來的值慢一拍**，
拿它驗證會誤判成沒切成功。UIA 掃一次樹 ~100ms，只准在點擊時做，不要放進輪詢迴圈。

執行期檔案一律寫 `~/.claude/`（`session-status/`、`session-hud/hud-pos.json`、`session-hud/layout-diag.log`），**不寫回腳本目錄** —— 外掛更新會整個換掉快取目錄。

**hooks 跑的是已安裝的快取副本，不是這個 repo。** 改完 `hooks/` 或 `status-hook.cjs` 要 `claude plugin update session-hud` 才生效；HUD 本體則是你啟動哪個路徑就跑哪個。

## 宿主限制（Windows PowerShell 5.1 + WPF + AllowsTransparency）

這些是實測踩出來的，**改動前先讀 [README.md](README.md) 的「開發筆記」與程式碼裡的長註解**，不要重新推理：

- **DPI 單位錯配**：`Window.Width/Height` 是實體像素，`ExtentHeight`／`ActualWidth` 是 DIP，兩軸都要乘 `scale`。
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

- **一般截圖抓不到 HUD**（`CopyFromScreen` 走 BitBlt，看不到 WPF layered 透明視窗，全螢幕截圖會是空的）。要看畫面用 `PrintWindow(hwnd, hdc, 2)`（`PW_RENDERFULLCONTENT`）。
- **不要用肉眼估版面尺寸**。遇到排版問題先看 `~/.claude/session-hud/layout-diag.log`（每次啟動重建），需要更多數字就先加 `Write-Diag` 再說。
- **session 數量會一直變動**（使用者同時開很多個）。「掃描座標 → 點擊」這種驗證要放在同一次執行裡，否則座標會過期並得到誤導性的失敗。

## 慣例

- 註解、UI 文字、commit message 一律**繁體中文**；註解寫「為什麼」（尤其是宿主怪癖），不寫「做什麼」。
- 不要自動開 feature branch，未明講就在當前分支 commit。
