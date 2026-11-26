# MacDeck

MacDeck turns a phone into a customizable control deck for your computer. Arrange tiles in the desktop editor, then tap them on your phone to launch apps, open websites, control playback, or trigger keyboard shortcuts. This repository contains the macOS host and its Windows counterpart, WinDeck.

![MacDeck desktop editor](public/macdeck_app_dashboard.png)

## Run on macOS

1. Open `macDeckk.xcodeproj` in Xcode. The project targets macOS 26.5.
2. Select the MacDeck app target and your Mac as the run destination, then choose **Product → Run**.
3. Use the desktop editor to add an action to a tile on your deck.

## Run on Windows

Install Python with the Python executable on your PATH, then double-click `windows/run.bat` to install dependencies and launch WinDeck. To build an executable, run `windows/build_exe.bat` and choose the single-file or folder build. See the [WinDeck guide](windows/README.md) for command-line setup and supported actions.

## Connect your phone

Connect your phone and computer to the same Wi-Fi network. With the desktop host running, open the MacDeck companion app on your phone, select your computer, and approve the pairing request on the desktop. Tap a configured tile on the phone to try it.
