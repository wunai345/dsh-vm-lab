@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnose.ps1" -Reason "run by hand"
pause
