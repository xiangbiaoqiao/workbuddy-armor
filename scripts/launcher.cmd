@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

rem ---------------------------------------------------------------
rem  WorkBuddy armour launcher
rem  Closes the app, applies both patch layers, relaunches.
rem  About 2 seconds once the stat cache exists.
rem
rem  Nothing here needs editing: the install path comes from
rem  armor-apply.py --print-exe (registry + common locations).
rem  Override by hand only if detection fails:
rem      set WB_EXE=D:\SomePath\WorkBuddy.exe
rem ---------------------------------------------------------------

if "%ARMOR_SCRIPTS%"=="" set "ARMOR_SCRIPTS=%~dp0"
set "SCRIPT=%ARMOR_SCRIPTS%armor-apply.py"

rem ---- 0. python must exist, otherwise the patch step is a silent no-op ----
where python >nul 2>&1
if errorlevel 1 (
    echo [!] python not found on PATH. Install Python 3.8+, then rerun.
    if "%WB_EXE%"=="" goto nolaunch
)

rem ---- 1. resolve the exe: env override, then auto-detect ----
if not "%WB_EXE%"=="" set "PROC=WorkBuddy.exe"
if "%WB_EXE%"=="" for /f "usebackq delims=" %%i in (`python "%SCRIPT%" --print-exe 2^>nul`) do (
    set "WB_EXE=%%i"
)
if "%WB_EXE%"=="" (
    echo [!] could not locate WorkBuddy.exe.
    echo     Set WB_EXE to its full path, or pass it before launching:
    echo         set WB_EXE=D:\WorkBuddy\WorkBuddy.exe
    echo     The patch was still applied if python ran ok.
    goto nolaunch
)
for %%f in ("!WB_EXE!") do set "PROC=%%~nxf"

echo [i] exe: !WB_EXE!

rem ---- 2. close if running: poll, no fixed sleep ----
tasklist /FI "IMAGENAME eq !PROC!" 2>nul | find /I "!PROC!" >nul
if errorlevel 1 goto patch

taskkill /F /T /IM "!PROC!" >nul 2>&1
set /a tries=0
:waitloop
tasklist /FI "IMAGENAME eq !PROC!" 2>nul | find /I "!PROC!" >nul
if errorlevel 1 goto patch
set /a tries+=1
if !tries! geq 20 goto patch
ping -n 2 127.0.0.1 >nul
goto waitloop

rem ---- 3. patch (idempotent; skips files whose size/mtime are unchanged) ----
:patch
python "%SCRIPT%" --quiet
if errorlevel 1 echo [!] patch step reported a problem, see above.

rem ---- 4. launch and exit ----
start "" "!WB_EXE!"
exit

:nolaunch
echo [i] opening WorkBuddy was skipped.
pause
exit
