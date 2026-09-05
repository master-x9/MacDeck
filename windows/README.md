# WinDeck — Windows Host for MacDeck

**WinDeck** is the Windows companion host for the **MacDeck** mobile app (Android / iOS). It enables you to use your phone or tablet as a high-speed, tactile wireless stream deck and macro controller for your Windows PC.

---

## Features

- **Seamless Discovery**: Automatically advertises `_macdeck._tcp` via mDNS/Bonjour on local port `62233`. Your phone auto-discovers your Windows PC just like a Mac.
- **Zero-Latency Win32 Controls**:
  - **Media Keys**: Play/Pause, Next Track, Previous Track, Mute, Volume Up/Down.
  - **System Controls**: Lock Workstation (`Win+L`), Sleep PC, Keep Awake / Anti-Sleep caffeine mode, Show Desktop (`Win+D`), Task View (`Win+Tab`), Quit App (`Alt+F4`), Screenshot Snipping (`Win+Shift+S`), Screen Record, Empty Recycle Bin.
  - **Browser Controls**: Tab 1–5, Back, Forward, Refresh, New Tab, Close Tab.
  - **App Launcher**: Instant launch of any installed Windows application or shortcut.
  - **Custom Hotkey Macros**: Supports key combinations like `CTRL+SHIFT+ESC`, `ALT+TAB`, and custom chords.
  - **Websites**: Opens any URL with automatic high-resolution Google favicon extraction.
  - **Locked Screen Layout**: Automatically switches the phone to a dedicated locked screen controller layout when your PC locks (`00000000-0000-0000-0000-000000000002`).
  - **Running Apps Page**: Live monitor of top visible Windows applications with one-tap window focus.
- **Desktop UI**:
  - Dark mode liquid-glass dashboard matching the MacDeck aesthetic.
  - Interactive 2x5 phone screen preview with tactile keycaps, drag-and-drop, and slot inspector.
  - System tray icon with background minimize and auto-run support.

---

## Quick Start (Running on Windows)

### Option 1: One-Click Run (Recommended)
1. Ensure [Python 3.9+](https://www.python.org/downloads/) is installed and added to your system `PATH`.
2. Double-click `run.bat` (or right-click `run.ps1` and choose "Run with PowerShell").
3. WinDeck will automatically install any missing dependencies and start the desktop dashboard and network server.

### Option 2: Command Line
```cmd
cd windows
pip install -r requirements.txt
python windeck.py
```

### Option 3: Build Standalone `.exe`
Double-click `build_exe.bat`. It will create a portable, standalone `WinDeck.exe` inside `dist/WinDeck/` that requires no Python installation to run!

---

## Pairing Your Phone

1. Ensure your phone and PC are connected to the **same Wi-Fi network**.
2. Open the **MacDeck** mobile app on your phone.
3. Your PC will appear automatically in the discovery list (e.g. `DESKTOP-XYZ`).
4. Tap your PC to connect. A pairing prompt will appear on your Windows desktop.
5. Click **Approve**. Your pages and icons will instantly sync to your phone!

---

## Architecture & Ports

- **Port 62233 (TCP)**: WebSocket wire protocol & mDNS Bonjour endpoint (`_macdeck._tcp`).
- **Port 62234 (HTTP)**: Local desktop dashboard API (`http://localhost:62234`).
- **Data Location**: `%APPDATA%\WinDeck\pages.json` and `%APPDATA%\WinDeck\TrustedDevices.json`.
