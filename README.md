<div align="center">

# MacDeck

**A wireless Stream Deck you already own.**
Turn an Android phone into a control surface for your Mac or PC — one tap, sub-2 ms, entirely over your own LAN.

[![Latest release](https://img.shields.io/github/v/release/master-x9/MacDeck?style=for-the-badge&label=release&color=242529)](https://github.com/master-x9/MacDeck/releases/latest)
[![Stars](https://img.shields.io/github/stars/master-x9/MacDeck?style=for-the-badge&color=242529)](https://github.com/master-x9/MacDeck/stargazers)
[![Support MacDeck](https://img.shields.io/badge/Support%20MacDeck-242529?style=for-the-badge&logo=razorpay&logoColor=white)](https://macdeck.fun/)

[![macOS](https://img.shields.io/badge/macOS-26.5%2B%20%C2%B7%20Apple%20silicon-000?style=flat-square&logo=apple&logoColor=white)](#requirements)
[![Windows](https://img.shields.io/badge/Windows-x64-0078D4?style=flat-square&logo=windows&logoColor=white)](#requirements)
[![Android](https://img.shields.io/badge/Android-7.0%2B-3DDC84?style=flat-square&logo=android&logoColor=white)](#requirements)
[![Zero cloud](https://img.shields.io/badge/network-LAN%20only-242529?style=flat-square)](#security-model)

[**Download**](#download) · [Quick start](#quick-start) · [Features](#what-you-can-build) · [Build from source](#build-from-source) · [Troubleshooting](#troubleshooting)

![MacDeck desktop dashboard with the deck editor and tile library](public/macdeck_app_dashboard.png)

</div>

---

## What it is

MacDeck is a local-network control deck. You lay out tiles on a desktop host, the phone shows those tiles, and a tap fires the action on the computer: launch an app, open a saved URL, adjust volume, take a screenshot, flip browser tabs, bring a running app forward, lock the Mac.

A writing deck might hold your notes app, a reference site, and a music control. A recording deck puts OBS scenes and your mic under your fingertips while the preview stays on the big screen. Nothing leaves the LAN — no account, no subscription, no round trip through someone else's server.

> MacDeck is my favorite project I've built. If you're trying it for the first time, start with one button for something you do every day. That's enough to make the deck feel like yours. — Jatin

## What you can build

| Tiles | Behavior |
| --- | --- |
| **App / URL** | Launch an application or open a saved URL. Group the tools for one task onto a named page. |
| **Media & system** | Play/pause, next track, volume, brightness, screenshot, keep-awake. |
| **Browser** | Back, forward, refresh, next/previous tab, new tab in the active browser. |
| **Running apps** | A live page of open apps — tap to bring one forward. Refreshes as the app set changes. |
| **Keyboard** | Global shortcuts and recorded macros, including custom combos. |
| **Mac lock / unlock** | Lock the Mac, or unlock it from the phone. macOS only. |
| **Discord** | Fixed row for mic, deafen, answer, camera and screen share; second row for unread DMs and mentions with Discord's own counts. |
| **OBS** | Scene tiles generated from your scene list, plus record, stream, replay buffer and mic controls. |
| **App-triggered pages** | A page can surface itself when an app comes to the foreground — e.g. the recording deck when OBS activates. macOS only. |

Custom icons, including animated GIFs, can be assigned to any tile. Layouts adapt to two, three or four rows based on the phone.

## Requirements

| Role | Platform |
| --- | --- |
| Host | **macOS 26.5 or later on Apple silicon** (Intel not supported) |
| Host | **Windows 10/11 x64** with WebView2 (ships with Windows 11 and current Edge) |
| Client | **Android 7.0+ (API 24)**, phone or tablet |
| Network | Both devices on the same LAN, able to reach each other |

The Mac host runs **unsandboxed** by design — sandboxing silently blocks `CGEvent` media-key injection and the `NWListener` socket, so a Stream Deck-style app can't function inside it.

## Download

| Platform | Package | Direct link |
| --- | --- | --- |
| macOS (Apple silicon) | `MacDeck.dmg` — 2.4 MB | [**Download for Mac**](https://github.com/master-x9/MacDeck/releases/latest/download/MacDeck.dmg) |
| Windows x64 | `WinDeck-Setup.exe` — 37 MB | [**Download for Windows**](https://github.com/master-x9/MacDeck/releases/latest/download/WinDeck-Setup.exe) |
| Android | `MacDeck.apk` — 13 MB | [**Download for Android**](https://github.com/master-x9/MacDeck/releases/download/2026.11.27.2/MacDeck.apk) |

Every build, plus per-file SHA-256 checksums, lives on the [releases page](https://github.com/master-x9/MacDeck/releases/latest). Mirror: [macdeck.fun](https://macdeck.fun/#download).

### Verify a download

```bash
# macOS
shasum -a 256 ~/Downloads/MacDeck.dmg
# Windows PowerShell
Get-FileHash .\WinDeck-Setup.exe -Algorithm SHA256
```

Compare against the hash on the release entry before opening anything.

## Install

### macOS

1. Open the disk image, drag **MacDeck** to `/Applications`, launch it.
2. Allow **Local Network** when prompted. Bonjour discovery fails silently without it.
3. Grant **Accessibility** under *System Settings → Privacy & Security* — required for media keys, shortcuts and browser control.
4. Optional: grant **Screen Recording** if you want Discord DM avatars, and allow **Automation** for System Events.

### Windows

1. Run `WinDeck-Setup.exe` once. If you're coming from an old portable ZIP, quit that copy first.
2. Allow WinDeck on **private networks** if Windows Firewall asks.
3. Keep the Discord desktop client installed and open if you want the Discord page.

### Android

1. Open the APK from Downloads and tap **Install**.
2. Allow installation from the file manager when Android asks. You can revoke that permission afterwards.
3. Keep the phone and host on the same Wi-Fi. Guest networks that isolate clients won't work.

## Quick start

1. Start the host on your computer and leave it running.
2. Open the Android app and pick your computer by name from discovery.
3. Confirm the device name in the desktop prompt and click **Allow** / **Approve**.
4. In the desktop editor, create a page — name it **Everyday**.
5. Drag **Volume Up** from the tile library onto an empty slot, then **Sync to Phone**.
6. Tap the tile on your phone. The volume moves. Add your most-used app to the next slot.

**Disconnect** ends the session and keeps the pairing; the next connection needs desktop approval again. Revoke a phone entirely under *Trusted phones* in host settings.

## OBS integration

1. In OBS 28+, enable *Tools → WebSocket Server Settings → Enable WebSocket server*, note the port and password.
2. In the host, open the OBS section of settings, enter the same port and password, **Save & Reconnect**.
3. Enable the **OBS Page**. Scenes become tiles; selecting a control in the desktop preview also fires it.

On Windows the password is stored in Credential Manager. `Previous Scene` / `Next Scene` reach scenes beyond the visible grid in large collections.

## Discord integration

Enable **Discord Calls** and keep an English-language Discord desktop window open. The first row is fixed to mic, deafen, call, camera and screen share; the second row shows up to five unread DMs and mentions, falling back to visible servers in sidebar order. The call tile opens Discord when idle, answers an incoming call, and disconnects an active one. Screen share opens Discord's own source picker.

Discord's tray-only mode, UI language and which controls are visible all affect what MacDeck can read. This page tracks Discord's UI and will occasionally need updates after Discord ships changes.

## Desktop updates

MacDeck and WinDeck 1.2.0 and later self-update. A newer release surfaces in-app with version and notes; accept to download and relaunch. Mac users can also use *MacDeck → Check for Updates…*. Mac builds are EdDSA-signed via Sparkle against the public key in `Info.plist`; WinDeck uses Velopack against the latest GitHub release. Checksums are published for both.

Maintainers: see [`release/README.md`](release/README.md).

## Security model

- **LAN only.** WebSocket on TCP `62233`, discovery via Bonjour `_macdeck._tcp`. No cloud relay, no telemetry, no account.
- **Plaintext WebSocket.** No TLS — fine for a trusted home network, not for hostile Wi-Fi. Encrypt at the network layer if that matters to you.
- **Explicit pairing.** Each new phone must be approved on the desktop. Trusted devices are listed and revocable.
- **Local state.** Decks, trusted phones and settings stay on the host (`AppData/Roaming/WinDeck` on Windows, Application Support on macOS).

## Architecture

Three clients, one protocol.

```
macDeckk/                 macOS host (SwiftUI, Swift 5)
  DeckNetworkManager      NWListener on 62233 + Bonjour advertisement
  SystemActionEngine      CGEvent key injection, app/URL launching
  OBSControlManager       obs-websocket client
  DiscordControlManager   Accessibility-tree reads, call state machine
  RemoteUnlockManager     lock/unlock
  PageStore               deck persistence
  AppFrontmostMonitor     app-triggered pages
  AppUpdates, MenuBarController, LaunchAtLoginManager

windows/                  Windows host (Python 3.11+, WebView2 dashboard)
  network.py              same protocol over asyncio
  action_engine.py        Win32 action execution
  integrations.py         Discord + OBS bridges
  app_updates.py          Velopack updater
  tests/                  unittest suite

android/                  Android client (Kotlin, Jetpack Compose, OkHttp)
  app/                    pages, tiles, pairing, in-app updater

public/, app/, lib/       macdeck.fun site (Next.js 14, Tailwind)
release/                  Sparkle + Velopack + APK signing pipeline
```

## Build from source

### macOS

Requires Xcode and an Apple silicon Mac on macOS 26.5+.

```bash
git clone https://github.com/master-x9/MacDeck.git
cd MacDeck
./release/setup-sparkle.sh   # once, before the first build
open macDeckk.xcodeproj
```

Build with `ENABLE_APP_SANDBOX=NO` (already the project default) and your own signing team. Sparkle updates need the private update key in your login Keychain.

### Windows

Requires Python 3.11+.

```bat
git clone https://github.com/master-x9/MacDeck.git
cd MacDeck\windows
run.bat                      :: install deps and start the host
build_exe.bat                :: standalone build via PyInstaller
python -m unittest discover -s tests
```

### Android

Requires JDK 17 and the Android SDK.

```bash
cd android
./gradlew assembleDebug
```

Release APKs must be signed with the same key as installed builds, or updates will be rejected.

### Website

```bash
npm install && npm run dev
```

## Releasing

Full procedure in [`release/README.md`](release/README.md): bump the Mac build number / Windows semver / Android versionCode, sign the Mac app and ZIP, run `release/prepare-updates.py` for the appcast and APK feed, build the Velopack package, upload everything to a draft release, then verify an update on a previous install before publishing.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Phone can't find the computer | Host running? Same subnet? Guest Wi-Fi isolates clients. Discovery is Bonjour `_macdeck._tcp` on `62233` — confirm the firewall allows it. |
| Pairing request never resolves | Bring the host window forward. Approval happens on the desktop before pages reach the phone. |
| Media, brightness or shortcut tiles do nothing | Grant Accessibility (macOS) and retry. On Windows, check the process isn't running unelevated against an elevated app. |
| Discord tiles stay empty | Discord desktop open and in English, not tray-only. macOS also needs Accessibility. |
| OBS page blank | WebSocket server enabled in OBS, matching port and password, `Save & Reconnect` pressed. |
| No DM avatars | Screen Recording permission (macOS), or Discord hasn't exposed an image link for that row. |

Still stuck? [Open an issue](https://github.com/master-x9/MacDeck/issues) with host OS, phone model, Android version and the steps that reproduce it.

## Known limitations

- Apple silicon only; no Intel Mac build.
- The Windows host is newer and less field-tested than macOS. Lock, unlock and the lock-screen layout are macOS-exclusive.
- Discord support depends on Discord's UI and is fragile across client updates.
- No TLS, no internet-facing mode, no multi-host switching mid-session.
- Android package ID is still `com.example.macdeck` (a rename would break in-place updates, so it's deferred).
- The repo has no license file yet — see below.

## Contributing

Issues and pull requests are welcome. Keep changes small and testable; a "lazy senior developer" rule applies — check whether the platform or an existing helper already solves it before adding a dependency.

- Host changes: add a case to the Windows `tests/` suite.
- Keep the wire protocol compatible across all three clients.
- Match the existing visual language; screenshots for UI changes.

## License

No `LICENSE` file is currently committed, so default copyright applies. Adding MIT would make reuse unambiguous — drop in a `LICENSE` file and the badge above can point at it.

## Acknowledgements

Built by [@master-x9](https://github.com/master-x9). Thanks to the OBS WebSocket and Sparkle projects, and to everyone filing Discord breakage reports.

---

<div align="center">

**[Download for Mac](https://github.com/master-x9/MacDeck/releases/latest/download/MacDeck.dmg) · [Download for Windows](https://github.com/master-x9/MacDeck/releases/latest/download/WinDeck-Setup.exe) · [Download for Android](https://github.com/master-x9/MacDeck/releases/download/2026.11.27.2/MacDeck.apk)**

[macdeck.fun](https://macdeck.fun/) · [Support the project](https://macdeck.fun/)

</div>
