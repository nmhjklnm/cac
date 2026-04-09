@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%.") do set "SCRIPT_DIR=%%~fI"
"%ProgramFiles%\Git\bin\bash.exe" "%SCRIPT_DIR%\cac" %*
if errorlevel 9009 (
  bash "%SCRIPT_DIR%\cac" %*
)
