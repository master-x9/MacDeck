"""
Automated Unit Tests for WinDeck
Verifies models, icons, action engine, page store, and network protocol.
"""

import os
import sys
import json
import base64
import unittest
import asyncio

current_dir = os.path.dirname(os.path.abspath(__file__))
parent_dir = os.path.dirname(current_dir)
if parent_dir not in sys.path:
    sys.path.insert(0, parent_dir)

from models import (
    DeckPage, DeckTile, TileType, ServerMessage, ClientCommand,
    SystemControlAction, BrowserControlAction
)
from icons import get_icon, ICONS
from action_engine import ActionEngine
from page_store import PageStore, LockedPageProvider, BrowserPageProvider, LOCKED_PAGE_ID, RUNNING_APPS_PAGE_ID
from network import NetworkManager


class TestWinDeck(unittest.TestCase):

    def test_models_serialization(self):
        tile_type = TileType(type="systemControl", action="volumeUp")
        tile = DeckTile(slotIndex=0, tileType=tile_type, customLabel="Vol+")
        page = DeckPage(name="Test Page", pageNumber=1, tiles=[tile] + [None] * 9)

        d = page.to_dict()
        self.assertEqual(d["name"], "Test Page")
        self.assertEqual(len(d["tiles"]), 10)
        self.assertIsNotNone(d["tiles"][0])
        self.assertIsNone(d["tiles"][1])

        # Test from_dict
        restored = DeckPage.from_dict(d)
        self.assertEqual(restored.name, "Test Page")
        self.assertEqual(restored.tiles[0].label, "Vol+")
        self.assertEqual(restored.tiles[0].tileType.action, "volumeUp")

    def test_client_command_parsing(self):
        raw = json.dumps({
            "command": "TRIGGER_SLOT",
            "pageID": LOCKED_PAGE_ID,
            "slotIndex": 4
        })
        cmd = ClientCommand.parse(raw)
        self.assertEqual(cmd.command, "TRIGGER_SLOT")
        self.assertEqual(cmd.pageID, LOCKED_PAGE_ID)
        self.assertEqual(cmd.slotIndex, 4)

        hello_raw = json.dumps({
            "command": "HELLO",
            "clientID": "test-client-123",
            "deviceName": "Pixel 8 Pro",
            "protocolVersion": 1
        })
        hello_cmd = ClientCommand.parse(hello_raw)
        self.assertEqual(hello_cmd.command, "HELLO")
        self.assertEqual(hello_cmd.clientID, "test-client-123")
        self.assertEqual(hello_cmd.deviceName, "Pixel 8 Pro")

    def test_server_messages(self):
        page = DeckPage(name="Main", pageNumber=1)
        sync_msg = ServerMessage.page_sync([page])
        parsed = json.loads(sync_msg)
        self.assertEqual(parsed["type"], "pageSync")
        self.assertIn("page", parsed)

        pong_msg = ServerMessage.pong()
        self.assertEqual(json.loads(pong_msg)["type"], "pong")

        lock_msg = ServerMessage.lock_state_changed(True)
        self.assertEqual(json.loads(lock_msg)["isLocked"], True)

    def test_icons_validity(self):
        self.assertGreater(len(ICONS), 15)
        # Verify icons decode to valid PNG headers (bytes 1..4 = PNG)
        for name in ["volumeUp", "playPause", "lockScreen", "keepAwake", "screenshot"]:
            icon_b64 = get_icon(name)
            self.assertIsNotNone(icon_b64, f"Icon for {name} should exist")
            raw_bytes = base64.b64decode(icon_b64)
            self.assertTrue(raw_bytes.startswith(b"\x89PNG\r\n\x1a\n"), f"Icon {name} is not valid PNG")

    def test_action_engine(self):
        engine = ActionEngine()
        # Test safe execution on any platform
        engine.execute(TileType(type="systemControl", action="volumeUp"))
        engine.execute(TileType(type="browserControl", action="newTab"))
        engine.execute(TileType(type="shortcut", name="CTRL+SHIFT+ESC"))
        
        # Test keep awake toggle
        state1 = engine.toggle_keep_awake()
        self.assertTrue(state1)
        state2 = engine.toggle_keep_awake()
        self.assertFalse(state2)

    def test_page_store_operations(self):
        import tempfile
        temp_dir = tempfile.mkdtemp()
        store = PageStore(storage_dir=temp_dir)
        initial_count = len(store.pages)

        # Add page
        new_page = store.add_page("Gaming Deck")
        self.assertEqual(len(store.pages), initial_count + 1)
        self.assertEqual(store.selected_page_id, new_page.id)

        # Set tile
        store.set_tile(new_page.id, 0, DeckTile(
            slotIndex=0,
            tileType=TileType(type="systemControl", action="mute"),
            customLabel="Silent"
        ))
        self.assertEqual(new_page.tiles[0].label, "Silent")

        # Swap tiles
        store.swap_tiles(new_page.id, 0, 1)
        self.assertIsNone(new_page.tiles[0])
        self.assertEqual(new_page.tiles[1].label, "Silent")

        # Clear tile
        store.clear_tile(new_page.id, 1)
        self.assertIsNone(new_page.tiles[1])

        # Delete page
        store.delete_page(new_page.id)
        self.assertEqual(len(store.pages), initial_count)

    def test_locked_page_provider(self):
        locked_page = LockedPageProvider.get_locked_page()
        self.assertEqual(locked_page.id, LOCKED_PAGE_ID)
        self.assertEqual(len(locked_page.tiles), 10)
        # Slot 4 should be volumeUp
        self.assertEqual(locked_page.tiles[4].tileType.action, "volumeUp")
        # Slot 7 should be playPause
        self.assertEqual(locked_page.tiles[7].tileType.action, "playPause")

    def test_network_handshake_and_trigger(self):
        executed_actions = []

        class TestActionEngine(ActionEngine):
            def execute(self, tile_type):
                executed_actions.append(tile_type)

        class MockWebSocket:
            def __init__(self):
                self.messages = []
                self.closed = False
                self.remote_address = ("192.168.1.50", 61000)

            async def send(self, msg):
                self.messages.append(json.loads(msg) if isinstance(msg, str) else msg)

            async def close(self):
                self.closed = True

        async def run_async_test():
            import tempfile
            temp_dir = tempfile.mkdtemp()
            engine = TestActionEngine()
            store = PageStore(action_engine=engine, storage_dir=temp_dir)
            net = NetworkManager(page_store=store, action_engine=engine)
            ws = MockWebSocket()
            net.active_ws = ws

            # 1. Unknown client sends HELLO -> pairingPending
            hello_msg = json.dumps({
                "command": "HELLO",
                "clientID": "device-new-999",
                "deviceName": "Pixel 8",
                "protocolVersion": 1
            })
            await net._handle_message(hello_msg, ws)
            self.assertEqual(net.status, "awaitingApproval")
            self.assertEqual(ws.messages[-1]["type"], "pairingPending")

            # 2. Approve pairing from desktop UI
            await net.approve_pairing("device-new-999")
            self.assertEqual(net.status, "connected")
            # Should have sent pairingApproved then pageSync
            types = [m["type"] for m in ws.messages]
            self.assertIn("pairingApproved", types)
            self.assertIn("pageSync", types)

            # 3. Client sends TRIGGER_SLOT for slot 0 (Volume Up in default main page)
            active_page_id = store.pages[0].id
            trigger_msg = json.dumps({
                "command": "TRIGGER_SLOT",
                "pageID": active_page_id,
                "slotIndex": 0
            })
            await net._handle_message(trigger_msg, ws)
            self.assertEqual(len(executed_actions), 1)
            self.assertEqual(executed_actions[0].action, "volumeUp")

            # 4. Client sends PING -> PONG
            await net._handle_message(json.dumps({"command": "PING"}), ws)
            self.assertEqual(ws.messages[-1]["type"], "pong")

            # 5. Lock state notification
            net.notify_lock_state(True)

        asyncio.run(run_async_test())

    def test_windeck_http_api(self):
        import tempfile
        from windeck import WinDeckApp, WinDeckHttpServer

        temp_dir = tempfile.mkdtemp()
        app = WinDeckApp()
        app.page_store = PageStore(action_engine=app.action_engine, storage_dir=temp_dir)
        app.network = NetworkManager(page_store=app.page_store, action_engine=app.action_engine)

        # Create mock server instance with app context (without binding port)
        server = WinDeckHttpServer.__new__(WinDeckHttpServer)
        server.ctx = app

        # Test initial state
        state = server.get_state()
        self.assertIn("pages", state)
        self.assertIn("controlsLibrary", state)
        self.assertIn("status", state)
        self.assertGreater(len(state["controlsLibrary"]), 15)

        # Test API add_page
        res = server.handle_api("/api/add_page", {"name": "Streaming"})
        self.assertTrue(res["success"])
        page_id = res["state"]["pages"][-1]["id"]
        self.assertEqual(res["state"]["pages"][-1]["name"], "Streaming")

        # Test API set_tile
        res = server.handle_api("/api/set_tile", {
            "pageId": page_id,
            "slotIndex": 2,
            "tileType": {"type": "systemControl", "action": "screenshot"}
        })
        self.assertTrue(res["success"])
        tile = res["state"]["pages"][-1]["tiles"][2]
        self.assertIsNotNone(tile)
        self.assertEqual(tile["tileType"]["action"], "screenshot")

        # Test API rename_page
        res = server.handle_api("/api/rename_page", {"pageId": page_id, "name": "OBS Studio"})
        self.assertEqual(res["state"]["pages"][-1]["name"], "OBS Studio")

        # Test API clear_tile
        res = server.handle_api("/api/clear_tile", {"pageId": page_id, "slotIndex": 2})
        self.assertIsNone(res["state"]["pages"][-1]["tiles"][2])

        # Test API set_toggles
        res = server.handle_api("/api/set_toggles", {"showRunningApps": False, "showBrowserControl": False})
        self.assertFalse(res["state"]["showRunningApps"])
        self.assertFalse(res["state"]["showBrowserControl"])


if __name__ == "__main__":
    unittest.main()
