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
from integrations import OBS, OBS_ID, CALL_ID, call_buttons, tile
from models import DeckPage
from network import NetworkManager
from page_store import PageStore


class IntegrationTests(unittest.TestCase):
    def test_discord_buttons_are_scoped_to_a_call(self):
        def buttons(*labels):
            return [SimpleNamespace(element_info=SimpleNamespace(name=name, control_type="Button"), is_enabled=lambda: True)
                    for name in labels]
        self.assertEqual(call_buttons(buttons("Mute", "Accept")), {})
        self.assertEqual(set(call_buttons(buttons("Mute", "Turn On Video"))), {"mute", "cameraOn"})
        self.assertEqual(set(call_buttons(buttons("End Call\nCtrl+Shift+E"))), {"disconnect"})
        active = call_buttons(buttons("Disconnect", "Unmute (Ctrl+Shift+M)", "Turn Off Camera"))
        self.assertEqual(set(active), {"disconnect", "unmute", "cameraOff"})
        self.assertEqual(set(call_buttons(buttons("Accept Call", "Decline", "Mute"))), {"answer", "decline"})

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
