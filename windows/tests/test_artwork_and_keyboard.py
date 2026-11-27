import asyncio
import base64
import sys
import tempfile
import unittest
from io import BytesIO
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app_icons import get_app_icon, shell_icon
from icons import fetch_favicon, get_icon, _favicon_cache
from integrations import OBS_ID, tile
from keyboard_backlight import KeyboardBacklight
from windeck import WinDeckApp, WinDeckHttpServer


class ArtworkAndKeyboardTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "win32", "Requires the Windows Shell")
    def test_native_shell_icon_extraction(self):
        import os
        image = shell_icon(str(Path(os.environ["WINDIR"]) / "System32/notepad.exe"))
        self.assertIsNotNone(image)
        self.assertEqual(image.size, (64, 64))
        self.assertIsNotNone(image.getbbox())

    @unittest.skipUnless(sys.platform == "win32", "Requires Windows lighting APIs")
    def test_native_keyboard_capability_query(self):
        backlight = KeyboardBacklight()
        asyncio.run(backlight.refresh())
        self.assertNotIn("couldn’t be checked", backlight.state["message"])

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = WinDeckApp(storage_dir=self.temp.name)
        self.addCleanup(self.app.loop.close)
        self.server = WinDeckHttpServer.__new__(WinDeckHttpServer)
        self.server.ctx = self.app

    def test_app_artwork_survives_state_poll_and_assignment(self):
        actual = get_app_icon("", "Example")
        self.app.installed_apps = [dict(name="Example", path="example.exe", iconData=actual)]
        for _ in range(2):
            self.assertEqual(self.server.get_state()["installedApps"][0]["iconData"], actual)
        with patch("windeck.get_app_icon", return_value=actual):
            self.server.handle_api("/api/set_tile", dict(pageId=self.app.page_store.pages[0].id,
                slotIndex=0, tileType=dict(type="app", name="Example", bundleIdentifier="example.exe")))
        self.assertEqual(self.app.page_store.pages[0].tiles[0].iconData, actual)
        self.assertNotEqual(actual, get_icon("app"))

    def test_website_ico_becomes_png_and_domain_is_cached(self):
        _favicon_cache.clear()
        data = BytesIO()
        Image.new("RGBA", (32, 32), "red").save(data, "ICO")
        with patch("urllib.request.urlopen", return_value=BytesIO(data.getvalue())) as request:
            icon = fetch_favicon("example.com/path")
            self.assertTrue(base64.b64decode(icon).startswith(b"\x89PNG\r\n\x1a\n"))
            self.assertEqual(fetch_favicon("https://example.com/other"), icon)
            self.assertEqual(request.call_count, 1)
        self.assertIsNone(fetch_favicon("file:///etc/passwd"))

    def test_favicon_fallback_after_invalid_response(self):
        _favicon_cache.clear()
        data = BytesIO()
        Image.new("RGB", (32, 32), "blue").save(data, "PNG")
        with patch("urllib.request.urlopen", side_effect=[BytesIO(b"<html>error</html>"), BytesIO(data.getvalue())]):
            self.assertIsNotNone(fetch_favicon("https://example.org"))

    def test_obs_actions_have_different_artwork(self):
        icons = [tile(OBS_ID, index, "obsControl", action, action).iconData for index, action in
                 enumerate(["StartStream", "StartRecord", "ToggleReplayBuffer", "ToggleInputMute", "SetCurrentProgramScene"])]
        self.assertEqual(len(set(icons)), 5)
        self.assertNotIn(get_icon("app"), icons)

    def test_keyboard_actions_are_capability_gated(self):
        self.assertNotIn("kbBrightnessUp", [control["action"] for control in self.server.get_state()["controlsLibrary"]])
        body = dict(pageId=self.app.page_store.pages[0].id, slotIndex=0,
                    tileType=dict(type="systemControl", action="kbBrightnessUp"))
        self.assertFalse(self.server.handle_api("/api/set_tile", body)["success"])
        self.app.action_engine.keyboard_backlight.state = dict(supported=True, message="Available")
        self.assertIn("kbBrightnessUp", [control["action"] for control in self.server.get_state()["controlsLibrary"]])
        self.assertTrue(self.server.handle_api("/api/set_tile", body)["success"])

    def test_keyboard_brightness_bounds_and_unavailable_device(self):
        backlight = KeyboardBacklight()
        colors = []
        lamp = SimpleNamespace(is_available=True, brightness_level=.95, is_enabled=False, set_color=colors.append)
        backlight.lamps = {"keyboard":lamp}
        backlight.adjust(.1)
        self.assertEqual(lamp.brightness_level, 1)
        backlight.adjust(-2)
        self.assertEqual(lamp.brightness_level, 0)
        self.assertEqual(colors, [(255,255,255,255)])
        lamp.is_available = False
        with self.assertRaises(RuntimeError):
            backlight.adjust(.1)

    def test_non_windows_does_not_claim_keyboard_support(self):
        with patch("keyboard_backlight.sys.platform", "darwin"):
            backlight = KeyboardBacklight()
            asyncio.run(backlight.refresh())
            self.assertFalse(backlight.state["supported"])


if __name__ == "__main__":
    unittest.main()
