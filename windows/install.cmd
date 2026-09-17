@echo off
REM ================================================================
REM  campus-net-autologin (Windows) - installer launcher
REM
REM  Why this file exists:
REM    Windows blocks .ps1 scripts by default:
REM      "cannot be loaded because running scripts is disabled"
REM    This launcher runs install.ps1 with -ExecutionPolicy Bypass,
REM    which applies to this one process only and does NOT change
REM    any system setting.
REM
REM  Usage:
REM      install.cmd                install
REM      install.cmd -Status        show task status + recent log
REM      install.cmd -Uninstall     uninstall
REM      install.cmd -IntervalSeconds 60
REM ================================================================

REM Double-clicked? Then keep the window open at the end.
set "PAUSE_AT_END="
echo %cmdcmdline% | find /i "%~nx0" >nul 2>&1
if not errorlevel 1 set "PAUSE_AT_END=1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo [OK] install.ps1 finished.
) else (
    echo [!] install.ps1 exited with code %RC%
    set "PAUSE_AT_END=1"
)

if defined PAUSE_AT_END (
    echo.
    echo Press any key to close this window . . .
    pause >nul
)
exit /b %RC%
