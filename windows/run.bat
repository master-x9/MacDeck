@echo off
cd /d "%~dp0"
title WinDeck Host Server
echo ========================================================
echo   WinDeck - PC Companion Host for MacDeck Mobile
echo ========================================================
echo.

where python >nul 2>nul
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Python is not installed or not in PATH!
    echo Please install Python 3.11+ from https://www.python.org/
    pause
    exit /b 1
)

echo Checking dependencies...
python -m pip install -r requirements.txt --quiet
if errorlevel 1 exit /b 1

echo Starting WinDeck...
start python windeck.py %*
echo WinDeck started in background. Check your system tray or open http://localhost:62234
