"""Keyboard brightness for devices exposed by Windows Dynamic Lighting."""
import asyncio
import sys


class KeyboardBacklight:
    def __init__(self):
        self.lamps = {}
        self.initialized = set()
        self.state = {"supported": False, "message": "Checking keyboard-light support…"}

    async def refresh(self):
        if sys.platform != "win32":
            self.state = {"supported": False, "message": "Keyboard lighting is available only on a supported Windows PC."}
            return
        try:
            from winrt.windows.devices.enumeration import DeviceInformation
            from winrt.windows.devices.lights import LampArray, LampArrayKind

            async def discover():
                devices = await DeviceInformation.find_all_async_aqs_filter(LampArray.get_device_selector())
                lamps = {}
                for device in devices:
                    lamp = self.lamps.get(device.id) or await LampArray.from_id_async(device.id)
                    if lamp and lamp.lamp_array_kind == LampArrayKind.KEYBOARD:
                        lamps[device.id] = lamp
                return lamps

            self.lamps = await asyncio.wait_for(discover(), timeout=8)
            self.initialized.intersection_update(self.lamps)
            available = any(lamp.is_available for lamp in self.lamps.values())
            message = "Keyboard brightness is available through Windows Dynamic Lighting."
            if not self.lamps:
                message = "This laptop doesn’t expose supported keyboard-light controls. Use its Fn key or manufacturer app."
            elif not available:
                message = "Keyboard lighting is unavailable. Check Windows Settings → Personalization → Dynamic Lighting."
            self.state = {"supported": available, "message": message}
        except Exception:
            self.lamps = {}
            self.state = {"supported": False, "message": "Keyboard-light support couldn’t be checked. Check Windows Dynamic Lighting or your manufacturer’s app."}

    def adjust(self, step):
        changed = False
        for identity, lamp in self.lamps.items():
            if not lamp.is_available:
                continue
            if identity not in self.initialized:
                lamp.set_color((255, 255, 255, 255))  # White backlight, applied only on explicit adjustment.
                self.initialized.add(identity)
            lamp.is_enabled = True
            lamp.brightness_level = max(0.0, min(1.0, lamp.brightness_level + step))
            changed = True
        if not changed:
            raise RuntimeError(self.state["message"])
