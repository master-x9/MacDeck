"""
WinDeck Main Application Entry Point
Starts the WebSocket server (port 62233), mDNS advertiser (_macdeck._tcp),
local UI HTTP server (port 62234), system tray icon, and desktop WebView2 window.
"""

import os
import sys
import json
import socket
import asyncio
import logging
import threading
import webbrowser
from http.server import SimpleHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

# Support PyInstaller standalone bundle path
if getattr(sys, "frozen", False):
    current_dir = getattr(sys, "_MEIPASS", os.path.dirname(sys.executable))
else:
    current_dir = os.path.dirname(os.path.abspath(__file__))

if current_dir not in sys.path:
    sys.path.insert(0, current_dir)

from models import DeckTile, TileType, SystemControlAction
from icons import get_icon, fetch_favicon, ICONS
from action_engine import ActionEngine
from page_store import PageStore
from network import NetworkManager, PORT as WS_PORT

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)
logger = logging.getLogger("WinDeck")

UI_DIR = os.path.join(current_dir, "ui")
HTTP_PORT = 62234


# -----------------------------------------------------------------------------
# Local Web & API Server
# -----------------------------------------------------------------------------
class WinDeckApiHandler(SimpleHTTPRequestHandler):
    """Serves static UI files and handles JSON API calls from app.js."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=UI_DIR, **kwargs)

    def log_message(self, format, *args):
        # Silence routine static asset GET logs
        pass

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/state":
            self._send_json(self.server.get_state())
        else:
            super().do_GET()

    def do_POST(self):
        parsed = urlparse(self.path)
        content_length = int(self.headers.get("Content-Length", 0))
        body_bytes = self.rfile.read(content_length)
        body = json.loads(body_bytes.decode("utf-8")) if body_bytes else {}

        response = self.server.handle_api(parsed.path, body)
        self._send_json(response)

    def _send_json(self, data):
        payload = json.dumps(data).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(payload)


class WinDeckHttpServer(HTTPServer):
    def __init__(self, server_address, app_context):
        super().__init__(server_address, WinDeckApiHandler)
        self.ctx = app_context

    def get_state(self):
        ctx = self.ctx
        controls = []
        for act in SystemControlAction:
            controls.append({
                "name": act.display_name,
                "action": act.value,
                "badge": act.badge,
                "type": "systemControl",
                "iconData": get_icon(act.value),
            })

        installed_apps = ctx.action_engine.discover_installed_apps()
        for app in installed_apps:
            app["iconData"] = get_icon("app")
            app["type"] = "app"

        return {
            "pages": [p.to_dict() for p in ctx.page_store.pages],
            "selectedPageId": ctx.page_store.selected_page_id,
            "status": ctx.network.status,
            "connectedDeviceName": ctx.network.connected_device_name,
            "pendingApproval": ctx.network.pending_approval,
            "computerName": ctx.network.computer_name,
            "showRunningApps": ctx.page_store.show_running_apps_page,
            "showBrowserControl": ctx.page_store.show_browser_control_page,
            "controlsLibrary": controls,
            "installedApps": installed_apps[:40],
        }

    def handle_api(self, path: str, body: dict) -> dict:
        ctx = self.ctx
        ps = ctx.page_store

        if path == "/api/select_page":
            ps.selected_page_id = body.get("pageId")
            ps.notify_changes()
            if ctx.network.status == "connected" and ps.selected_page_id:
                ctx.network.switch_to_page(ps.selected_page_id)

        elif path == "/api/add_page":
            name = body.get("name", "New Page")
            ps.add_page(name)

        elif path == "/api/delete_page":
            page_id = body.get("pageId")
            ps.delete_page(page_id)

        elif path == "/api/rename_page":
            page_id = body.get("pageId")
            name = body.get("name")
            ps.rename_page(page_id, name)

        elif path == "/api/set_tile":
            page_id = body.get("pageId")
            slot_index = body.get("slotIndex")
            tile_type_data = body.get("tileType", {})
            custom_label = body.get("customLabel")

            tt = TileType.from_dict(tile_type_data)
            icon = get_icon(tt.action or tt.type)

            # Check if website favicon needs fetching
            if tt.type == "website" and tt.url:
                fav = fetch_favicon(tt.url)
                if fav:
                    icon = fav

            tile = DeckTile(
                slotIndex=slot_index,
                tileType=tt,
                customLabel=custom_label,
                iconData=icon,
            )
            ps.set_tile(page_id, slot_index, tile)

        elif path == "/api/clear_tile":
            page_id = body.get("pageId")
            slot_index = body.get("slotIndex")
            ps.clear_tile(page_id, slot_index)

        elif path == "/api/swap_tiles":
            page_id = body.get("pageId")
            slot_a = body.get("slotA")
            slot_b = body.get("slotB")
            ps.swap_tiles(page_id, slot_a, slot_b)

        elif path == "/api/set_toggles":
            if "showRunningApps" in body:
                ps.show_running_apps_page = body["showRunningApps"]
            if "showBrowserControl" in body:
                ps.show_browser_control_page = body["showBrowserControl"]
            ps.notify_changes()

        elif path == "/api/approve_pairing":
            client_id = body.get("clientId")
            asyncio.run_coroutine_threadsafe(
                ctx.network.approve_pairing(client_id), ctx.loop
            )

        elif path == "/api/deny_pairing":
            client_id = body.get("clientId")
            asyncio.run_coroutine_threadsafe(
                ctx.network.deny_pairing(client_id), ctx.loop
            )

        return {"success": True, "state": self.get_state()}


# -----------------------------------------------------------------------------
# WinDeck Application Context
# -----------------------------------------------------------------------------
class WinDeckApp:
    def __init__(self):
        self.action_engine = ActionEngine()
        self.page_store = PageStore(action_engine=self.action_engine)
        self.network = NetworkManager(page_store=self.page_store, action_engine=self.action_engine)
        self.loop = None
        self.http_server = None
        self.tray_icon = None

    def start_http_server(self):
        try:
            self.http_server = WinDeckHttpServer(("127.0.0.1", HTTP_PORT), self)
            t = threading.Thread(target=self.http_server.serve_forever, daemon=True)
            t.start()
            logger.info(f"UI dashboard running at http://localhost:{HTTP_PORT}")
        except Exception as e:
            logger.error(f"Failed to start HTTP server on port {HTTP_PORT}: {e}")

    def start_system_tray(self):
        """Creates a background system tray icon with menu."""
        try:
            import pystray
            from PIL import Image, ImageDraw

            # Generate tray icon (blue squircle with grid)
            icon_img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
            d = ImageDraw.Draw(icon_img)
            d.rounded_rectangle([4, 4, 60, 60], radius=14, fill=(10, 132, 255, 255))
            d.rounded_rectangle([14, 14, 28, 28], radius=3, fill=(255, 255, 255, 240))
            d.rounded_rectangle([36, 14, 50, 28], radius=3, fill=(255, 255, 255, 240))
            d.rounded_rectangle([14, 36, 28, 50], radius=3, fill=(255, 255, 255, 240))
            d.rounded_rectangle([36, 36, 50, 50], radius=3, fill=(255, 255, 255, 240))

            def open_ui(icon, item):
                webbrowser.open(f"http://localhost:{HTTP_PORT}")

            def on_exit(icon, item):
                icon.stop()
                sys.exit(0)

            menu = pystray.Menu(
                pystray.MenuItem("Open WinDeck", open_ui, default=True),
                pystray.MenuItem(f"PC: {self.network.computer_name}", None, enabled=False),
                pystray.Menu.SEPARATOR,
                pystray.MenuItem("Exit", on_exit)
            )

            self.tray_icon = pystray.Icon("WinDeck", icon_img, "WinDeck Host", menu)
            t = threading.Thread(target=self.tray_icon.run, daemon=True)
            t.start()
            logger.info("System tray icon initialized")
        except Exception as e:
            logger.debug(f"System tray icon not available: {e}")

    def run(self, headless: bool = False):
        self.start_http_server()
        self.start_system_tray()

        # Start WebSocket & mDNS in asyncio
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)

        # Start network manager
        self.loop.run_until_complete(self.network.start_server())

        # Start desktop window or open browser
        if not headless:
            self._launch_window()
        else:
            logger.info("Running in headless / tray-only mode.")

        # Keep event loop running
        try:
            self.loop.run_forever()
        except (KeyboardInterrupt, SystemExit):
            logger.info("Shutting down WinDeck...")
            self.loop.run_until_complete(self.network.stop())

    def _launch_window(self):
        ui_url = f"http://localhost:{HTTP_PORT}"
        try:
            import webview

            def start_gui():
                window = webview.create_window(
                    "WinDeck — PC Controller Host",
                    ui_url,
                    width=960,
                    height=660,
                    min_size=(860, 600),
                    background_color="#060608",
                )
                webview.start()

            t = threading.Thread(target=start_gui, daemon=True)
            t.start()
            logger.info("Desktop WebView2 window created")
        except ImportError:
            logger.info("pywebview not installed. Opening dashboard in default web browser.")
            webbrowser.open(ui_url)


if __name__ == "__main__":
    headless_mode = "--headless" in sys.argv or "--tray-only" in sys.argv
    app = WinDeckApp()
    app.run(headless=headless_mode)
