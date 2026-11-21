@echo off
rem ClaudeReset: menu. Right-click > Run as administrator to also stop the Cowork service.
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ClaudeReset.ps1" %*
pause
