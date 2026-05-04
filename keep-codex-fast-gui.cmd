@echo off
set SCRIPT_DIR=%~dp0
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT_DIR%Keep-CodexFast-GUI.ps1"
