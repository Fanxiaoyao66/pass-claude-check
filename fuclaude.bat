@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0fuclaude-host.ps1" %*
exit /b %ERRORLEVEL%
