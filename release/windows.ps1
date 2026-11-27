param([Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$')][string]$Version, [Parameter(Mandatory)][string]$Notes)
$ErrorActionPreference = 'Stop'
$notesPath = (Resolve-Path $Notes).Path
Push-Location "$PSScriptRoot/../windows"
try {
    python -m pip install -r requirements.txt pyinstaller
    if ($LASTEXITCODE) { throw 'Dependency installation failed' }
    python -B -m unittest discover -s tests -v
    if ($LASTEXITCODE) { throw 'WinDeck tests failed' }
    python -c "from winrt.windows.devices.lights import LampArray; from winrt.windows.devices.enumeration import DeviceInformation; from winrt.windows.ui import Color; print('Windows lighting API available')"
    if ($LASTEXITCODE) { throw 'Windows lighting dependencies missing' }
    python -m PyInstaller --noconfirm --onedir --windowed --collect-submodules winrt --collect-all pywinauto --collect-all velopack --hidden-import websockets.asyncio.server --icon windeck.ico --add-data 'ui;ui' --name WinDeck windeck.py
    if ($LASTEXITCODE) { throw 'WinDeck build failed' }
    vpk pack --packId WinDeck --packVersion $Version --packDir dist/WinDeck --mainExe WinDeck.exe --releaseNotes $notesPath --outputDir ../release/out/windows
    if ($LASTEXITCODE) { throw 'Velopack packaging failed' }
} finally { Pop-Location }
