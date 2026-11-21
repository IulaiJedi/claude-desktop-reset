@echo off
rem ClaudeReset: audit only, changes nothing.
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ClaudeReset.ps1" -Mode Audit
pause
