@echo off
setlocal
cd /d "%~dp0"
rem An optional schema-v1 Final-series Sales review manifest may be supplied
rem as the first argument. Reviews remain target-bound evidence; invalid or
rem missing review input never becomes Human/Sales PASS.
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
