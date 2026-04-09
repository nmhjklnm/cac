@echo off
where bash >nul 2>&1
if %errorlevel%==0 (
    bash "%~dp0cac" %*
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0cac.ps1" %*
)
