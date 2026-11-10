@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0OPEN_DOWNLOADS.ps1" %*
exit /b %ERRORLEVEL%
