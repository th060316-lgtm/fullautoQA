@echo off
call "%~dp0START_QA.cmd" -Prototype logic %*
exit /b %errorlevel%
