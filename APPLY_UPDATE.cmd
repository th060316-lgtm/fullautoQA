@echo off
setlocal
cd /d "%~dp0"
if "%~1"=="" (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0APPLY_UPDATE.ps1"
) else (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0APPLY_UPDATE.ps1" -TargetRoot "%~1"
)
set "CODE=%ERRORLEVEL%"
echo.
if "%CODE%"=="0" (
  echo UPDATE FINISHED.
) else (
  echo UPDATE FAILED WITH CODE %CODE%.
)
pause
exit /b %CODE%
