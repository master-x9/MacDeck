param([Parameter(Mandatory)][version]$Version, [Parameter(Mandatory)][string]$Notes)
$ErrorActionPreference = 'Stop'
$notesPath = (Resolve-Path $Notes).Path
Push-Location "$PSScriptRoot/../windows"
try {
    python -m pip install -r requirements.txt pyinstaller
    if ($LASTEXITCODE) { throw 'Dependency installation failed' }
    python -m PyInstaller --noconfirm --onedir --windowed --collect-all pywinauto --collect-all velopack --hidden-import websockets.asyncio.server --icon windeck.ico --add-data 'ui;ui' --name WinDeck windeck.py
    if ($LASTEXITCODE) { throw 'WinDeck build failed' }
    vpk pack --packId WinDeck --packVersion $Version --packDir dist/WinDeck --mainExe WinDeck.exe --releaseNotes $notesPath --outputDir ../release/out/windows
    if ($LASTEXITCODE) { throw 'Velopack packaging failed' }
} finally { Pop-Location }
