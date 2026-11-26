# WinDeck PowerShell Launcher
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  WinDeck - PC Companion Host for MacDeck Mobile" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] Python 3.11+ was not found in PATH." -ForegroundColor Red
    Write-Host "Please install Python from https://www.python.org/ or the Microsoft Store."
    pause
    exit 1
}

Write-Host "Verifying dependencies..." -ForegroundColor Gray
python -m pip install -r "$PSScriptRoot/requirements.txt" --quiet
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Starting WinDeck..." -ForegroundColor Green
Start-Process python -WorkingDirectory $PSScriptRoot -ArgumentList (@("windeck.py") + $args)
Write-Host "WinDeck is running. Open http://localhost:62234 in your browser or check your system tray." -ForegroundColor Cyan
