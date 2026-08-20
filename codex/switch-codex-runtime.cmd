@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.codex\scripts\Switch-CodexRuntime.ps1" %*
exit /b %ERRORLEVEL%
