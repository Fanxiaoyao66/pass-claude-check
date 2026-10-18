@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0fureclaude-host.ps1" %*
exit /b %ERRORLEVEL%
