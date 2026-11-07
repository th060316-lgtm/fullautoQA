@echo off
setlocal
cd /d "%~dp0"
rem A cold-start review file may be supplied as the first argument.  It is
rem ingested by the Sales headquarters; a model proxy is never promoted to a
rem human and a missing file is never read as a pass.
if not "%~1"=="" (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN_LOCAL_COMPLETION.ps1" -RequireOffline -SalesReviewEvidence "%~1"
) else (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN_LOCAL_COMPLETION.ps1" -RequireOffline
)
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
