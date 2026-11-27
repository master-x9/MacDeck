"""Live desktop integration pages. Android sends back only the page ID and slot."""
import asyncio
import base64
import hashlib
import json
import logging
import re
from functools import lru_cache
from io import BytesIO

from PIL import Image
from discord_icons import icon
import sys
import threading
import uuid

from icons import get_icon
from models import DeckPage, DeckTile, TileType

@lru_cache(maxsize=1)
def uia_errors():
    errors = (AttributeError, OSError, RuntimeError, NotImplementedError)
    if sys.platform == "win32":
        from comtypes import COMError
        from pywinauto.uia_defines import NoPatternInterfaceError
        return errors + (COMError, NoPatternInterfaceError)
    return errors


OBS_ID = "00000000-0000-0000-0000-000000000005"
CALL_ID = "00000000-0000-0000-0000-000000000006"
CALL_LABELS = {
    "mute": ("Mute", "Mute Microphone", "Mute Audio", "Mute Yourself"),
    "unmute": ("Unmute", "Unmute Microphone", "Unmute Audio", "Unmute Yourself"),
    "deafen": ("Deafen", "Deafen Audio", "Deafen Yourself"),
    "undeafen": ("Undeafen", "Undeafen Audio", "Undeafen Yourself"),
    "cameraOn": ("Turn On Camera", "Turn Camera On", "Start Video", "Enable Camera", "Turn On Video"),
    "cameraOff": ("Turn Off Camera", "Turn Camera Off", "Stop Video", "Disable Camera", "Turn Off Video"),
    "share": ("Share Screen", "Share Your Screen", "Screen Share", "Start Screen Share"),
    "stopShare": ("Stop Sharing", "Stop Streaming", "Stop Sharing Your Screen", "Stop Screen Share"),
    "disconnect": ("Disconnect", "Leave Call", "Disconnect from Voice", "Disconnect Call", "End Call", "Hang Up", "Leave Voice Channel"),
    "answer": ("Answer", "Accept", "Accept Call", "Answer Call", "Accept Incoming Call", "Join Call", "Join Voice Call", "Accept Voice Call", "Accept Video Call"),
    "decline": ("Decline", "Decline Call"),
    "openDiscord": ("Discord",),
    "toggleMute": ("Toggle Mute",),
    "toggleDeafen": ("Toggle Deafen",),
}
CALL_NAMES = {name.casefold(): key for key, names in CALL_LABELS.items() if key not in ("openDiscord", "toggleMute", "toggleDeafen") for name in names}
SLOTS = [("unmute", "mute", "toggleMute"), ("undeafen", "deafen", "toggleDeafen"), ("answer", "disconnect", "openDiscord"),
         ("cameraOff", "cameraOn"), ("stopShare", "share")]
COUNT = re.compile(r"\b([0-9]+\+?)\s+(?:unread\s+)?(?:mentions?|messages?|notifications?)\b", re.I)


def tile(page_id, slot, kind, action, label, name=None):
    return DeckTile(slotIndex=slot, tileType=TileType(type=kind, action=action, name=name),
                    customLabel=label, iconData=get_icon(kind),
                    id=str(uuid.uuid5(uuid.UUID(page_id), str(slot))).upper())


def call_buttons(buttons):
    found = {}
    for button in buttons:
        name = (button.element_info.name or "").partition("\n")[0].partition(" (")[0].strip().casefold()
        key = CALL_NAMES.get(name)
        if not key or not button.is_enabled():
            continue
        try:
            checked = button.get_toggle_state() == 1
        except uia_errors():
            checked = False
        if checked:
            key = {"mute": "unmute", "deafen": "undeafen", "cameraOn": "cameraOff", "share": "stopShare"}.get(key, key)
        found[key] = button
    if "answer" in found and "decline" in found:
        return {k: v for k, v in found.items() if k != "disconnect"}
    found.pop("answer", None)
    found.pop("decline", None)
    if "disconnect" in found or (found.keys() & {"mute", "unmute"} and found.keys() & {"cameraOn", "cameraOff"}):
        return found
    return {k: v for k, v in found.items() if k in ("mute", "unmute", "deafen", "undeafen")}


def destination(name, identifier, value, in_servers, in_dms=False):
    from urllib.parse import urlsplit
    path = urlsplit(value).path if value else ""
    dm_route = re.fullmatch(r"/channels/@me/[0-9]+/?", path)
    server_route = re.fullmatch(r"/channels/[0-9]+/?", path)
    row_id = re.search(r"(?:private-channels-.*___|guildsnav___(?:dm-)?)[0-9]+$", identifier)
    if path and not (dm_route or server_route):
        return None
    if not (dm_route or server_route or row_id) and re.match(r"^\s*(friends|nitro|shop|quests|message requests|family cent(?:er|re)|discover|find or start a conversation|start a conversation|create dm|new message)(?:$|[\s,:!•–-])", name or "", re.I):
        return None
    direct = (in_dms or "/channels/@me/" in value or "private-channels-" in identifier or identifier.startswith("guildsnav___dm-"))
    if not (direct or in_servers or re.search(r"/channels/[0-9]+/?$", value) or re.fullmatch(r"guildsnav___[0-9]+", identifier)):
        return None
    if not name or "folder" in identifier or re.search(r"\b(folder|direct messages|add a server|discover servers|download apps)\b", name, re.I):
        return None
    match = COUNT.search(name)
    count = match[1] if match else None
    unread = count != "0" if count else direct and "unread" in name.casefold()
    label = re.sub(r"(?:^|,\s*)(?:unread|server|guild)(?:,|$)", "", COUNT.sub("", name), flags=re.I).strip(" ,•:-\n")
    if direct:
        label = re.sub(r"\s*\(direct messages?\)$", "", label, flags=re.I).strip()
    if label:
        return ("dm:" if direct else "server:") + (path or (identifier if row_id else label.casefold())), (label, direct, unread, count)


def discord_page(found, entries, avatar=None, links=None):
    active = found.keys() & {"disconnect", "cameraOn", "cameraOff", "share", "stopShare"}
    page = DeckPage(id=CALL_ID, name="Incoming Discord Call" if "answer" in found else "Discord Call" if active else "Discord", pageNumber=-4)
    for slot, options in enumerate(SLOTS):
        key = next((k for k in options if k in found or k == "openDiscord"), None)
        if key:
            t = tile(CALL_ID, slot, "discordControl", key, CALL_LABELS[key][0])
            t.iconData = icon(key, avatar=avatar if key == "answer" else None)
            page.tiles[slot] = t
    identified = {("dm:" if direct else "server:") + label.casefold() for key, (label, direct, _, _) in entries.items()
                  if key != ("dm:" if direct else "server:") + label.casefold()}
    entries = {key: value for key, value in entries.items() if key not in identified}
    unread = [item for item in entries.items() if item[1][2]]
    selected = unread or [item for item in entries.items() if not item[1][1]] or list(entries.items())
    frames = {}
    for slot, (key, (label, direct, unread, count)) in enumerate(selected[:5], 5):
        t = tile(CALL_ID, slot, "discordControl", "nav:" + key, label)
        art = None
        if links and key in links:
            images = links[key].descendants(control_type="Image")
            for child in images:
                url = legacy_value(child)
                if re.fullmatch(r"https://(?:cdn\.discordapp\.com|media\.discordapp\.net)/(?:avatars|embed/avatars|icons|channel-icons)/[\w./-]+(?:\?[^\s]*)?", url):
                    art = avatar_bytes(url)
                    break
            if art is None and direct:
                art = visible_dm_avatar(links[key], images, frames)
        t.iconData = icon("dm" if direct else "server", (count or "•") if unread else None, avatar=art, name=label)
        page.tiles[slot] = t
    return page


def legacy_value(control):
    from pywinauto.uia_defines import get_elem_interface
    try:
        return str(get_elem_interface(control.element_info.element, "LegacyIAccessible").CurrentValue or "")
    except uia_errors():
        return ""


@lru_cache(maxsize=8)
def avatar_bytes(url):
    # Fetch only Discord's small rendered avatar, never arbitrary links from a chat.
    from urllib.request import urlopen
    try:
        with urlopen(url.split("?")[0] + "?size=128", timeout=2) as response:
            raw = response.read(256 * 1024)
        with Image.open(BytesIO(raw)) as image:
            if image.width <= 512 and image.height <= 512:
                image.load()
                return raw
    except (OSError, ValueError):
        pass


def visible_dm_avatar(row, images, frames):
    from ctypes import windll
    import win32gui
    from PIL import ImageGrab

    try:
        hwnd = row.top_level_parent().handle
        if not hwnd or win32gui.IsIconic(hwnd) or row.element_info.element.CurrentIsOffscreen:
            return None
        scale = (windll.user32.GetDpiForWindow(hwnd) or 96) / 96
        r = row.rectangle()
        if not (28 * scale <= r.height() <= 80 * scale and r.width() >= r.height() * 2):
            return None
        side = min(round(40 * scale), round(r.height() * .76))
        x, y = r.left + round(8 * scale), r.top + (r.height() - side) // 2
        box = (x, y, x + side, y + side)
        for child in images:
            b = child.rectangle()
            if (14 * scale <= b.width() <= 80 * scale and abs(b.width() - b.height()) < 3 * scale
                    and r.left <= b.left < b.right <= r.left + r.width() // 2
                    and r.top <= b.top < b.bottom <= r.bottom):
                box = (b.left, b.top, b.right, b.bottom)
                break
        if hwnd not in frames:
            frames[hwnd] = ImageGrab.grab(window=hwnd)
        frame = frames[hwnd]
        left, top, right, bottom = win32gui.GetWindowRect(hwnd)
        if frame.size != (right - left, bottom - top):
            if frame.size != win32gui.GetClientRect(hwnd)[2:]:
                return None
            left, top = win32gui.ClientToScreen(hwnd, (0, 0))
        return crop_avatar(frame, (box[0]-left, box[1]-top, box[2]-left, box[3]-top))
    except uia_errors() + (TypeError,):
        return None


def crop_avatar(frame, box):
    if not (0 <= box[0] < box[2] <= frame.width and 0 <= box[1] < box[3] <= frame.height):
        return None
    crop = frame.crop(box).convert("RGB")
    if all(low == high for low, high in crop.getextrema()):
        return None
    buffer = BytesIO()
    crop.thumbnail((128, 128))
    crop.save(buffer, format="PNG")
    return buffer.getvalue()


def caller_avatar(answer, decline):
    parent = answer
    for _ in range(10):
        parent = parent.parent()
        if parent is None or parent.element_info.control_type in ("Document", "Window"):
            break
        # A caller panel is small. Stop before reaching the rest of the Discord window.
        children = parent.descendants()
        if len(children) > 80:
            break
        if not any(c == decline for c in children):
            continue
        images = [c for c in children if c.element_info.control_type == "Image"]
        urls = {legacy_value(c) for c in images}
        avatars = [u for u in urls if re.fullmatch(r"https://(?:cdn\.discordapp\.com|media\.discordapp\.net)/(?:embed/)?avatars/[\w./-]+(?:\?[^\s]*)?", u)]
        if len(avatars) == 1:
            return avatar_bytes(avatars[0])
        if avatars:
            break
        if len(images) == 1:
            # PrintWindow renders just Discord, including when another app covers it.
            import win32gui
            from PIL import ImageGrab
            root = answer.top_level_parent()
            bounds = images[0].rectangle()
            if root.handle and 12 <= bounds.width() <= 512 and 12 <= bounds.height() <= 512:
                try:
                    frame = ImageGrab.grab(window=root.handle)
                    left, top = win32gui.GetWindowRect(root.handle)[:2]
                    box = (bounds.left-left, bounds.top-top, bounds.right-left, bounds.bottom-top)
                    if 0 <= box[0] < box[2] <= frame.width and 0 <= box[1] < box[3] <= frame.height:
                        crop = frame.crop(box)
                        if any(low != high for low, high in crop.convert("RGB").getextrema()):
                            buffer = BytesIO()
                            crop.thumbnail((128, 128))
                            crop.save(buffer, format="PNG")
                            return buffer.getvalue()
                except (OSError, TypeError):
                    pass
            break
    return None


def discord_call(press=None):
    if sys.platform != "win32":
        return None
    import os
    import pythoncom
    import win32gui
    import win32process
    import psutil
    if press == "openDiscord":
        os.startfile("discord://discord.com/channels/@me")
        return None
    pythoncom.CoInitialize()
    try:
        from pywinauto import Desktop
        from pywinauto.uia_defines import get_elem_interface
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
        if press in ("toggleMute", "toggleDeafen"):
            if windows:
                window = Desktop(backend="uia").window(handle=windows[0])
                window.set_focus()
                if win32gui.GetForegroundWindow() == windows[0]:
                    window.type_keys("^+m" if press == "toggleMute" else "^+d", set_foreground=False)
            return None
        controls, links, entries = [], {}, {}
        for hwnd in windows:
            window = Desktop(backend="uia").window(handle=hwnd).wrapper_object()
            nodes = window.descendants()
            server_ids, dm_ids = set(), set()
            item_roles = ("TreeItem", "ListItem", "Hyperlink", "Button", "RadioButton", "TabItem", "DataItem")
            for n in nodes:
                if n.element_info.control_type not in ("Tree", "Group", "List", "Pane", "Custom", "Tab", "ToolBar", "Table"):
                    continue
                label = (n.element_info.name or "").strip().casefold()
                if label in ("servers", "servers list", "servers sidebar", "server list", "guilds"):
                    target = server_ids
                elif label in ("direct messages", "private channels", "direct messages list"):
                    target = dm_ids
                else:
                    continue
                target.update(tuple(c.element_info.runtime_id) for c in n.descendants()
                              if c.element_info.control_type in item_roles and c.element_info.runtime_id)
            for n in nodes:
                info = n.element_info
                if info.control_type in ("Button", "CheckBox"):
                    controls.append(n)
                if info.control_type not in item_roles:
                    continue
                value = legacy_value(n) if info.control_type == "Hyperlink" else ""
                rid = tuple(info.runtime_id or ())
                item = destination(info.name, info.automation_id or "", value, rid in server_ids, rid in dm_ids and info.control_type != "Button")
                if item:
                    key, entry = item
                    entries.setdefault(key, entry)
                    links.setdefault(key, n)
        found = call_buttons(controls)
        if press is not None:
            control = links.get(press[4:]) if press.startswith("nav:") else found.get(press)
            if control is not None:
                if control.element_info.control_type == "CheckBox":
                    control.toggle()
                else:
                    try:
                        control.iface_invoke.Invoke()
                    except uia_errors():
                        get_elem_interface(control.element_info.element, "LegacyIAccessible").DoDefaultAction()
            return None
        if windows:
            if not found.keys() & {"mute", "unmute"}:
                found["toggleMute"] = True
            if not found.keys() & {"deafen", "undeafen"}:
                found["toggleDeafen"] = True
        return discord_page(found, entries, caller_avatar(found["answer"], found["decline"]) if "answer" in found else None, links=links)
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
