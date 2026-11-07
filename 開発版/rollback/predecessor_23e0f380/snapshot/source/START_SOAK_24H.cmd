@echo off
call "%~dp0START_QA.cmd" -SoakSeconds 86400 %*
exit /b %errorlevel%
