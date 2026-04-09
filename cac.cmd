@echo off
setlocal enabledelayedexpansion
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%.") do set "SCRIPT_DIR=%%~fI"

set "BASH_EXE="
for %%P in (
  "%ProgramFiles%\Git\bin\bash.exe"
  "%ProgramW6432%\Git\bin\bash.exe"
  "%LocalAppData%\Programs\Git\bin\bash.exe"
  "%LocalAppData%\Git\bin\bash.exe"
) do (
  if not defined BASH_EXE if exist %%~fP set "BASH_EXE=%%~fP"
)

if not defined BASH_EXE (
  for /f "delims=" %%I in ('where.exe git.exe 2^>nul') do (
    if not defined BASH_EXE (
      set "CANDIDATE=%%~dpI..\bin\bash.exe"
      if exist "!CANDIDATE!" for %%B in ("!CANDIDATE!") do set "BASH_EXE=%%~fB"
    )
  )
)

if not defined BASH_EXE (
  for /f "delims=" %%I in ('where.exe bash.exe 2^>nul') do (
    if not defined BASH_EXE (
      echo %%~fI | findstr /I /C:"\WindowsApps\" >nul || set "BASH_EXE=%%~fI"
    )
  )
)

if not defined BASH_EXE (
  >&2 echo [cac] Error: Git Bash not found. Install Git for Windows or add bash.exe to PATH.
  exit /b 9009
)

"%BASH_EXE%" "%SCRIPT_DIR%\cac" %*
exit /b %ERRORLEVEL%
