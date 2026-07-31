---
name: session-hud
description: 啟動、關閉或重啟 Claude Session HUD —— 那個懸浮在螢幕上、列出所有正在執行的 Claude Code session 的小視窗。使用者說「開啟 HUD」「關掉懸浮視窗」「重啟 session 監看」「session HUD 沒反應」時使用。
---

# Claude Session HUD 控制

HUD 是一個獨立的 Windows 桌面視窗（PowerShell + WPF），跟 Claude Code 的生命週期無關 —— 它自己跑一個行程，靠 `claude agents --json` 每 3 秒輪詢一次。

腳本位置：`${CLAUDE_PLUGIN_ROOT}/scripts/`

## 判斷目前是否在執行

視窗標題固定是 `Claude Session HUD`。用 PowerShell 列出行程：

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*session-hud.ps1*' } |
  Select-Object ProcessId
```

## 啟動

```powershell
Start-Process wscript.exe -ArgumentList '"<PLUGIN_ROOT>\scripts\start-hud.vbs"' -WindowStyle Hidden
```

把 `<PLUGIN_ROOT>` 換成 `${CLAUDE_PLUGIN_ROOT}` 的實際值。用 `start-hud.vbs` 而不是直接跑 `.ps1`，這樣不會閃出主控台視窗。

啟動後等約 5 秒再確認 —— 第一次輪詢 `claude agents --json` 要花 ~600ms，加上 WPF 起始化。

## 關閉

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*session-hud.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

也可以直接點 HUD 右上角的 ✕。

## 重啟

先關再開，中間隔約 0.7 秒讓行程確實結束。改過設定或更新外掛後需要重啟才會生效。

## 疑難排解

- **視窗沒出現**：直接跑 `powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "<PLUGIN_ROOT>\scripts\session-hud.ps1"` 並看 stderr，錯誤訊息會直接印出來。
- **所有 session 都顯示「未知」**：狀態由外掛的 hooks 寫入，只有在該 session **下一次**送出提示或結束回合後才會有值。已經開著的舊 session 要等它動一下。
- **排版異常**：`~/.claude/session-hud/layout-diag.log` 有每次調整視窗尺寸的數字（scale、內容高度、chrome），每次啟動重建。
- **視窗跑到螢幕外**：刪掉 `~/.claude/session-hud/hud-pos.json` 再重啟，會回到右下角預設位置。
