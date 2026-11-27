"""
WinDeck PageStore & Device Trust Store
Manages user-configured pages, dynamic pages (Running Apps, Browser Control, integrations),
and device pairing persistence in %APPDATA%/WinDeck/.
"""

import os
import sys
import json
import uuid
import logging
from datetime import datetime, timezone
from typing import List, Optional, Dict, Any, Callable
try:
    from .models import (
        DeckPage, DeckTile, TileType, SystemControlAction, BrowserControlAction
    )
    from .icons import get_icon, fetch_favicon
except ImportError:
    from models import (
        DeckPage, DeckTile, TileType, SystemControlAction, BrowserControlAction
    )
    from icons import get_icon, fetch_favicon

logger = logging.getLogger("WinDeck.PageStore")

# Well-known dynamic page UUIDs (matching MacDeck exactly)
RUNNING_APPS_PAGE_ID = "00000000-0000-0000-0000-000000000001"
LOCKED_PAGE_ID = "00000000-0000-0000-0000-000000000002"
BROWSER_PAGE_ID = "00000000-0000-0000-0000-000000000003"


def supported(tile_type):
    if tile_type.type == "systemControl":
        return tile_type.action in SystemControlAction._value2member_map_
    if tile_type.type == "shortcut" and (tile_type.name or "").upper().replace(" ", "") in ("WIN+L", "WIN+L(LOCK)"):
        return False
    return True


def get_storage_dir(custom_dir: Optional[str] = None) -> str:
    """Returns the persistent storage directory for WinDeck."""
    if custom_dir:
        os.makedirs(custom_dir, exist_ok=True)
        return custom_dir
    if sys.platform == "win32":
        base = os.environ.get("APPDATA", os.path.expanduser("~\\AppData\\Roaming"))
        path = os.path.join(base, "WinDeck")
    else:
        try:
            home_path = os.path.expanduser("~/.windeck")
            os.makedirs(home_path, exist_ok=True)
            return home_path
        except (PermissionError, OSError):
            path = os.path.abspath(os.path.join(os.path.dirname(__file__), ".windeck_data"))
    os.makedirs(path, exist_ok=True)
    return path


# -----------------------------------------------------------------------------
# Browser Control Page Provider
# -----------------------------------------------------------------------------
class BrowserPageProvider:
    """Fixed browser navigation control page layout."""
    browser_page_id = BROWSER_PAGE_ID

    @classmethod
    def get_browser_page(cls) -> DeckPage:
        actions = [
            (0, BrowserControlAction.switchTab1),
            (1, BrowserControlAction.switchTab2),
            (2, BrowserControlAction.switchTab3),
            (3, BrowserControlAction.switchTab4),
            (4, BrowserControlAction.switchTab5),
            (5, BrowserControlAction.back),
            (6, BrowserControlAction.forward),
            (7, BrowserControlAction.refresh),
            (8, BrowserControlAction.newTab),
            (9, BrowserControlAction.closeTab),
        ]
        tiles: List[Optional[DeckTile]] = [None] * 20
        for slot, act in actions:
            tiles[slot] = DeckTile(
                id=str(uuid.uuid5(uuid.UUID(cls.browser_page_id), str(slot))).upper(),
                slotIndex=slot,
                tileType=TileType(type="browserControl", action=act.value),
                iconData=get_icon(act.value),
            )
        return DeckPage(
            id=cls.browser_page_id,
            name="Browser Control",
            pageNumber=0,
            tiles=tiles,
        )


# -----------------------------------------------------------------------------
# Trusted Device Store
# -----------------------------------------------------------------------------
class TrustedDeviceStore:
    """Manages pairing approval and stored trusted mobile devices."""

    def __init__(self, storage_dir: str):
        self.file_path = os.path.join(storage_dir, "TrustedDevices.json")
        self.devices: List[Dict[str, Any]] = []
        self.load()

    def is_trusted(self, client_id: str) -> bool:
        return any(d.get("clientID") == client_id for d in self.devices)

    def trust(self, client_id: str, device_name: str):
        self.devices = [d for d in self.devices if d.get("clientID") != client_id]
        self.devices.append({
            "clientID": client_id,
            "deviceName": device_name,
            "lastConnected": datetime.now(timezone.utc).isoformat(),
        })
        self.save()
        logger.info(f"Trusted device: {device_name} ({client_id})")

    def forget(self, client_id: str):
        self.devices = [d for d in self.devices if d.get("clientID") != client_id]
        self.save()

    def record_connection(self, client_id: str):
        for d in self.devices:
            if d.get("clientID") == client_id:
                d["lastConnected"] = datetime.now(timezone.utc).isoformat()
                self.save()
                break

    def load(self):
        if os.path.exists(self.file_path):
            try:
                with open(self.file_path, "r", encoding="utf-8") as f:
                    self.devices = json.load(f)
            except Exception as e:
                logger.error(f"Error loading TrustedDevices.json: {e}")
                self.devices = []
        else:
            self.devices = []

    def save(self):
        try:
            with open(self.file_path, "w", encoding="utf-8") as f:
                json.dump(self.devices, f, indent=2)
        except Exception as e:
            logger.error(f"Error saving TrustedDevices.json: {e}")


# -----------------------------------------------------------------------------
# Page Store
# -----------------------------------------------------------------------------
class PageStore:
    """Manages all deck pages and dynamic page providers."""

    def __init__(self, action_engine=None, storage_dir=None):
        self.storage_dir = get_storage_dir(storage_dir)
        self.pages_file = os.path.join(self.storage_dir, "pages.json")
        self.settings_file = os.path.join(self.storage_dir, "settings.json")
        self.trusted_devices = TrustedDeviceStore(self.storage_dir)
        self.action_engine = action_engine

        self.pages: List[DeckPage] = []
        self.selected_page_id: Optional[str] = None
        self.show_running_apps_page: bool = True
        self.show_browser_control_page: bool = True

        self.browser_active = False
        self.running_apps = []
        self.live_pages = {}
        self.grid_rows = 2
        self.show_obs = True
        self.show_discord = True
        self.obs_port = 4455
        self.on_change_callbacks: List[Callable[[], None]] = []

        self.load()
        if not self.pages:
            self.pages = [self.create_default_main_page()]
            self.save()
        if not any(page.id == self.selected_page_id for page in self.all_pages) and self.pages:
            self.selected_page_id = self.pages[0].id

    def update_live_page(self, page_id, page):
        if self.live_pages.get(page_id) == page:
            return
        pages = dict(self.live_pages)
        if page:
            pages[page_id] = page
        else:
            pages.pop(page_id, None)
            if self.selected_page_id == page_id:
                self.selected_page_id = self.pages[0].id
        self.live_pages = pages
        for callback in self.on_change_callbacks:
            callback()

    def subscribe(self, callback: Callable[[], None]):
        """Subscribes to page modifications."""
        self.on_change_callbacks.append(callback)

    def notify_changes(self):
        """Notifies subscribers that pages or selection changed."""
        self.save()
        for cb in self.on_change_callbacks:
            try:
                cb()
            except Exception as e:
                logger.error(f"Callback error: {e}")

    # -------------------------------------------------------------------------
    # Dynamic Pages & All Pages
    # -------------------------------------------------------------------------
    def set_browser_active(self, active):
        if self.browser_active != active:
            self.browser_active = active
            if not active and self.selected_page_id == BROWSER_PAGE_ID:
                self.selected_page_id = self.pages[0].id
            for callback in self.on_change_callbacks:
                callback()

    def refresh_running_apps(self):
        if self.show_running_apps_page and self.action_engine:
            apps = self.action_engine.get_running_apps()
            if apps != self.running_apps:
                self.running_apps = apps
                for callback in self.on_change_callbacks:
                    callback()

    def get_running_apps_page(self) -> DeckPage:
        """Constructs a running apps page from active Windows visible windows."""
        tiles: List[Optional[DeckTile]] = [None] * 20
        if self.action_engine:
            running = self.running_apps
            for idx, app in enumerate(running[:10]):
                tiles[idx] = DeckTile(
                    id=str(uuid.uuid5(uuid.UUID(RUNNING_APPS_PAGE_ID), app["bundleIdentifier"])).upper(),
                    slotIndex=idx,
                    tileType=TileType(type="app", name=app["name"], bundleIdentifier=app["bundleIdentifier"]),
                    customLabel=app["name"][:12],
                    iconData=app.get("iconData") or get_icon("app"),
                )
        return DeckPage(
            id=RUNNING_APPS_PAGE_ID,
            name="Running Apps",
            pageNumber=0,
            tiles=tiles,
        )

    @property
    def all_pages(self) -> List[DeckPage]:
        """Returns all pages: dynamic pages (if enabled) followed by user pages."""
        pages_list: List[DeckPage] = []
        if self.show_browser_control_page and self.browser_active:
            pages_list.append(BrowserPageProvider.get_browser_page())
        if self.show_running_apps_page:
            pages_list.append(self.get_running_apps_page())
        pages_list.extend(p for p in self.live_pages.values()
                          if (p.pageNumber == -2 and self.show_obs) or (p.pageNumber == -4 and self.show_discord))
        pages_list.extend(self.pages)
        return pages_list

    @property
    def active_page(self) -> Optional[DeckPage]:
        """The currently selected page."""
        for p in self.all_pages:
            if p.id == self.selected_page_id:
                return p
        return self.pages[0] if self.pages else None

    # -------------------------------------------------------------------------
    # Page Operations
    # -------------------------------------------------------------------------
    def create_default_main_page(self) -> DeckPage:
        """Creates the initial default 2x5 page for new users."""
        default_actions = [
            (0, SystemControlAction.volumeUp),
            (1, SystemControlAction.volumeDown),
            (2, SystemControlAction.playPause),
            (3, SystemControlAction.nextTrack),
            (4, SystemControlAction.mute),
            (5, SystemControlAction.screenshot),
            (6, SystemControlAction.keepAwake),
            (7, SystemControlAction.previousTrack),
            (8, SystemControlAction.desktop),
            (9, SystemControlAction.emptyTrash),
        ]
        tiles: List[Optional[DeckTile]] = [None] * 20
        for slot, act in default_actions:
            tiles[slot] = DeckTile(
                slotIndex=slot,
                tileType=TileType(type="systemControl", action=act.value),
                customLabel=act.display_name,
                iconData=get_icon(act.value),
            )
        return DeckPage(name="Main", pageNumber=1, tiles=tiles)

    def add_page(self, name: str = "New Page") -> DeckPage:
        page_num = len(self.pages) + 1
        new_page = DeckPage(name=name, pageNumber=page_num)
        self.pages.append(new_page)
        self.selected_page_id = new_page.id
        self.notify_changes()
        return new_page

    def delete_page(self, page_id: str) -> bool:
        if len(self.pages) <= 1:
            return False  # Don't delete the only page
        self.pages = [p for p in self.pages if p.id != page_id]
        if self.selected_page_id == page_id:
            self.selected_page_id = self.pages[0].id
        self.notify_changes()
        return True

    def rename_page(self, page_id: str, new_name: str):
        for p in self.pages:
            if p.id == page_id:
                p.name = new_name.strip()
                self.notify_changes()
                break

    def set_tile(self, page_id: str, slot_index: int, tile: DeckTile):
        """Sets or replaces a tile in a page's slot."""
        if not supported(tile.tileType):
            return
        for p in self.pages:
            if p.id == page_id and 0 <= slot_index < len(p.tiles):
                tile.slotIndex = slot_index
                if not tile.iconData:
                    tile.iconData = get_icon(tile.tileType.action or tile.tileType.type)
                p.tiles[slot_index] = tile
                self.notify_changes()
                break

    def clear_tile(self, page_id: str, slot_index: int):
        """Clears a slot."""
        for p in self.pages:
            if p.id == page_id and 0 <= slot_index < len(p.tiles):
                p.tiles[slot_index] = None
                self.notify_changes()
                break

    def swap_tiles(self, page_id: str, slot_a: int, slot_b: int):
        """Swaps two slots in a page."""
        for p in self.pages:
            if p.id == page_id and 0 <= slot_a < len(p.tiles) and 0 <= slot_b < len(p.tiles):
                a = p.tiles[slot_a]
                b = p.tiles[slot_b]
                if a:
                    a.slotIndex = slot_b
                if b:
                    b.slotIndex = slot_a
                p.tiles[slot_a] = b
                p.tiles[slot_b] = a
                self.notify_changes()
                break

    # -------------------------------------------------------------------------
    # Persistence
    # -------------------------------------------------------------------------
    def load(self):
        if os.path.exists(self.pages_file):
            try:
                with open(self.pages_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                self.pages = [DeckPage.from_dict(p) for p in data if p.get("id") != LOCKED_PAGE_ID]
                for page in self.pages:
                    for slot, tile in enumerate(page.tiles):
                        if tile and not supported(tile.tileType):
                            page.tiles[slot] = None
            except Exception as e:
                logger.error(f"Failed to load pages.json: {e}")
                self.pages = []

        if os.path.exists(self.settings_file):
            try:
                with open(self.settings_file, "r", encoding="utf-8") as f:
                    settings = json.load(f)
                self.show_running_apps_page = settings.get("showRunningAppsPage", True)
                self.show_browser_control_page = settings.get("showBrowserControlPage", True)
                self.show_obs = settings.get("showOBS", True)
                self.show_discord = settings.get("showDiscord", True)
                self.obs_port = settings.get("obsPort", 4455)
                self.selected_page_id = settings.get("selectedPageID")
            except Exception as e:
                logger.error(f"Failed to load settings.json: {e}")

    def save(self):
        try:
            pages_data = [p.to_dict() for p in self.pages]
            with open(self.pages_file, "w", encoding="utf-8") as f:
                json.dump(pages_data, f, indent=2)

            settings = {
                "showRunningAppsPage": self.show_running_apps_page,
                "showBrowserControlPage": self.show_browser_control_page,
                "showOBS": self.show_obs,
                "showDiscord": self.show_discord,
                "obsPort": self.obs_port,
                "selectedPageID": self.selected_page_id,
            }
            with open(self.settings_file, "w", encoding="utf-8") as f:
                json.dump(settings, f, indent=2)
        except Exception as e:
            logger.error(f"Failed to save WinDeck state: {e}")
