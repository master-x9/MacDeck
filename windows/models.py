"""
WinDeck Data Models
Mirrors MacDeck's DeckModels.swift 1:1 for the WebSocket wire protocol.
"""

from dataclasses import dataclass, field
from enum import Enum
from typing import Optional, List, Dict, Any
import uuid
import json


class SystemControlAction(str, Enum):
    brightnessUp = "brightnessUp"
    brightnessDown = "brightnessDown"
    playPause = "playPause"
    nextTrack = "nextTrack"
    previousTrack = "previousTrack"
    mute = "mute"
    volumeUp = "volumeUp"
    volumeDown = "volumeDown"
    screenshot = "screenshot"
    screenRecord = "screenRecord"
    keepAwake = "keepAwake"
    quitFrontmostApp = "quitFrontmostApp"
    sleepMac = "sleepMac"  # Wire protocol uses "sleepMac" for sleep PC
    desktop = "desktop"
    missionControl = "missionControl"  # Task View (Win+Tab)
    emptyTrash = "emptyTrash"

    @property
    def display_name(self) -> str:
        names = {
            "brightnessUp": "Bright",
            "brightnessDown": "Dim",
            "playPause": "Play",
            "nextTrack": "Next",
            "previousTrack": "Previous",
            "mute": "Mute",
            "volumeUp": "Vol +",
            "volumeDown": "Vol -",
            "screenshot": "Screenshot",
            "screenRecord": "Record",
            "keepAwake": "Caffeine",
            "quitFrontmostApp": "Quit App",
            "sleepMac": "Sleep PC",
            "desktop": "Desktop",
            "missionControl": "Task View",
            "emptyTrash": "Empty Bin",
        }
        return names.get(self.value, self.value)

    @property
    def badge(self) -> str:
        badges = {
            "brightnessDown": "F1",
            "brightnessUp": "F2",
            "missionControl": "⊞Tab",
            "previousTrack": "Prev",
            "playPause": "Play",
            "nextTrack": "Next",
            "mute": "Mute",
            "volumeDown": "Vol-",
            "volumeUp": "Vol+",
            "screenshot": "⊞⇧S",
            "screenRecord": "⊞AltR",
            "quitFrontmostApp": "Alt+F4",
            "desktop": "⊞D",
            "emptyTrash": "Bin",
            "keepAwake": "☕",
            "sleepMac": "☾",
        }
        return badges.get(self.value, "")


class BrowserControlAction(str, Enum):
    switchTab1 = "switchTab1"
    switchTab2 = "switchTab2"
    switchTab3 = "switchTab3"
    switchTab4 = "switchTab4"
    switchTab5 = "switchTab5"
    back = "back"
    forward = "forward"
    refresh = "refresh"
    newTab = "newTab"
    closeTab = "closeTab"

    @property
    def display_name(self) -> str:
        names = {
            "switchTab1": "Tab 1",
            "switchTab2": "Tab 2",
            "switchTab3": "Tab 3",
            "switchTab4": "Tab 4",
            "switchTab5": "Tab 5",
            "back": "Back",
            "forward": "Forward",
            "refresh": "Refresh",
            "newTab": "New Tab",
            "closeTab": "Close Tab",
        }
        return names.get(self.value, self.value)


@dataclass
class TileType:
    type: str  # app, systemControl, browserControl, website, shortcut, obsControl, discordControl
    bundleIdentifier: Optional[str] = None
    name: Optional[str] = None
    action: Optional[str] = None
    url: Optional[str] = None

    @property
    def default_label(self) -> str:
        if self.type == "app":
            return self.name or "App"
        elif self.type == "website":
            return self.name or self.url or "Website"
        elif self.type == "shortcut":
            return self.name or "Macro"
        elif self.type == "systemControl" and self.action:
            try:
                return SystemControlAction(self.action).display_name
            except ValueError:
                return self.action
        elif self.type == "browserControl" and self.action:
            try:
                return BrowserControlAction(self.action).display_name
            except ValueError:
                return self.action
        elif self.type == "obsControl":
            return self.name or "OBS"
        elif self.type == "discordControl":
            return self.name or "Discord"
        return self.name or ""

    def to_dict(self) -> Dict[str, Any]:
        d = {"type": self.type}
        if self.bundleIdentifier is not None:
            d["bundleIdentifier"] = self.bundleIdentifier
        if self.name is not None:
            d["name"] = self.name
        if self.action is not None:
            d["action"] = self.action
        if self.url is not None:
            d["url"] = self.url
        return d

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "TileType":
        return cls(
            type=data.get("type", ""),
            bundleIdentifier=data.get("bundleIdentifier"),
            name=data.get("name"),
            action=data.get("action"),
            url=data.get("url"),
        )


@dataclass
class DeckTile:
    slotIndex: int
    tileType: TileType
    id: str = field(default_factory=lambda: str(uuid.uuid4()).upper())
    customLabel: Optional[str] = None
    iconData: Optional[str] = None  # Base64 encoded PNG

    @property
    def label(self) -> str:
        return self.customLabel or self.tileType.default_label

    def to_dict(self) -> Dict[str, Any]:
        d = {
            "id": self.id,
            "slotIndex": self.slotIndex,
            "tileType": self.tileType.to_dict(),
        }
        if self.customLabel is not None:
            d["customLabel"] = self.customLabel
        if self.iconData is not None:
            d["iconData"] = self.iconData
        return d

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "DeckTile":
        return cls(
            id=data.get("id", str(uuid.uuid4()).upper()),
            slotIndex=data.get("slotIndex", 0),
            tileType=TileType.from_dict(data.get("tileType", {})),
            customLabel=data.get("customLabel"),
            iconData=data.get("iconData"),
        )


@dataclass
class DeckPage:
    name: str
    pageNumber: int
    id: str = field(default_factory=lambda: str(uuid.uuid4()).upper())
    tiles: List[Optional[DeckTile]] = field(default_factory=lambda: [None] * 20)

    triggerApps: List[str] = field(default_factory=list)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "pageNumber": self.pageNumber,
            "triggerApps": self.triggerApps,
            "tiles": [t.to_dict() if t else None for t in self.tiles],
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "DeckPage":
        raw_tiles = data.get("tiles", [])
        tiles: List[Optional[DeckTile]] = []
        for t in raw_tiles:
            if t is None:
                tiles.append(None)
            elif isinstance(t, dict):
                tiles.append(DeckTile.from_dict(t))
            else:
                tiles.append(None)
        # Ensure length is at least 10
        while len(tiles) < 20:
            tiles.append(None)
        return cls(
            id=data.get("id", str(uuid.uuid4()).upper()),
            name=data.get("name", "Page"),
            pageNumber=data.get("pageNumber", 1),
            tiles=tiles[:20],
            triggerApps=data.get("triggerApps", []),
        )


# Server -> Client Messages
class ServerMessage:
    @staticmethod
    def page_sync(pages: List[DeckPage]) -> str:
        # Phone client reads "page" (legacy) or "pages"
        pages_dict = [p.to_dict() for p in pages]
        for page in pages_dict:
            page.pop("triggerApps", None)
            for tile in page["tiles"]:
                if tile and tile["tileType"]["type"] in ("obsControl", "discordControl"):
                    tile["tileType"] = {"type": "shortcut", "name": tile["customLabel"]}
        return json.dumps({
            "type": "pageSync",
            "page": pages_dict
        })

    @staticmethod
    def switch_to_page(page_id: str) -> str:
        return json.dumps({
            "type": "switchToPage",
            "pageID": page_id
        })

    @staticmethod
    def pong() -> str:
        return json.dumps({"type": "pong"})

    @staticmethod
    def error(message: str) -> str:
        return json.dumps({"type": "error", "message": message})

    @staticmethod
    def pairing_pending() -> str:
        return json.dumps({"type": "pairingPending"})

    @staticmethod
    def pairing_approved() -> str:
        return json.dumps({"type": "pairingApproved"})

    @staticmethod
    def pairing_denied() -> str:
        return json.dumps({"type": "pairingDenied"})

    @staticmethod
    def version_mismatch(required_version: int = 1) -> str:
        return json.dumps({
            "type": "versionMismatch",
            "requiredVersion": required_version
        })

# Client -> Server Commands
@dataclass
class ClientCommand:
    command: str
    pageID: Optional[str] = None
    slotIndex: Optional[int] = None
    clientID: Optional[str] = None
    deviceName: Optional[str] = None
    protocolVersion: int = 1
    gridRows: Optional[int] = None

    @classmethod
    def parse(cls, data_str: str) -> "ClientCommand":
        data = json.loads(data_str)
        return cls(
            command=data.get("command", ""),
            pageID=data.get("pageID"),
            slotIndex=data.get("slotIndex"),
            clientID=data.get("clientID"),
            deviceName=data.get("deviceName"),
            protocolVersion=data.get("protocolVersion", 1),
            gridRows=data.get("gridRows"),
        )
