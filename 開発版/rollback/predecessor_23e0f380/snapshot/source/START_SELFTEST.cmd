@echo off
setlocal
cd /d "%~dp0"
call "%~dp0START_QA.cmd" -SelfTest %*
exit /b %errorlevel%
