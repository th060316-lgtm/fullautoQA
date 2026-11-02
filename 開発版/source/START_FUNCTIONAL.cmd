@echo off
call "%~dp0START_QA.cmd" -Backend rfb %*
exit /b %errorlevel%
