@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch_final_series.ps1"
if errorlevel 1 (
  echo Acceptance stopped. Preserve the logs and result files.
  pause
  exit /b 1
)
pause
