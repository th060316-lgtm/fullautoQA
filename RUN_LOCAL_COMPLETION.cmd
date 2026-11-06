@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN_LOCAL_COMPLETION.ps1" -RequireOffline
set "CODE=%ERRORLEVEL%"
echo.
if "%CODE%"=="0" (
  echo LOCAL FINAL COMPLETION FINISHED.
) else (
  echo LOCAL FINAL COMPLETION STOPPED WITH CODE %CODE%.
  echo Preserve the LOCAL_FINAL_ACCEPTANCE_* folder and its logs.
)
pause
exit /b %CODE%
