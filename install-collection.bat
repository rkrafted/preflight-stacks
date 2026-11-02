@echo off
rem Double-click entry point: runs install-collection.ps1 and keeps the window open.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-collection.ps1" %*
echo.
pause
