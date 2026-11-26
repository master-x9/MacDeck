"""
WinDeck Network Manager
Advertises WinDeck over mDNS / Bonjour as `_macdeck._tcp` on port 62233,
runs a WebSocket server via `websockets`, handles device pairing handshakes,
and routes mobile TRIGGER_SLOT commands to ActionEngine.
"""

import os
import sys
import uuid
import socket
import asyncio
import logging
from typing import Optional, Dict, Any, Callable
try:
    from .models import (
        ServerMessage, ClientCommand, DeckPage, DeckTile
    )
    from .page_store import (
        PageStore, RUNNING_APPS_PAGE_ID
    )
    from .action_engine import ActionEngine
except ImportError:
    from models import (
        ServerMessage, ClientCommand, DeckPage, DeckTile
    )
    from page_store import (
        PageStore, RUNNING_APPS_PAGE_ID
    )
    from action_engine import ActionEngine

logger = logging.getLogger("WinDeck.Network")

SERVICE_TYPE = "_macdeck._tcp.local."
PORT = 62233
REQUIRED_PROTOCOL_VERSION = 1


def get_computer_name() -> str:
    """Returns a user-friendly computer name."""
    try:
        return socket.gethostname() or "WinDeck PC"
    except Exception:
        return "WinDeck PC"


def get_persistent_host_id(storage_dir: str) -> str:
    """Returns or generates a stable host UUID."""
    id_file = os.path.join(storage_dir, "host_id.txt")
    if os.path.exists(id_file):
        try:
            with open(id_file, "r") as f:
                saved = f.read().strip()
                if saved:
                    return saved
        except Exception:
            pass
    new_id = str(uuid.uuid4()).upper()
    try:
        with open(id_file, "w") as f:
            f.write(new_id)
    except Exception:
        pass
    return new_id


class NetworkManager:
    """Manages mDNS advertising and the mobile companion WebSocket connection."""

    def __init__(self, page_store: PageStore, action_engine: ActionEngine):
        self.page_store = page_store
        self.action_engine = action_engine
        self.host_id = get_persistent_host_id(page_store.storage_dir)
        self.computer_name = get_computer_name()

        # Connection status: "disconnected", "waiting", "awaitingApproval", "connected"
        self.status: str = "disconnected"
        self.connected_device_name: Optional[str] = None
        self.connected_client_id: Optional[str] = None
        self.require_approval_on_return = set()
        self.pending_approval: Optional[Dict[str, str]] = None  # {"clientID": ..., "deviceName": ...}

        self.loop = None
        self.sent_pages = {}
        self.active_ws = None
        self.server = None
        self.zeroconf = None
        self.service_info = None

        self.on_status_changed: Optional[Callable[[str, Optional[str]], None]] = None

        # Subscribe to page store changes to auto-broadcast updates
        self.page_store.subscribe(self.broadcast_page_update)

    def set_status(self, status: str, device_name: Optional[str] = None):
        self.status = status
        self.connected_device_name = device_name
        logger.info(f"Network Status: {status} ({device_name or 'No device'})")
        if self.on_status_changed:
            try:
                self.on_status_changed(status, device_name)
            except Exception as e:
                logger.error(f"Status callback error: {e}")

    # -------------------------------------------------------------------------
    # Bonjour / mDNS Advertising
    # -------------------------------------------------------------------------
    def start_mdns(self):
        """Starts mDNS zero-configuration service advertising."""
        try:
            from zeroconf import Zeroconf, ServiceInfo
        except ImportError:
            logger.warning("zeroconf package not installed. mDNS discovery disabled. Manual IP connection available.")
            return

        try:
            local_ip = self._get_local_ip()
            desc = {
                "name": self.computer_name,
                "hostId": self.host_id,
                "version": str(REQUIRED_PROTOCOL_VERSION),
                "model": "PC",
            }
            service_name = f"{self.computer_name}.{SERVICE_TYPE}"

            self.service_info = ServiceInfo(
                type_=SERVICE_TYPE,
                name=service_name,
                addresses=[socket.inet_aton(local_ip)],
                port=PORT,
                properties=desc,
                server=f"{socket.gethostname()}.local.",
            )

            self.zeroconf = Zeroconf()
            self.zeroconf.register_service(self.service_info)
            logger.info(f"mDNS registered: {service_name} on {local_ip}:{PORT}")
        except Exception as e:
            logger.error(f"Failed to start mDNS service: {e}")

    def stop_mdns(self):
        """Unregisters mDNS service."""
        if self.zeroconf and self.service_info:
            try:
                self.zeroconf.unregister_service(self.service_info)
                self.zeroconf.close()
                self.zeroconf = None
                self.service_info = None
                logger.info("mDNS service unregistered")
            except Exception as e:
                logger.error(f"Error stopping mDNS: {e}")

    def _get_local_ip(self) -> str:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("8.8.8.8", 80))
            ip = s.getsockname()[0]
        except Exception:
            ip = "127.0.0.1"
        finally:
            s.close()
        return ip

    # -------------------------------------------------------------------------
    # WebSocket Server
    # -------------------------------------------------------------------------
    async def start_server(self):
        """Starts the WebSocket server listening on port 62233."""
        try:
            import websockets
        except ImportError:
            logger.error("websockets package not installed. Cannot start WebSocket server.")
            return

        self.set_status("waiting")
        self.loop = asyncio.get_running_loop()

        try:
            self.server = await websockets.serve(
                self._handle_client,
                "0.0.0.0",
                PORT,
                max_size=50 * 1024 * 1024,  # 50MB for full page sync with base64 icons
            )
            await asyncio.to_thread(self.start_mdns)
            logger.info(f"WebSocket server listening on port {PORT}")
        except Exception as e:
            logger.error(f"Failed to bind WebSocket server on port {PORT}: {e}")
            self.set_status("disconnected")

    async def stop(self):
        """Gracefully shuts down WebSocket server and mDNS."""
        await asyncio.to_thread(self.stop_mdns)
        if self.active_ws:
            try:
                await self.active_ws.close()
            except Exception:
                pass
            self.active_ws = None

        if self.server:
            self.server.close()
            await self.server.wait_closed()
            self.server = None

        self.set_status("disconnected")

    # -------------------------------------------------------------------------
    # WebSocket Client Handler
    # -------------------------------------------------------------------------
    async def _handle_client(self, websocket):
        logger.info(f"New client connected from {websocket.remote_address}")

        if self.active_ws is not None:
            await websocket.close(code=1013, reason="Another phone is connected")
            return

        self.pending_approval = None
        self.connected_client_id = None
        self.sent_pages = {}
        self.active_ws = websocket
        self.set_status("awaitingHello")

        try:
            async for message in websocket:
                if isinstance(message, bytes):
                    message = message.decode("utf-8")
                await self._handle_message(message, websocket)
        except Exception as e:
            logger.debug(f"Client connection closed: {e}")
        finally:
            if self.active_ws == websocket:
                self.active_ws = None
                self.pending_approval = None
                self.connected_client_id = None
                self.set_status("waiting")

    async def _handle_message(self, raw_str: str, websocket):
        if websocket is not self.active_ws:
            return
        try:
            cmd = ClientCommand.parse(raw_str)
        except Exception as e:
            logger.warning(f"Failed to parse incoming JSON: {e}")
            return

        logger.debug(f"Received command: {cmd.command}")

        # 1. HELLO Handshake
        if cmd.command == "HELLO":
            await self._handle_hello(cmd, websocket)
            return

        # 2. PING
        if cmd.command == "PING":
            await websocket.send(ServerMessage.pong())
            return

        # Subsequent commands require connected authenticated session
        if self.status != "connected":
            logger.warning(f"Ignoring {cmd.command} because status is {self.status}")
            return

        # 3. REQUEST_SYNC
        if cmd.command == "REQUEST_SYNC":
            await self._send_full_sync(websocket)
            return

        # 4. TRIGGER_SLOT
        if cmd.command == "TRIGGER_SLOT":
            await self._handle_trigger_slot(cmd)

    async def _handle_hello(self, cmd: ClientCommand, websocket):
        if not cmd.clientID or self.status == "connected":
            return
        self.pending_approval = None
        client_id = cmd.clientID
        device_name = cmd.deviceName or "Phone"

        if cmd.protocolVersion != REQUIRED_PROTOCOL_VERSION:
            await websocket.send(ServerMessage.version_mismatch(REQUIRED_PROTOCOL_VERSION))
            await websocket.close()
            return

        self.page_store.grid_rows = cmd.gridRows if cmd.gridRows in (2, 3, 4) else 2
        # Check trust
        if self.page_store.trusted_devices.is_trusted(client_id) and client_id not in self.require_approval_on_return:
            self.connected_client_id = client_id
            self.page_store.trusted_devices.record_connection(client_id)
            await websocket.send(ServerMessage.pairing_approved())
            self.set_status("connected", device_name)
            await self._send_full_sync(websocket)
        else:
            # Awaiting approval from Windows UI
            self.pending_approval = {"clientID": client_id, "deviceName": device_name}
            self.set_status("awaitingApproval", device_name)
            await websocket.send(ServerMessage.pairing_pending())

    async def disconnect_device(self, client_id):
        if self.status != "connected" or not self.active_ws or client_id != self.connected_client_id:
            return
        socket = self.active_ws
        self.require_approval_on_return.add(client_id)
        self.active_ws = None
        self.connected_client_id = None
        self.sent_pages = {}
        self.set_status("waiting")
        await socket.close()

    async def approve_pairing(self, client_id: str):
        """Approved by user from desktop UI."""
        if self.pending_approval and self.pending_approval.get("clientID") == client_id:
            device_name = self.pending_approval.get("deviceName", "Phone")
            self.require_approval_on_return.discard(client_id)
            self.page_store.trusted_devices.trust(client_id, device_name)
            self.connected_client_id = client_id
            self.pending_approval = None
            if self.active_ws:
                await self.active_ws.send(ServerMessage.pairing_approved())
                self.set_status("connected", device_name)
                await self._send_full_sync(self.active_ws)

    async def deny_pairing(self, client_id: str):
        """Denied by user from desktop UI."""
        if self.pending_approval and self.pending_approval.get("clientID") == client_id:
            self.pending_approval = None
            if self.active_ws:
                await self.active_ws.send(ServerMessage.pairing_denied())
                await self.active_ws.close()
            self.set_status("waiting")

    # -------------------------------------------------------------------------
    # Slot Execution & Sync
    # -------------------------------------------------------------------------
    async def _handle_trigger_slot(self, cmd):
        await self.execute_slot(self.sent_pages.get(cmd.pageID), cmd.slotIndex)

    async def execute_slot(self, page, slot):
        if not page or type(slot) is not int or not 0 <= slot < len(page.tiles):
            return
        tile = page.tiles[slot]
        if not tile:
            return
        target = tile.tileType
        try:
            if target.type == "discordControl":
                from integrations import discord_call
                if self.page_store.show_discord:
                    await asyncio.to_thread(discord_call, target.action)
            elif target.type == "obsControl":
                if self.page_store.show_obs:
                    await asyncio.to_thread(self.obs.execute, target)
            elif page.id == RUNNING_APPS_PAGE_ID:
                self.action_engine.focus_window(target.bundleIdentifier)
            else:
                self.action_engine.execute(target)
        except Exception as error:
            logger.warning("Deck action failed: %s", error)
            if self.active_ws and self.status == "connected":
                await self.active_ws.send(ServerMessage.error("Action unavailable. Check the desktop app."))

    async def _send_full_sync(self, websocket):
        """Sends all pages down to the phone client."""
        if websocket is not self.active_ws or self.status != "connected":
            return
        pages = self.page_store.all_pages
        self.sent_pages = {p.id: p for p in pages}
        msg = ServerMessage.page_sync(pages)
        await websocket.send(msg)
        logger.info("Sent full PAGE_SYNC to client")

    def broadcast_page_update(self):
        """Thread-safe / async broadcast of page updates to active client."""
        if self.active_ws and self.status == "connected":
            try:
                loop = self.loop
                if loop and loop.is_running():
                    asyncio.run_coroutine_threadsafe(
                        self._send_full_sync(self.active_ws), loop
                    )
            except Exception as e:
                logger.debug(f"Broadcast update failed: {e}")

    def switch_to_page(self, page_id: str):
        """Commands phone client to switch to a specific page."""
        if self.active_ws and self.status == "connected":
            try:
                loop = self.loop
                if loop and loop.is_running():
                    asyncio.run_coroutine_threadsafe(
                        self.active_ws.send(ServerMessage.switch_to_page(page_id)), loop
                    )
            except Exception as e:
                logger.debug(f"Switch to page failed: {e}")

