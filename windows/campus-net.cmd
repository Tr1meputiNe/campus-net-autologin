@echo off
REM ================================================================
REM  campus-net-autologin (Windows) - helper launcher
REM
REM  Same reason as install.cmd: Windows blocks .ps1 by default,
REM  so every entry point goes through -ExecutionPolicy Bypass.
REM  Nothing is changed on your system.
REM
REM  Usage:
REM      campus-net.cmd diagnose   environment diagnosis (run this first)
REM      campus-net.cmd force      send one auth request now
REM      campus-net.cmd rotate     rotate the log now
REM      campus-net.cmd log        show the last 20 log lines
REM      campus-net.cmd config     open config.ps1 in Notepad
REM      campus-net.cmd status     scheduled task status
REM ================================================================

setlocal
set "APPDIR=%LOCALAPPDATA%\campus-net"
set "PS1=%APPDIR%\campus-net-autologin.ps1"
set "LOG=%APPDIR%\logs\monitor.log"
set "CFG=%APPDIR%\config.ps1"

if /i "%~1"=="diagnose" goto diagnose
if /i "%~1"=="force"    goto force
if /i "%~1"=="rotate"   goto rotate
if /i "%~1"=="log"      goto showlog
if /i "%~1"=="config"   goto editconfig
if /i "%~1"=="status"   goto status
goto usage

:diagnose
if not exist "%PS1%" goto notinstalled
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Diagnose
goto end

:force
if not exist "%PS1%" goto notinstalled
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Force
goto end

:rotate
if not exist "%PS1%" goto notinstalled
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Rotate
goto end

:showlog
if not exist "%LOG%" (
    echo [!] No log yet: %LOG%
    goto end
)
powershell.exe -NoProfile -Command "Get-Content -LiteralPath '%LOG%' -Tail 20 -Encoding UTF8"
goto end

:editconfig
if not exist "%CFG%" goto notinstalled
notepad "%CFG%"
goto end

:status
if not exist "%~dp0install.ps1" goto statusappdir
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Status
goto end

:statusappdir
if not exist "%APPDIR%\install.ps1" goto notinstalled
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%APPDIR%\install.ps1" -Status
goto end

:notinstalled
echo [!] Not installed yet: %PS1%
echo     Run install.cmd first.
goto end

:usage
echo campus-net-autologin - helper
echo.
echo   campus-net.cmd diagnose   environment diagnosis (run this first)
echo   campus-net.cmd force      send one auth request now
echo   campus-net.cmd rotate     rotate the log now
echo   campus-net.cmd log        show the last 20 log lines
echo   campus-net.cmd config     open config.ps1 in Notepad
echo   campus-net.cmd status     scheduled task status
echo.
echo   To install:  install.cmd

:end
endlocal
