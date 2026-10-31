@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Civ6Relay.ps1" -Action Gui
if errorlevel 1 pause
