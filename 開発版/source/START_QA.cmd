@echo off
setlocal
set "FULLAUTOQA_START_QA=1"
set "FULLAUTOQA_FRESH_EXTRACTION="
set "FULLAUTOQA_FRESH_EXTRACTION_ID="
if not exist "%~dp0PHASE3_FRESH_EXTRACTION.marker" goto run_qa
set /p FULLAUTOQA_FRESH_EXTRACTION_ID=<"%~dp0PHASE3_FRESH_EXTRACTION.marker"
del /f /q "%~dp0PHASE3_FRESH_EXTRACTION.marker" >nul 2>&1
if not "%FULLAUTOQA_FRESH_EXTRACTION_ID%"=="" if not exist "%~dp0PHASE3_FRESH_EXTRACTION.marker" set "FULLAUTOQA_FRESH_EXTRACTION=1"
:run_qa
cd /d "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0BOOTSTRAP.ps1" %*
exit /b %errorlevel%

