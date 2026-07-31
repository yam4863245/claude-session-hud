' Launch Claude Session HUD with no console window.
' Double-click to run. Put a shortcut in shell:startup for auto-start on login.
' NOTE: keep this file ASCII and WITHOUT a BOM - cscript rejects a UTF-8 BOM.
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File """ & root & "\session-hud.ps1""", 0, False
