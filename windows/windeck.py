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
import subprocess
import webbrowser
from http.server import SimpleHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

if __name__ == "__main__" and sys.platform == "win32" and getattr(sys, "frozen", False):
    import velopack
    velopack.App().run()

# Support PyInstaller standalone bundle path
if getattr(sys, "frozen", False):
    current_dir = getattr(sys, "_MEIPASS", os.path.dirname(sys.executable))
else:
    current_dir = os.path.dirname(os.path.abspath(__file__))

if current_dir not in sys.path:
    sys.path.insert(0, current_dir)

from models import DeckTile, TileType, SystemControlAction
from icons import get_icon, fetch_favicon, ICONS
from action_engine import ActionEngine, BROWSERS
from page_store import PageStore, supported, BROWSER_PAGE_ID
from integrations import OBS, OBS_ID, CALL_ID, discord_call, monitor
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
        if self.headers.get("Host") not in (f"localhost:{HTTP_PORT}", f"127.0.0.1:{HTTP_PORT}"):
            self.send_error(403)
            return
        parsed = urlparse(self.path)
        if parsed.path == "/api/state":
            self._send_json(self.server.get_state())
        else:
            super().do_GET()

    def do_POST(self):
        # Pairing decisions and credentials come only from the local dashboard.
        host = self.headers.get("Host", "")
        if host not in (f"localhost:{HTTP_PORT}", f"127.0.0.1:{HTTP_PORT}") or self.headers.get("Origin", f"http://{host}") != f"http://{host}" or self.headers.get_content_type() != "application/json":
            self.send_error(403)
            return
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
        self.send_header("Cache-Control", "no-store")
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

        installed_apps = ctx.installed_apps
        for app in installed_apps:
            app["iconData"] = get_icon("app")
            app["type"] = "app"

        return {
            "pages": [dict(p.to_dict(), readOnly=p.pageNumber <= 0) for p in ctx.page_store.all_pages],
            "gridRows": ctx.page_store.grid_rows,
            "showOBS": ctx.page_store.show_obs,
            "showDiscord": ctx.page_store.show_discord,
            "obsPort": ctx.page_store.obs_port,
            "obsStatus": ctx.obs.status,
            "trustedDevices": ctx.page_store.trusted_devices.devices,
            "launchAtLogin": ctx.launch_at_login,
            "selectedPageId": ctx.page_store.selected_page_id,
            "status": ctx.network.status,
            "connectedClientID": ctx.network.connected_client_id,
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
            if not any(p.id == body.get("pageId") for p in ps.all_pages):
                return {"success": False, "error": "Page unavailable"}
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
            if not supported(tt) or tt.type not in ("app", "shortcut", "website", "systemControl", "browserControl"):
                return {"success": False, "error": "Unavailable on Windows"}
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

        elif path == "/api/trigger_live_slot":
            page = next((p for p in ps.all_pages if p.id == body.get("pageId") and p.pageNumber <= 0), None)
            if page:
                asyncio.run_coroutine_threadsafe(ctx.network.execute_slot(page, body.get("slotIndex")), ctx.loop)

        elif path == "/api/page_triggers":
            page = next((p for p in ps.pages if p.id == body.get("pageId")), None)
            if page:
                page.triggerApps = [name.strip().casefold() for name in body.get("apps", "").split(",") if name.strip()]
                ps.notify_changes()

        elif path == "/api/disconnect_device":
            asyncio.run_coroutine_threadsafe(ctx.network.disconnect_device(body.get("clientId")), ctx.loop)

        elif path == "/api/forget_device":
            client_id = body.get("clientId")
            async def forget():
                ps.trusted_devices.forget(client_id)
                if ctx.network.connected_client_id == client_id and ctx.network.active_ws:
                    await ctx.network.active_ws.close()
            asyncio.run_coroutine_threadsafe(forget(), ctx.loop).result(timeout=8)

        elif path == "/api/launch_at_login":
            try:
                ctx.launch_at_login = launch_setting(bool(body.get("enabled")))
            except OSError:
                return {"success": False, "error": "Windows could not update the startup setting."}

        elif path == "/api/obs_settings":
            port = body.get("port")
            if type(port) is not int or not 1 <= port <= 65535:
                return {"success": False, "error": "Enter a port between 1 and 65535."}
            password = body.get("password", "")
            if password or body.get("clearPassword"):
                try:
                    write_obs_password(password)
                except Exception:
                    return {"success": False, "error": "Could not save the OBS password in Windows Credential Manager."}
            else:
                password = ctx.obs.password
            ctx.obs.configure(port, password)
            ps.obs_port = port
            ps.notify_changes()

        elif path == "/api/set_toggles":
            if "showOBS" in body:
                ps.show_obs = bool(body["showOBS"])
            if "showDiscord" in body:
                ps.show_discord = bool(body["showDiscord"])
            if "showRunningApps" in body:
                ps.show_running_apps_page = body["showRunningApps"]
            if "showBrowserControl" in body:
                ps.show_browser_control_page = body["showBrowserControl"]
            if not any(p.id == ps.selected_page_id for p in ps.all_pages):
                ps.selected_page_id = ps.pages[0].id
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
def launch_setting(enabled=None):
    if sys.platform != "win32":
        return False
    import winreg
    path = r"Software\Microsoft\Windows\CurrentVersion\Run"
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, path) as key:
        if enabled:
            if getattr(sys, "frozen", False):
                args = [sys.executable]
            elif sys.argv[0].lower().endswith(".exe"):
                args = [os.path.abspath(sys.argv[0])]
            else:
                args = [os.path.join(os.path.dirname(sys.executable), "pythonw.exe"), os.path.abspath(__file__)]
            winreg.SetValueEx(key, "WinDeck", 0, winreg.REG_SZ, subprocess.list2cmdline(args + ["--tray-only"]))
        elif enabled is False:
            try:
                winreg.DeleteValue(key, "WinDeck")
            except FileNotFoundError:
                pass
        try:
            return bool(winreg.QueryValueEx(key, "WinDeck")[0])
        except FileNotFoundError:
            return False


def read_obs_password():
    if sys.platform != "win32":
        return ""
    import win32cred
    import pywintypes
    try:
        credential = win32cred.CredRead("WinDeck/OBS", win32cred.CRED_TYPE_GENERIC)
        return credential["CredentialBlob"].decode("utf-16-le")
    except pywintypes.error as exc:
        if exc.winerror != 1168:
            logger.warning("OBS credential unavailable")
        return ""


def write_obs_password(password):
    import win32cred
    win32cred.CredWrite({"Type": win32cred.CRED_TYPE_GENERIC, "TargetName": "WinDeck/OBS",
                         "CredentialBlob": password.encode("utf-16-le"),
                         "Persist": win32cred.CRED_PERSIST_LOCAL_MACHINE}, 0)


class WinDeckApp:
    def __init__(self, storage_dir=None):
        self.action_engine = ActionEngine()
        self.page_store = PageStore(action_engine=self.action_engine, storage_dir=storage_dir)
        self.network = NetworkManager(page_store=self.page_store, action_engine=self.action_engine)
        self.launch_at_login = launch_setting()
        self.installed_apps = self.action_engine.discover_installed_apps()
        self.obs = OBS(self.page_store.obs_port, read_obs_password())
        self.network.obs = self.obs
        self.loop = asyncio.new_event_loop()
        self.quit = threading.Event()
        self.window = None
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
                self.quit.set()
                if self.window:
                    self.window.destroy()

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

    async def serve(self):
        await self.network.start_server()
        store = self.page_store
        tasks = [asyncio.create_task(monitor(store, OBS_ID, self.obs.page, lambda: store.show_obs)),
                 asyncio.create_task(monitor(store, CALL_ID, discord_call, lambda: store.show_discord)),
                 asyncio.create_task(self.refresh_windows())]
        try:
            while not self.quit.is_set():
                await asyncio.sleep(0.25)
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            await self.network.stop()
            await asyncio.to_thread(self.obs.configure, self.obs.port, self.obs.password)

    async def refresh_windows(self):
        previous_target = None
        had_call = False
        while True:
            self.page_store.refresh_running_apps()
            foreground = self.action_engine.foreground_executable()
            self.page_store.set_browser_active(foreground in BROWSERS)
            target = None
            discord = self.page_store.live_pages.get(CALL_ID) if self.page_store.show_discord else None
            has_call = discord is not None and discord.name != "Discord"
            if discord and (foreground == "discord.exe" or (has_call and not had_call)):
                target = CALL_ID
            elif foreground in ("obs64.exe", "obs32.exe") and OBS_ID in self.page_store.live_pages:
                target = OBS_ID
            elif self.page_store.show_browser_control_page and foreground in BROWSERS:
                target = BROWSER_PAGE_ID
            if foreground and target is None:
                target = next((p.id for p in self.page_store.pages if foreground in p.triggerApps), None)
            if target and target != previous_target and self.network.status == "connected":
                self.page_store.selected_page_id = target
                self.network.switch_to_page(target)
            had_call = has_call and self.network.status == "connected"
            previous_target = target if self.network.status == "connected" else None
            await asyncio.sleep(2)

    def run(self, headless=False):
        self.start_http_server()
        if self.http_server is None:
            return
        thread = threading.Thread(target=self.loop.run_until_complete, args=(self.serve(),))
        thread.start()
        self.start_system_tray()
        if sys.platform == "win32" and getattr(sys, "frozen", False):
            from app_updates import monitor_updates
            threading.Thread(target=monitor_updates, args=(self.quit,), daemon=True).start()
        try:
            if not headless:
                url = f"http://localhost:{HTTP_PORT}"
                try:
                    import webview
                    self.window = webview.create_window("WinDeck", url, width=1000, height=760,
                                                        min_size=(860, 620), background_color="#151517")
                    webview.start()  # WebView2 requires the main thread.
                    self.window = None
                    if not self.tray_icon:
                        return
                except Exception:
                    webbrowser.open(url)
            self.quit.wait()
        except KeyboardInterrupt:
            pass
        finally:
            self.quit.set()
            thread.join()
            self.loop.close()
            self.http_server.shutdown()
            self.http_server.server_close()
            if self.tray_icon:
                self.tray_icon.stop()


if __name__ == "__main__":
    headless_mode = "--headless" in sys.argv or "--tray-only" in sys.argv
    app = WinDeckApp()
    app.run(headless=headless_mode)
