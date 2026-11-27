import asyncio
import base64
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from integrations import OBS, OBS_ID, CALL_ID, call_buttons, destination, discord_page, tile
from models import DeckPage
from network import NetworkManager
from page_store import PageStore


class IntegrationTests(unittest.TestCase):
    def test_discord_buttons_are_scoped_to_a_call(self):
        def buttons(*labels):
            return [SimpleNamespace(element_info=SimpleNamespace(name=name, control_type="Button"), is_enabled=lambda: True)
                    for name in labels]
        self.assertEqual(set(call_buttons(buttons("Mute", "Accept"))), {"mute"})
        self.assertEqual(set(call_buttons(buttons("Mute", "Turn On Video"))), {"mute", "cameraOn"})
        self.assertEqual(set(call_buttons(buttons("End Call\nCtrl+Shift+E"))), {"disconnect"})
        active = call_buttons(buttons("Disconnect", "Unmute (Ctrl+Shift+M)", "Turn Off Camera"))
        self.assertEqual(set(active), {"disconnect", "unmute", "cameraOff"})
        self.assertEqual(set(call_buttons(buttons("Accept Call", "Decline", "Mute"))), {"answer", "decline", "mute"})

    def test_discord_layout_states_and_sidebar_order(self):
        entries = dict(destination(f"Community {n}", f"guildsnav___{n}", "", True) for n in range(7))
        idle = discord_page({}, entries)
        self.assertEqual(idle.tiles[2].tileType.action, "openDiscord")
        self.assertEqual([t.customLabel for t in idle.tiles[5:10]], [f"Community {n}" for n in range(5)])
        key, info = destination("Casey, 12 unread messages", "", "/channels/@me/123", False)
        entries[key] = info
        self.assertEqual(info, ("Casey", True, True, "12"))
        key, info = destination("Robotics, 3 mentions", "guildsnav___12", "", True)
        entries[key] = info
        self.assertEqual(info, ("Robotics", False, True, "3"))
        before = discord_page(dict.fromkeys(("mute", "deafen", "disconnect", "cameraOn", "share")), entries)
        after = discord_page(dict.fromkeys(("unmute", "undeafen", "disconnect", "cameraOff", "stopShare")), entries)
        self.assertEqual([t.tileType.action for t in before.tiles[:5]], ["mute", "deafen", "disconnect", "cameraOn", "share"])
        self.assertEqual([t.tileType.action for t in after.tiles[:5]], ["unmute", "undeafen", "disconnect", "cameraOff", "stopShare"])
        for slot in (0, 1, 3, 4):
            self.assertNotEqual(before.tiles[slot].iconData, after.tiles[slot].iconData)
        self.assertEqual([t.customLabel for t in after.tiles[5:7]], ["Casey", "Robotics"])
        self.assertIsNone(after.tiles[7])
        self.assertIsNone(destination("not a sidebar link", "", "", False))
        ringing = discord_page({"answer": True}, {})
        self.assertEqual(ringing.tiles[2].tileType.action, "answer")
        self.assertNotEqual(ringing.tiles[2].iconData, idle.tiles[2].iconData)

    def test_sidebar_without_identifiers_or_unread_activity(self):
        dm = destination("Casey", "", "", False, in_dms=True)
        server = destination("Workshop", "", "", True)
        self.assertEqual(discord_page({}, dict([dm])).tiles[5].customLabel, "Casey")
        self.assertEqual(discord_page({}, dict([dm, server])).tiles[5].customLabel, "Workshop")
        unread = destination("Casey, 2 unread messages", "", "", False, in_dms=True)
        self.assertEqual(discord_page({}, dict([server, unread])).tiles[5].customLabel, "Casey")

    def test_sidebar_home_links_and_conversation_art(self):
        for label, path in [("Friends", "/channels/@me"), ("Friends", ""), ("Nitro DISCOUNT", ""),
                            ("Shop", "/shop"), ("Quests", ""), ("Promotion", "/store")]:
            self.assertIsNone(destination(label, "", path, False, True))
        entries = dict([destination("Casey", "", "", False, True),
                        destination("Casey", "", "/channels/@me/123", False, True),
                        destination("Shop", "", "/channels/@me/456", False, True)])
        page = discord_page({}, entries)
        self.assertEqual([t.customLabel for t in page.tiles[5:7]], ["Casey", "Shop"])
        self.assertNotEqual(page.tiles[5].iconData, page.tiles[6].iconData)
        self.assertIsNone(page.tiles[7])

    def test_discord_photo_crop_and_tile(self):
        from io import BytesIO
        from unittest.mock import patch
        from PIL import Image
        from integrations import crop_avatar
        frame = Image.new("RGB", (180, 80), "black")
        frame.paste("red", (8, 8, 40, 40))
        frame.putpixel((24, 24), (30, 60, 90))
        art = crop_avatar(frame, (8, 8, 40, 40))
        self.assertEqual(Image.open(BytesIO(art)).getpixel((16, 16)), (30, 60, 90))
        self.assertIsNone(crop_avatar(frame, (0, -1, 32, 31)))
        self.assertIsNone(crop_avatar(frame, (100, 8, 132, 40)))
        key, entry = destination("Casey (direct message)", "", "/channels/@me/123", False)
        row = SimpleNamespace(descendants=lambda **_: [])
        with patch("integrations.visible_dm_avatar", return_value=art):
            photo_tile = discord_page({}, {key: entry}, links={key: row}).tiles[5]
        self.assertEqual(photo_tile.customLabel, "Casey")
        photo = Image.open(BytesIO(base64.b64decode(photo_tile.iconData)))
        self.assertEqual(photo.getpixel((32, 16)), (255, 0, 0))

    def test_paired_android_controls_obs(self):
        from websockets import serve, connect

        async def scenario(directory):
            commands = []
            recording = False
            async def obs_server(socket):
                nonlocal recording
                await socket.send(json.dumps({"op": 0, "d": {"authentication": {"salt": "salt", "challenge": "challenge"}}}))
                identify = json.loads(await socket.recv())
                def digest(value):
                    return base64.b64encode(hashlib.sha256(value.encode()).digest()).decode()
                self.assertEqual(identify["d"]["authentication"], digest(digest("test" + "salt") + "challenge"))
                await socket.send(json.dumps({"op": 2, "d": {"negotiatedRpcVersion": 1}}))
                async for raw in socket:
                    request = json.loads(raw)["d"]
                    name = request["requestType"]
                    commands.append((name, request["requestData"]))
                    if name in ("StartRecord", "StopRecord"):
                        recording = name == "StartRecord"
                    data = {"GetRecordStatus": {"outputActive": recording}, "GetStreamStatus": {"outputActive": False},
                            "GetSceneList": {"scenes": [{"sceneName": "Desk"}], "currentProgramSceneName": "Desk"},
                            "GetSpecialInputs": {"mic1": "Mic"}}.get(name, {})
                    await socket.send(json.dumps({"op": 7, "d": {"requestId": request["requestId"],
                        "requestStatus": {"result": True}, "responseData": data}}))

            async with serve(obs_server, "127.0.0.1", 0) as server:
                obs = OBS(server.sockets[0].getsockname()[1], "test")
                try:
                    store = PageStore(storage_dir=directory)
                    store.update_live_page(OBS_ID, await asyncio.to_thread(obs.page))
                    call = DeckPage(id=CALL_ID, name="Discord Call", pageNumber=-4)
                    call.tiles[4] = tile(CALL_ID, 4, "discordControl", "disconnect", "Disconnect")
                    store.update_live_page(CALL_ID, call)
                    net = NetworkManager(store, None)
                    net.loop, net.obs = asyncio.get_running_loop(), obs
                    async with serve(net._handle_client, "127.0.0.1", 0) as host:
                        async with connect(f"ws://127.0.0.1:{host.sockets[0].getsockname()[1]}") as phone:
                            await phone.send(json.dumps({"command": "HELLO", "clientID": "test-phone", "deviceName": "Android", "gridRows": 4}))
                            self.assertEqual(json.loads(await phone.recv())["type"], "pairingPending")
                            await net.approve_pairing("test-phone")
                            self.assertEqual(json.loads(await phone.recv())["type"], "pairingApproved")
                            pages = json.loads(await phone.recv())["page"]
                            self.assertEqual(store.grid_rows, 4)
                            for page in pages:
                                for t in filter(None, page["tiles"]):
                                    self.assertIn(t["tileType"]["type"], {"shortcut", "browserControl", "systemControl", "app", "website"})
                            slots = next(p["tiles"] for p in pages if p["id"] == OBS_ID)
                            self.assertEqual(slots[0]["tileType"]["name"], "Start Recording")
                            self.assertEqual(slots[4]["customLabel"], "✓ Desk")
                            async def trigger(slot):
                                await phone.send(json.dumps({"command": "TRIGGER_SLOT", "pageID": OBS_ID, "slotIndex": slot}))
                                await phone.send('{"command":"PING"}')
                                self.assertEqual(json.loads(await phone.recv())["type"], "pong")
                            await trigger(0)
                            await trigger(4)
                            self.assertTrue(recording)
                            self.assertIn(("SetCurrentProgramScene", {"sceneName": "Desk"}), commands)
                            store.update_live_page(OBS_ID, await asyncio.to_thread(obs.page))
                            updated = json.loads(await phone.recv())["page"]
                            self.assertEqual(next(p for p in updated if p["id"] == OBS_ID)["tiles"][0]["customLabel"], "Stop Recording")
                            await trigger(0)
                            self.assertFalse(recording)
                finally:
                    await asyncio.to_thread(obs.close)

        with tempfile.TemporaryDirectory() as directory:
            asyncio.run(asyncio.wait_for(scenario(directory), timeout=12))
