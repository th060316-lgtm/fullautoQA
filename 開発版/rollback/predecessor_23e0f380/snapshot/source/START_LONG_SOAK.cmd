@echo off
call "%~dp0START_QA.cmd" -SoakSeconds 3600 %*
exit /b %errorlevel%
