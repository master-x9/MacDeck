# MacDeck

MacDeck turns your Android phone into a control deck for your Mac. Build a page on your computer, lay your phone beside your keyboard, and tap a tile to do something on the desktop. A writing deck might hold your notes app, a reference site, and a music control. A recording deck on the Mac can put your OBS scenes and microphone under your fingertips.

MacDeck is my favorite project I’ve built. If you’re trying it for the first time, start with one button for something you do every day. That’s enough to make the deck feel like yours. — Jatin

[![Support MacDeck via Razorpay](https://img.shields.io/badge/Support%20MacDeck-242529?style=for-the-badge&logo=razorpay&logoColor=white)](https://macdeck.fun/)

Choose **Support** on the MacDeck site to make a one-time contribution in an amount you choose.

![MacDeck desktop dashboard with the deck editor and tile library](public/macdeck_app_dashboard.png)

## Download and install

The Android companion also pairs with the Windows host. The desktop hosts include Discord controls and OBS live pages.

| Device | Download | Install |
| --- | --- | --- |
| Mac (Apple silicon, macOS 26.5+) | [Download MacDeck.dmg](https://github.com/master-x9/MacDeck/releases/latest/download/MacDeck.dmg) | Open the disk image, copy MacDeck to Applications, and launch it. Allow local network access if prompted. |
| Windows x64 | [Download WinDeck for Windows x64](https://github.com/master-x9/MacDeck/releases/latest/download/WinDeck-Setup.exe) | Run **WinDeck-Setup.exe** once. Future versions appear in the app with release notes. |
| Android phone | [Download MacDeck.apk](https://github.com/master-x9/MacDeck/releases/download/2026.11.27.2/MacDeck.apk) | Open the APK from Downloads and tap **Install**. If Android prompts you, allow installation from the app that opened the file. You can switch that permission off afterward. |

Install the Android app and the host for your computer, then follow [Pair your phone and try a tile](#pair-your-phone-and-try-a-tile). You can also find all downloads on the [GitHub release page](https://github.com/master-x9/MacDeck/releases/latest).

## What can go on a deck?

| On your phone | On your computer |
| --- | --- |
| An app or website tile | Open an application or jump straight to a saved URL. Put the tools for one task together on a named page. |
| Media and system controls | Pause music, skip a track, change volume, take a screenshot, or keep the computer awake. |
| Browser controls | Move between tabs, go back or forward, refresh, or open a new tab while the browser is active. |
| A running-apps page | See which apps are open and tap one to bring it forward. The page updates as the set of running apps changes. |

The **macOS host** also supports app-triggered pages. For example, you can have your recording deck appear when OBS comes to the foreground. Its OBS integration builds tiles from your scene list and adds recording, streaming, replay buffer, and microphone controls. On either host, the Discord page reserves five positions for microphone, deafen, call, camera and screen sharing. The call tile opens Discord while idle, answers an incoming call and disconnects an active call. The next five positions show visible unread DMs and server mentions with Discord’s counts, or the first visible servers in sidebar order. Caller artwork appears when Discord exposes it. Screen sharing opens Discord’s source picker. Keep an English-language Discord desktop window open. On macOS, grant MacDeck Accessibility permission under System Settings → Privacy & Security. Pinned channels on macOS use the optional bot connection. Mac lock and unlock remain exclusive to macOS.

## Pair your phone and try a tile

1. Connect the phone and computer to the same local network. Leave MacDeck running on your Mac.
2. Open the mobile companion and select your computer by name. Check the device name in the desktop pairing prompt, then click **Allow** on your Mac.
3. In the desktop editor, select a page or click **+** to create one. Try naming it **Everyday**.
4. Add a **Volume Up** tile. Drag the volume control from the library onto an empty slot and click **Sync to Phone**.
5. Open **Everyday** on your phone and tap the tile. Your computer’s volume should increase. Add your most-used app to the next slot and try launching it the same way.

Click **Disconnect** on the desktop connection card to end the phone session and keep the pairing saved. The next connection requires desktop approval.

## Make a recording deck on macOS

In OBS, open **Tools → WebSocket Server Settings**, enable the server, and note its port and password. In MacDeck, open **Configure OBS & Discord… → OBS**, enter the matching connection details, and click **Save & Reconnect**. Enable **OBS Page** in the sidebar. Your scene names become tiles, so you can switch scenes from the phone while keeping the preview visible on your Mac.

## Troubleshooting

| What you see | What to check |
| --- | --- |
| The phone can’t find the computer | Keep the host running and check that both devices can reach each other on the LAN. Guest Wi-Fi can isolate devices. Discovery uses Bonjour/mDNS (`_macdeck._tcp`), and the host accepts connections on TCP port `62233`. |
| A pairing request stays pending | Bring the desktop host window forward. Pairing needs approval on the computer before the phone receives its pages. |
| Apps launch, but Mac media or keyboard tiles do nothing | Check MacDeck’s Accessibility permission in System Settings, then retry the tile. |
