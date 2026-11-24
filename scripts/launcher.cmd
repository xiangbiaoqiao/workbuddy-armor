@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

rem ---------------------------------------------------------------
rem  WorkBuddy armour launcher
rem  Closes the app, applies both patch layers, relaunches.
rem  Normally finishes in about 2 seconds (stat cache).
rem
rem  Edit these two lines once for your machine, or set the same
rem  names as environment variables before calling.
rem ---------------------------------------------------------------
if "%ARMOR_SCRIPTS%"=="" set "ARMOR_SCRIPTS=%~dp0"
if "%WB_EXE%"=="" set "WB_EXE=D:\WorkBuddy\WorkBuddy.exe"

rem ---- 1. close if running: poll, no fixed sleep ----
tasklist /FI "IMAGENAME eq WorkBuddy.exe" 2>nul | find /I "WorkBuddy.exe" >nul
if errorlevel 1 goto patch

taskkill /F /T /IM WorkBuddy.exe >nul 2>&1
set /a tries=0
:waitloop
tasklist /FI "IMAGENAME eq WorkBuddy.exe" 2>nul | find /I "WorkBuddy.exe" >nul
if errorlevel 1 goto patch
set /a tries+=1
if !tries! geq 20 goto patch
ping -n 2 127.0.0.1 >nul
goto waitloop

rem ---- 2. patch (idempotent; skips files whose size/mtime are unchanged) ----
:patch
python "%ARMOR_SCRIPTS%armor-apply.py" --quiet >nul 2>&1

rem ---- 3. launch and exit ----
start "" "%WB_EXE%"
exit
