@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0JOIN_COMPLETE.ps1"
set "join_result=%ERRORLEVEL%"
if not "%join_result%"=="0" pause
exit /b %join_result%
