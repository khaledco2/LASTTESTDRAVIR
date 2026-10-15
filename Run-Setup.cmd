@echo off
setlocal EnableExtensions
cd /d "%~dp0"

echo ==========================================
echo   recoil-killer setup launcher
echo ==========================================
echo.

set "PS1=%~dp0Install-Toolkit.ps1"
if not exist "%PS1%" (
    echo ERROR: Install-Toolkit.ps1 was not found next to this launcher.
    echo Keep both files in the same folder and try again.
    echo.
    pause
    exit /b 1
)

rem --- Administrator check -------------------------------------------------
net session >nul 2>&1
if errorlevel 1 (
    echo Administrator rights are required. A UAC prompt will appear now.
    echo.
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    exit /b
)

echo Running the setup (source folder: %~dp0) ...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Source "%~dp0." %*

echo.
echo ------------------------------------------
echo Done. Press any key to close this window.
pause >nul
endlocal
