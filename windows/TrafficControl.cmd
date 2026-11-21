@echo off
rem Claude Traffic Control. Right-click > Run as administrator for the firewall and Cowork service part.
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TrafficControl\TrafficControl.ps1"
pause
