@echo off
title WinDeck Standalone Builder
echo ========================================================
echo   Building WinDeck Standalone Executable
echo ========================================================
echo.

where python >nul 2>nul
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Python not found in PATH!
    pause
    exit /b 1
)

echo Installing PyInstaller and dependencies...
python -m pip install pyinstaller -r requirements.txt --quiet

echo Building standalone single-file WinDeck.exe...
pyinstaller --noconfirm --onedir --windowed ^
    --add-data "ui;ui" ^
    --name "WinDeck" ^
    windeck.py

echo.
if exist "dist\WinDeck\WinDeck.exe" (
    echo [SUCCESS] Standalone build complete!
    echo Executable location: dist\WinDeck\WinDeck.exe
) else (
    echo [ERROR] Build failed. Check pyinstaller output above.
)
pause
