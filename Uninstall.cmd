@echo off
rem Double-click to remove everything Install.cmd added. Asks for administrator rights.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall.ps1" %*
