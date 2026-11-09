@echo off
cd /d "%~dp0"
echo Starting Vivaldi Tabs Agent...
echo Close this window to stop the agent.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0agent.ps1"
pause
