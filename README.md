# MacDeck

MacDeck turns your phone into a control deck for your Mac or Windows PC. Build a page on your computer, lay your phone beside your keyboard, and tap a tile to do something on the desktop. A writing deck might hold your notes app, a reference site, and a music control. A recording deck on the Mac can put your OBS scenes and microphone under your fingertips.

MacDeck is my favorite project I’ve built. If you’re trying it for the first time, start with one button for something you do every day. That’s enough to make the deck feel like yours. — Jatin

![MacDeck desktop dashboard with the deck editor and tile library](public/macdeck_app_dashboard.png)

## What can go on a deck?

| On your phone | On your computer |
| --- | --- |
| An app or website tile | Open an application or jump straight to a saved URL. Put the tools for one task together on a named page. |
| Media and system controls | Pause music, skip a track, change volume, take a screenshot, or keep the computer awake. |
| Browser controls | Move between tabs, go back or forward, refresh, or open a new tab while the browser is active. |
| A running-apps page | See which apps are open and tap one to bring it forward. The page updates as the set of running apps changes. |

The **macOS host** also supports app-triggered pages. For example, you can have your recording deck appear when OBS comes to the foreground. Its OBS integration builds tiles from your scene list and adds recording, streaming, replay buffer, and microphone controls. The Discord integration lets you pin channels your configured bot can access.

The **Windows host**, WinDeck, adds custom hotkey tiles and Windows actions such as Task View, Show Desktop, and screenshot snipping. You can keep it running in the system tray while you use the phone.

## Set up the desktop host

This repository includes the macOS host, the [WinDeck host](windows/), and the [Android companion](android/). First run the host for the computer you want to control, then install the companion on your phone.

### macOS

1. Use a Mac running macOS 26.5 or later and an Xcode installation that supports the project’s deployment target.
2. Clone and open the project from Terminal.

   ```sh
   git clone https://github.com/master-x9/macDeckk.git
   cd macDeckk
   open macDeckk.xcodeproj
   ```

3. In Xcode, choose the **MacDeck** scheme and **My Mac** as the destination. Press **⌘R** to build and launch the desktop editor.
4. Allow local network access if macOS asks. For media keys and simulated keyboard actions, use the editor’s **Open System Settings** button and enable MacDeck under **Privacy & Security → Accessibility**.

### Windows

1. Install Python with **Add python.exe to PATH** enabled. Download and extract the repository using GitHub’s **Code → Download ZIP**, or clone it with Git.
2. Open the extracted project’s `windows` folder. In that folder, open Command Prompt and run the following commands. Keeping the terminal open lets you see any startup errors.

   ```bat
   python -m pip install -r requirements.txt
   python windeck.py
   ```

3. The WinDeck dashboard opens on your PC. For subsequent launches, you can use `run.bat` from the same folder.

For a standalone executable, run `build_exe.bat` from the `windows` folder. Choose **1** for `dist\WinDeck.exe` or **2** for the folder bundle in `dist\WinDeck\`. [WinDeck guide](windows/README.md)

## Install the Android companion

1. Open the [android](android/) folder in Android Studio as its own project. Let Gradle sync and install Android SDK Platform 35 if prompted.
2. On a phone running Android 7.0 or later, enable developer options and USB debugging. Connect it to the computer by USB and approve the debugging prompt on the phone.
3. In Android Studio, select the **app** run configuration and your phone, then click **Run**. Once the app launches, you can disconnect USB. The deck communicates with the desktop over your local network.

## Pair your phone and try a tile

1. Connect the phone and computer to the same local network. Leave MacDeck or WinDeck running on the computer.
2. Open the mobile companion and select your computer by name. Check the device name in the desktop pairing prompt, then click **Allow** on macOS or **Approve** on Windows.
3. In the desktop editor, select a page or click **+** to create one. Try naming it **Everyday**.
4. Add a **Volume Up** tile. On macOS, drag the volume control from the library onto an empty slot and click **Sync to Phone**. On Windows, select an empty slot, open **Tile Library → Controls**, and click the volume control.
5. Open **Everyday** on your phone and tap the tile. Your computer’s volume should increase. Add your most-used app to the next slot and try launching it the same way.

## Make a recording deck on macOS

In OBS, open **Tools → WebSocket Server Settings**, enable the server, and note its port and password. In MacDeck, open **Configure OBS & Discord… → OBS**, enter the matching connection details, and click **Save & Reconnect**. Enable **OBS Page** in the sidebar. Your scene names become tiles, so you can switch scenes from the phone while keeping the preview visible on your Mac.

## Troubleshooting

| What you see | What to check |
| --- | --- |
| The phone can’t find the computer | Keep the host running and check that both devices can reach each other on the LAN. Guest Wi-Fi can isolate devices. Discovery uses Bonjour/mDNS (`_macdeck._tcp`), and the host accepts connections on TCP port `62233`. |
| A pairing request stays pending | Bring the desktop host window forward. Pairing needs approval on the computer before the phone receives its pages. |
| Apps launch, but Mac media or keyboard tiles do nothing | Check MacDeck’s Accessibility permission in System Settings, then retry the tile. |
| The Windows dashboard window is hidden | While WinDeck is running, open `http://localhost:62234` in a browser on the PC. |
