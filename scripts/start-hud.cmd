@echo off
REM Launch Claude Session HUD. Double-click to run.
REM Put a shortcut in shell:startup for auto-start on login.
REM
REM Goes through start-hud.vbs on purpose instead of calling powershell.exe
REM directly: even with -WindowStyle Hidden, powershell allocates a console
REM first and hides it afterwards, so the user sees it flash. wscript.exe is a
REM GUI-subsystem host and never gets a console at all.
REM
REM NOTE: keep this file ASCII and WITHOUT a BOM. cmd reads batch files in the
REM OEM code page (cp950 here), so UTF-8 Chinese bytes get parsed as Big5 and
REM the lead bytes swallow the line ending - REM lines then leak out as bogus
REM commands. A BOM would likewise be echoed as an unknown command.
start "" wscript.exe "%~dp0start-hud.vbs"
