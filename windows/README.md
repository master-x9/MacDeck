# WinDeck for Windows

WinDeck pairs with the MacDeck Android app over Wi-Fi. The desktop editor has a page sidebar, a phone preview, and a bottom tile library. The preview follows the two-, three-, or four-row layout chosen on the phone. Lock, unlock and the locked-screen layout are exclusive to macOS.

## Run and pair

1. Run **WinDeck-Setup.exe** once. If you used the old portable ZIP, quit that copy before starting the installed app. WinDeck checks for updates on launch and every four hours. Choose **Yes** in the version-and-release-notes prompt to download, install and restart. The desktop window uses Edge WebView2. If it is unavailable, WinDeck opens the dashboard in the default browser.
2. Connect the phone and PC to the same local network. If Windows Firewall asks, allow WinDeck on the private network.
3. Open MacDeck on Android, choose the PC in the discovery list, and click **Approve** on the desktop. WinDeck remembers the phone. Click **Disconnect** on its connection card to end the session. Approve the next connection when you want to resume. **Host settings → Trusted phones** lets you forget it.

The phone uses Bonjour/mDNS service `_macdeck._tcp` and WebSocket port 62233. The desktop dashboard listens on loopback port 62234. Pages and trusted devices are stored in the current Windows user's AppData/Roaming/WinDeck directory.

## Discord calls

Enable **Discord Calls** and keep the Discord desktop window open. WinDeck reads the English accessibility labels on Discord's own buttons. The top row shows microphone, deafen, call, camera and screen sharing in fixed positions. The call tile opens Discord, answers an incoming call, or disconnects. The second row shows up to five unread DMs and server mentions, falling back to visible joined servers in sidebar order. Counts and caller artwork depend on what Discord exposes. Choose the screen or window to share in Discord. Discord's tray-only mode, language, and which call controls are visible can affect availability.

## OBS Studio

In OBS 28 or later, enable **Tools → WebSocket Server Settings → Enable WebSocket server**. In WinDeck, enable **OBS Studio**, then enter the same local port and password under **Host settings**. WinDeck saves the password in Windows Credential Manager.

Open the live OBS page to start or stop recording and streaming, switch scenes, toggle the replay buffer, or mute the configured primary microphone. In a large scene collection, **Previous Scene** and **Next Scene** reach scenes beyond the visible grid. Selecting a live control in the desktop preview also runs it.

## Build from source on Windows

With Python 3.11 or later installed, double-click **run.bat** to install the dependencies and run the desktop host. **build_exe.bat** builds a standalone executable with PyInstaller. Select a single file or a folder bundle when prompted. Run the tests with `python -m unittest discover -s tests` after installing requirements.txt.
