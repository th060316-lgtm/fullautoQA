@echo off
call "%~dp0START_QA.cmd" -Prototype playable %*
exit /b %errorlevel%
