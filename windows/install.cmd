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

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo [!] install.ps1 exited with code %RC%
    echo.
    pause
)
exit /b %RC%
