"""Live desktop integration pages. Android sends back only the page ID and slot."""
import asyncio
import base64
import hashlib
import json
import logging
import sys
import threading
import uuid

from icons import get_icon
from models import DeckPage, DeckTile, TileType

OBS_ID = "00000000-0000-0000-0000-000000000005"
CALL_ID = "00000000-0000-0000-0000-000000000006"
CALL_LABELS = {
    "mute": ("Mute", "Mute Microphone"),
    "unmute": ("Unmute", "Unmute Microphone"),
    "cameraOn": ("Camera On", "Turn On Camera", "Turn Camera On", "Start Video", "Enable Camera", "Turn On Video"),
    "cameraOff": ("Camera Off", "Turn Off Camera", "Turn Camera Off", "Stop Video", "Disable Camera", "Turn Off Video"),
    "disconnect": ("Disconnect", "Leave Call", "Disconnect from Voice", "Disconnect Call", "End Call", "Hang Up", "Leave Voice Channel"),
    "answer": ("Answer", "Accept", "Accept Call", "Answer Call", "Join Call"),
    "decline": ("Decline", "Decline Call"),
}
CALL_NAMES = {name.casefold(): key for key, names in CALL_LABELS.items() for name in names}


def tile(page_id, slot, kind, action, label, name=None):
    # Stable IDs keep polling from rebuilding an unchanged phone page.
    return DeckTile(slotIndex=slot, tileType=TileType(type=kind, action=action, name=name),
                    customLabel=label, iconData=get_icon(kind),
                    id=str(uuid.uuid5(uuid.UUID(page_id), str(slot))).upper())


def call_buttons(buttons):
    found = {}
    for button in buttons:
        name = (button.element_info.name or "").partition("\n")[0].partition(" (")[0].strip().casefold()
        key = CALL_NAMES.get(name)
        if key and button.is_enabled():
            if key == "mute" and button.element_info.control_type == "CheckBox" and button.get_toggle_state() == 1:
                key = "unmute"
            found[key] = button
    if "disconnect" in found or (found.keys() & {"mute", "unmute"} and found.keys() & {"cameraOn", "cameraOff"}):
        return {k: v for k, v in found.items() if k not in ("answer", "decline")}
    if "answer" in found and "decline" in found:
        return {k: found[k] for k in ("answer", "decline")}
    return {}


def discord_call(press=None):
    if sys.platform != "win32":
        return None
    import pythoncom
    import win32gui
    import win32process
    import psutil
    pythoncom.CoInitialize()
    try:
        from pywinauto import Desktop
        windows = []
        def collect(hwnd, _):
            if win32gui.IsWindowVisible(hwnd) and win32gui.GetClassName(hwnd) == "Chrome_WidgetWin_1":
                pid = win32process.GetWindowThreadProcessId(hwnd)[1]
                try:
                    if psutil.Process(pid).name().casefold() == "discord.exe":
                        windows.append(hwnd)
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    pass
        win32gui.EnumWindows(collect, None)
        for hwnd in windows:
            window = Desktop(backend="uia").window(handle=hwnd).wrapper_object()
            controls = window.descendants(control_type="Button") + window.descendants(control_type="CheckBox")
            found = call_buttons(controls)
            if not found:
                continue
            if press is not None:
                if press in found:
                    control = found[press]
                    if control.element_info.control_type == "CheckBox":
                        control.toggle()
                    else:
                        control.invoke()
                return None
            name = "Incoming Discord Call" if "answer" in found else "Discord Call"
            page = DeckPage(id=CALL_ID, name=name, pageNumber=-4)
            for index, key in enumerate(CALL_LABELS):
                if key in found:
                    page.tiles[index] = tile(CALL_ID, index, "discordControl", key, CALL_LABELS[key][0])
            return page
        return None
    finally:
        pythoncom.CoUninitialize()


class OBS:
    """Request-only OBS v5 connection. Serialize poll, action and reconnect on the same socket."""
    def __init__(self, port=4455, password=""):
        self.port = port
        self.password = password
        self.socket = None
        self.connection = None
        self.status = "Waiting for OBS"
        self.lock = threading.Lock()

    def configure(self, port, password):
        with self.lock:
            self.close()
            self.port, self.password = port, password

    def close(self):
        if self.socket is not None:
            self.connection.__exit__(None, None, None)
            self.socket = None
            self.connection = None

    def receive(self, opcode):
        message = json.loads(self.socket.recv(timeout=3))
        if message["op"] != opcode:
            raise ValueError("Unexpected OBS response")
        return message["d"]

    def connect(self):
        from websockets.sync.client import connect
        self.connection = connect(f"ws://127.0.0.1:{self.port}", open_timeout=3, close_timeout=1)
        self.socket = self.connection.__enter__()
        hello = self.receive(0)
        identify = {"rpcVersion": 1, "eventSubscriptions": 0}
        if auth := hello.get("authentication"):
            def digest(text):
                return base64.b64encode(hashlib.sha256(text.encode()).digest()).decode()
            identify["authentication"] = digest(digest(self.password + auth["salt"]) + auth["challenge"])
        self.socket.send(json.dumps({"op": 1, "d": identify}))
        self.receive(2)

    def request(self, method, **params):
        request_id = str(uuid.uuid4())
        self.socket.send(json.dumps({"op": 6, "d": {
            "requestType": method, "requestId": request_id, "requestData": params
        }}))
        response = self.receive(7)
        if response["requestId"] != request_id or not response["requestStatus"]["result"]:
            raise ValueError(response["requestStatus"].get("comment", "OBS rejected the request"))
        return response.get("responseData", {})

    def page(self):
        with self.lock:
            try:
                if self.socket is None:
                    self.connect()
                scenes = self.request("GetSceneList")
                page = DeckPage(id=OBS_ID, name="OBS", pageNumber=-2)
                for slot, (group, label) in enumerate([("Record", "Recording"), ("Stream", "Streaming")]):
                    active = self.request("Get" + group + "Status")["outputActive"]
                    verb = "Stop" if active else "Start"
                    page.tiles[slot] = tile(OBS_ID, slot, "obsControl", verb + group, verb + " " + label)
                page.tiles[2] = tile(OBS_ID, 2, "obsControl", "ToggleReplayBuffer", "Replay Buffer")
                mic = self.request("GetSpecialInputs").get("mic1")
                if mic:
                    page.tiles[3] = tile(OBS_ID, 3, "obsControl", "ToggleInputMute", "Mic", mic)
                ordered = [scene["sceneName"] for scene in reversed(scenes["scenes"])]
                current = scenes["currentProgramSceneName"]
                first_scene = 4
                if len(ordered) > 6 and current in ordered:
                    index = ordered.index(current)
                    for offset, label in [(-1, "Previous Scene"), (1, "Next Scene")]:
                        name = ordered[(index + offset) % len(ordered)]
                        page.tiles[first_scene] = tile(OBS_ID, first_scene, "obsControl", "SetCurrentProgramScene", label, name)
                        first_scene += 1
                for i, name in enumerate(ordered, first_scene):
                    if i == len(page.tiles):
                        break
                    label = ("✓ " if name == scenes["currentProgramSceneName"] else "") + name
                    page.tiles[i] = tile(OBS_ID, i, "obsControl", "SetCurrentProgramScene", label, name)
                self.status = "Connected to OBS"
                return page
            except Exception as exc:
                self.close()
                self.status = "Waiting for OBS" if isinstance(exc, OSError) else "Check OBS WebSocket settings and password"
                return None

    def execute(self, target):
        with self.lock:
            if self.socket is None:
                return
            if target.action == "SetCurrentProgramScene":
                self.request(target.action, sceneName=target.name)
            elif target.action == "ToggleInputMute":
                self.request(target.action, inputName=target.name)
            elif target.action in ("StartRecord", "StopRecord", "StartStream", "StopStream", "ToggleReplayBuffer"):
                self.request(target.action)


async def monitor(store, page_id, fetch, enabled):
    while True:
        try:
            page = await asyncio.to_thread(fetch) if enabled() else None
        except Exception:
            logging.getLogger("WinDeck").debug("Integration unavailable", exc_info=True)
            page = None
        store.update_live_page(page_id, page if enabled() else None)
        await asyncio.sleep(2)
