@echo off
rem Double-click to install. Asks for administrator rights.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
