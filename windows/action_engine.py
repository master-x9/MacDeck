"""
WinDeck Action Engine
Executes system controls, media keys, volume, brightness, window management,
app launching, websites, macros, and browser controls using the Win32 API.
"""

import os
import sys
import time
import logging
import subprocess
import webbrowser
from typing import Optional, List, Dict, Tuple
try:
    from .models import TileType, SystemControlAction, BrowserControlAction
except ImportError:
    from models import TileType, SystemControlAction, BrowserControlAction

logger = logging.getLogger("WinDeck.ActionEngine")

IS_WINDOWS = sys.platform == "win32"
BROWSERS = {"chrome.exe", "msedge.exe", "brave.exe", "firefox.exe", "vivaldi.exe", "opera.exe"}

if IS_WINDOWS:
    import ctypes
    from ctypes import wintypes
    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32
    shell32 = ctypes.windll.shell32
    powrprof = ctypes.windll.powrprof
else:
    user32 = None
    kernel32 = None
    shell32 = None
    powrprof = None

# Windows Virtual-Key Codes
VK_LBUTTON = 0x01
VK_CANCEL = 0x03
VK_BACK = 0x08
VK_TAB = 0x09
VK_RETURN = 0x0D
VK_SHIFT = 0x10
VK_CONTROL = 0x11
VK_MENU = 0x12  # Alt
VK_PAUSE = 0x13
VK_ESCAPE = 0x1B
VK_SPACE = 0x20
VK_LEFT = 0x25
VK_UP = 0x26
VK_RIGHT = 0x27
VK_DOWN = 0x28
VK_SNAPSHOT = 0x2C  # Print Screen
VK_LWIN = 0x5B
VK_RWIN = 0x5C
VK_F1 = 0x70
VK_F4 = 0x73
VK_F5 = 0x74
VK_F11 = 0x7A
VK_F12 = 0x7B

# Multimedia Keys
VK_VOLUME_MUTE = 0xAD
VK_VOLUME_DOWN = 0xAE
VK_VOLUME_UP = 0xAF
VK_MEDIA_NEXT_TRACK = 0xB0
VK_MEDIA_PREV_TRACK = 0xB1
VK_MEDIA_STOP = 0xB2
VK_MEDIA_PLAY_PAUSE = 0xB3

# Execution State flags for Keep Awake
ES_CONTINUOUS = 0x80000000
ES_SYSTEM_REQUIRED = 0x00000001
ES_DISPLAY_REQUIRED = 0x00000002
ES_AWAYMODE_REQUIRED = 0x00000040

KEYEVENTF_EXTENDEDKEY = 0x0001
KEYEVENTF_KEYUP = 0x0002


class ActionEngine:
    """Executes actions triggered from mobile companion or desktop UI."""

    def __init__(self):
        self.is_keep_awake_active: bool = False

    # -------------------------------------------------------------------------
    # Low-level Keystroke Injection (Win32 keybd_event)
    # -------------------------------------------------------------------------
    def press_key(self, vk_code: int):
        """Sends key down event."""
        if IS_WINDOWS and user32:
            user32.keybd_event(vk_code, 0, KEYEVENTF_EXTENDEDKEY, 0)
        else:
            logger.debug(f"[MOCK] Key down: 0x{vk_code:02X}")

    def release_key(self, vk_code: int):
        """Sends key up event."""
        if IS_WINDOWS and user32:
            user32.keybd_event(vk_code, 0, KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP, 0)
        else:
            logger.debug(f"[MOCK] Key up: 0x{vk_code:02X}")

    def tap_key(self, vk_code: int, delay: float = 0.03):
        """Taps a single virtual key."""
        self.press_key(vk_code)
        time.sleep(delay)
        self.release_key(vk_code)

    def tap_combo(self, modifiers: List[int], key: int, delay: float = 0.03):
        """Taps a key with modifiers (e.g. Ctrl + Shift + S)."""
        for mod in modifiers:
            self.press_key(mod)
        time.sleep(delay)
        self.tap_key(key, delay=delay)
        for mod in reversed(modifiers):
            self.release_key(mod)

    # -------------------------------------------------------------------------
    # Public Dispatch
    # -------------------------------------------------------------------------
    def execute(self, tile_type: TileType):
        """Executes a tile action."""
        kind = tile_type.type
        logger.info(f"Executing tile: kind={kind}, action={tile_type.action}, url={tile_type.url}")

        try:
            if kind == "systemControl" and tile_type.action:
                self.perform_system_control(SystemControlAction(tile_type.action))
            elif kind == "browserControl" and tile_type.action:
                self.perform_browser_control(BrowserControlAction(tile_type.action))
            elif kind == "app":
                self.launch_app(tile_type.bundleIdentifier or tile_type.name or "")
            elif kind == "website" and tile_type.url:
                self.open_website(tile_type.url)
            elif kind == "shortcut" and tile_type.name:
                self.execute_macro(tile_type.name)
            else:
                logger.warning(f"Unknown or unhandled tile type: {kind}")
        except Exception as e:
            logger.error(f"Error executing action {tile_type}: {e}", exc_info=True)

    # -------------------------------------------------------------------------
    # System Controls
    # -------------------------------------------------------------------------
    def perform_system_control(self, action: SystemControlAction):
        """Executes a SystemControlAction on Windows."""
        if action == SystemControlAction.playPause:
            self.tap_key(VK_MEDIA_PLAY_PAUSE)
        elif action == SystemControlAction.nextTrack:
            self.tap_key(VK_MEDIA_NEXT_TRACK)
        elif action == SystemControlAction.previousTrack:
            self.tap_key(VK_MEDIA_PREV_TRACK)
        elif action == SystemControlAction.volumeUp:
            self.tap_key(VK_VOLUME_UP)
        elif action == SystemControlAction.volumeDown:
            self.tap_key(VK_VOLUME_DOWN)
        elif action == SystemControlAction.mute:
            self.tap_key(VK_VOLUME_MUTE)
        elif action == SystemControlAction.brightnessUp:
            self.adjust_brightness(step=10)
        elif action == SystemControlAction.brightnessDown:
            self.adjust_brightness(step=-10)
        elif action == SystemControlAction.sleepMac:
            self.sleep_pc()
        elif action == SystemControlAction.keepAwake:
            self.toggle_keep_awake()
        elif action == SystemControlAction.desktop:
            # Win + D
            self.tap_combo([VK_LWIN], 0x44)  # 'D'
        elif action == SystemControlAction.missionControl:
            # Win + Tab (Task View)
            self.tap_combo([VK_LWIN], VK_TAB)
        elif action == SystemControlAction.quitFrontmostApp:
            # Alt + F4
            self.tap_combo([VK_MENU], VK_F4)
        elif action == SystemControlAction.screenshot:
            # Win + Shift + S (Windows Snipping Tool)
            self.tap_combo([VK_LWIN, VK_SHIFT], 0x53)  # 'S'
        elif action == SystemControlAction.screenRecord:
            # Win + Alt + R (Xbox Game Bar screen recording toggle)
            self.tap_combo([VK_LWIN, VK_MENU], 0x52)  # 'R'
        elif action == SystemControlAction.emptyTrash:
            self.empty_recycle_bin()

    def sleep_pc(self):
        """Puts Windows PC to sleep."""
        if IS_WINDOWS:
            try:
                if powrprof:
                    # SetSuspendState(bHibernate=False, bForce=False, bWakeupEventsDisabled=False)
                    powrprof.SetSuspendState(0, 1, 0)
                else:
                    subprocess.run(["rundll32.exe", "powrprof.dll,SetSuspendState", "0,1,0"], check=False)
            except Exception as e:
                logger.error(f"Failed to sleep PC: {e}")
        else:
            logger.info("[MOCK] PC sleep triggered")

    def toggle_keep_awake(self) -> bool:
        """Toggles anti-sleep / display keep-awake assertion."""
        if self.is_keep_awake_active:
            if IS_WINDOWS and kernel32:
                kernel32.SetThreadExecutionState(ES_CONTINUOUS)
            self.is_keep_awake_active = False
            logger.info("Keep Awake disabled")
        else:
            if IS_WINDOWS and kernel32:
                kernel32.SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)
            self.is_keep_awake_active = True
            logger.info("Keep Awake enabled")
        return self.is_keep_awake_active

    def empty_recycle_bin(self):
        """Empties the Windows Recycle Bin without prompt."""
        if IS_WINDOWS and shell32:
            try:
                # SHERB_NOCONFIRMATION = 0x00000001
                # SHERB_NOPROGRESSUI   = 0x00000002
                # SHERB_NOSOUND        = 0x00000004
                flags = 0x00000001 | 0x00000002
                shell32.SHEmptyRecycleBinW(0, None, flags)
            except Exception as e:
                logger.error(f"Failed to empty recycle bin: {e}")
        else:
            logger.info("[MOCK] Recycle bin emptied")

    def adjust_brightness(self, step: int):
        """Adjusts monitor brightness via PowerShell WMI or simulated keys."""
        if IS_WINDOWS:
            cmd = f"(Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightnessMethods).WmiSetBrightness(1, [Math]::Min(100, [Math]::Max(0, (Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightness).CurrentBrightness + ({step}))))"
            try:
                subprocess.Popen(["powershell", "-NoProfile", "-Command", cmd],
                                 creationflags=subprocess.CREATE_NO_WINDOW if IS_WINDOWS else 0)
            except Exception as e:
                logger.debug(f"WMI brightness adjust failed: {e}")

    # -------------------------------------------------------------------------
    # Browser Controls
    # -------------------------------------------------------------------------
    def perform_browser_control(self, action: BrowserControlAction):
        """Executes tab and navigation shortcuts for browsers."""
        if IS_WINDOWS and self.foreground_executable() not in BROWSERS:
            return
        key_map = {
            BrowserControlAction.switchTab1: ([VK_CONTROL], 0x31),  # Ctrl+1
            BrowserControlAction.switchTab2: ([VK_CONTROL], 0x32),  # Ctrl+2
            BrowserControlAction.switchTab3: ([VK_CONTROL], 0x33),  # Ctrl+3
            BrowserControlAction.switchTab4: ([VK_CONTROL], 0x34),  # Ctrl+4
            BrowserControlAction.switchTab5: ([VK_CONTROL], 0x35),  # Ctrl+5
            BrowserControlAction.back: ([VK_MENU], VK_LEFT),        # Alt+Left
            BrowserControlAction.forward: ([VK_MENU], VK_RIGHT),    # Alt+Right
            BrowserControlAction.refresh: ([VK_CONTROL], 0x52),     # Ctrl+R
            BrowserControlAction.newTab: ([VK_CONTROL], 0x54),      # Ctrl+T
            BrowserControlAction.closeTab: ([VK_CONTROL], 0x57),    # Ctrl+W
        }
        if action in key_map:
            mods, key = key_map[action]
            self.tap_combo(mods, key)

    # -------------------------------------------------------------------------
    # App & Website Launchers
    # -------------------------------------------------------------------------
    def launch_app(self, path_or_name: str):
        """Launches an application executable or shortcut."""
        if not path_or_name:
            return
        if IS_WINDOWS:
            try:
                os.startfile(path_or_name)
            except Exception as e:
                logger.error(f"Failed to launch app {path_or_name}: {e}")
        else:
            logger.info(f"[MOCK] Launched app: {path_or_name}")

    def open_website(self, url: str):
        """Opens a website in the user's default browser."""
        normalized = url.strip()
        if not normalized.lower().startswith("http://") and not normalized.lower().startswith("https://"):
            normalized = f"https://{normalized}"
        webbrowser.open(normalized)

    # -------------------------------------------------------------------------
    # Macros & Shortcuts
    # -------------------------------------------------------------------------
    def execute_macro(self, macro_name: str):
        """
        Executes a keyboard macro string.
        Format can be 'CTRL+SHIFT+ESC' or 'WIN+D' or custom string.
        """
        keys = [k.strip().upper() for k in macro_name.split("+")]
        mod_map = {
            "CTRL": VK_CONTROL,
            "CONTROL": VK_CONTROL,
            "SHIFT": VK_SHIFT,
            "ALT": VK_MENU,
            "WIN": VK_LWIN,
            "CMD": VK_LWIN,
        }
        modifiers = []
        regular_key = None

        for k in keys:
            if k in mod_map:
                modifiers.append(mod_map[k])
            elif len(k) == 1:
                regular_key = ord(k)
            elif k.startswith("F") and k[1:].isdigit():
                f_num = int(k[1:])
                regular_key = VK_F1 + (f_num - 1)
            elif k == "ENTER":
                regular_key = VK_RETURN
            elif k == "TAB":
                regular_key = VK_TAB
            elif k == "SPACE":
                regular_key = VK_SPACE
            elif k == "ESC":
                regular_key = VK_ESCAPE

        if regular_key:
            self.tap_combo(modifiers, regular_key)
        elif modifiers:
            for m in modifiers:
                self.tap_key(m)

    # -------------------------------------------------------------------------
    # Running Apps Enumeration
    # -------------------------------------------------------------------------
    def get_running_apps(self) -> List[Dict[str, str]]:
        """
        Returns a list of visible running top-level window titles.
        Useful for the Running Apps dynamic page.
        """
        results: List[Dict[str, str]] = []
        if not IS_WINDOWS or not user32:
            return [
                {"name": "Google Chrome", "bundleIdentifier": "chrome.exe"},
                {"name": "Visual Studio Code", "bundleIdentifier": "code.exe"},
                {"name": "Discord", "bundleIdentifier": "discord.exe"},
                {"name": "Spotify", "bundleIdentifier": "spotify.exe"},
            ]

        def enum_windows_callback(hwnd, extra):
            if user32.IsWindowVisible(hwnd):
                length = user32.GetWindowTextLengthW(hwnd)
                if length > 0:
                    buffer = ctypes.create_unicode_buffer(length + 1)
                    user32.GetWindowTextW(hwnd, buffer, length + 1)
                    title = buffer.value.strip()
                    # Filter out tiny or background tool windows
                    if title and title not in ["Program Manager", "Settings"]:
                        results.append({"name": title, "bundleIdentifier": str(hwnd)})
            return True

        WNDENUMPROC = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_ssize_t)
        user32.EnumWindows(WNDENUMPROC(enum_windows_callback), 0)
        return results[:10]

    @staticmethod
    def foreground_executable():
        if IS_WINDOWS:
            import win32gui
            import win32process
            import psutil
            hwnd = win32gui.GetForegroundWindow()
            if hwnd:
                try:
                    pid = win32process.GetWindowThreadProcessId(hwnd)[1]
                    return psutil.Process(pid).name().casefold()
                except (OSError, psutil.Error):
                    pass
        return None

    def focus_window(self, hwnd_or_name: str):
        """Brings a window to the foreground."""
        if IS_WINDOWS and user32 and hwnd_or_name.isdigit():
            hwnd = int(hwnd_or_name)
            user32.ShowWindow(hwnd, 9)  # SW_RESTORE
            user32.SetForegroundWindow(hwnd)

    # -------------------------------------------------------------------------
    # Installed Apps Scanner
    # -------------------------------------------------------------------------
    @staticmethod
    def discover_installed_apps() -> List[Dict[str, str]]:
        """Scans Windows Start Menu for installed applications."""
        apps = []
        if not IS_WINDOWS:
            return [
                {"name": "Chrome", "path": "chrome.exe"},
                {"name": "VS Code", "path": "code.exe"},
                {"name": "Discord", "path": "discord.exe"},
                {"name": "Spotify", "path": "spotify.exe"},
                {"name": "Calculator", "path": "calc.exe"},
                {"name": "Notepad", "path": "notepad.exe"},
            ]

        search_dirs = [
            os.path.join(os.environ.get("ProgramData", "C:\\ProgramData"), "Microsoft\\Windows\\Start Menu\\Programs"),
            os.path.join(os.environ.get("APPDATA", ""), "Microsoft\\Windows\\Start Menu\\Programs")
        ]

        seen_names = set()
        for base in search_dirs:
            if not os.path.exists(base):
                continue
            for root, _, files in os.walk(base):
                for f in files:
                    if f.lower().endswith(".lnk") or f.lower().endswith(".exe"):
                        name = os.path.splitext(f)[0]
                        full_path = os.path.join(root, f)
                        # Filter uninstaller shortcuts
                        if "uninstall" in name.lower() or name in seen_names:
                            continue
                        seen_names.add(name)
                        apps.append({"name": name, "path": full_path})

        return sorted(apps, key=lambda x: x["name"].lower())
