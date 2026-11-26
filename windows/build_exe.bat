@echo off
title WinDeck Standalone Builder
echo ========================================================
echo   Building WinDeck Standalone Windows Executable (.exe)
echo ========================================================
echo.

where python >nul 2>nul
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Python not found in PATH!
    echo Please install Python 3.9+ from https://www.python.org/
    pause
    exit /b 1
)

echo [1/3] Installing PyInstaller and dependencies...
python -m pip install pyinstaller -r requirements.txt --quiet

echo.
echo [2/3] Choose build type:
echo   [1] Single-File Portable Executable (dist\WinDeck.exe) [Recommended]
echo   [2] Folder Bundle (dist\WinDeck\WinDeck.exe)
echo.
set /p BUILD_CHOICE="Select (1 or 2, default 1): "
if "%BUILD_CHOICE%"=="" set BUILD_CHOICE=1

if "%BUILD_CHOICE%"=="2" (
    echo [3/3] Building folder bundle...
    pyinstaller --noconfirm --onedir --windowed ^
        --icon "windeck.ico" ^
        --add-data "ui;ui" ^
        --name "WinDeck" ^
        windeck.py
    set OUTPUT_PATH=dist\WinDeck\WinDeck.exe
) else (
    echo [3/3] Building single-file portable WinDeck.exe...
    pyinstaller --noconfirm --onefile --windowed ^
        --icon "windeck.ico" ^
        --add-data "ui;ui" ^
        --name "WinDeck" ^
        windeck.py
    set OUTPUT_PATH=dist\WinDeck.exe
)

echo.
if exist "%OUTPUT_PATH%" (
    echo ========================================================
    echo   [SUCCESS] Build complete!
    echo   Executable: %OUTPUT_PATH%
    echo ========================================================
) else (
    echo [ERROR] Build failed. Review PyInstaller logs above.
)
pause
