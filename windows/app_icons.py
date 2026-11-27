"""Read real Windows Shell icons, including Start menu shortcuts."""
import base64
import logging
import sys
from functools import lru_cache
from io import BytesIO

from PIL import Image, ImageDraw, ImageFont


@lru_cache(maxsize=256)
def get_app_icon(path, name="App"):
    image = None
    if sys.platform == "win32" and path:
        try:
            image = shell_icon(path)
        except Exception:
            logging.getLogger("WinDeck.Icons").debug("Shell icon unavailable for %s", path, exc_info=True)
    if image is None:
        image = Image.new("RGBA", (64, 64))
        draw = ImageDraw.Draw(image)
        draw.rounded_rectangle((2, 2, 62, 62), radius=14, fill="#38383b")
        initials = "".join(word[0] for word in name.split()[:2]).upper() or "?"
        draw.text((32, 32), initials, font=ImageFont.load_default(size=24), anchor="mm", fill="white")
    output = BytesIO()
    image.save(output, format="PNG")
    return base64.b64encode(output.getvalue()).decode("ascii")


def shell_icon(path):
    import ctypes
    from ctypes import wintypes
    import win32gui
    import win32ui

    class SHFILEINFO(ctypes.Structure):
        _fields_ = [("hIcon", wintypes.HICON), ("iIcon", ctypes.c_int),
                    ("dwAttributes", wintypes.DWORD), ("szDisplayName", wintypes.WCHAR * 260),
                    ("szTypeName", wintypes.WCHAR * 80)]

    get_info = ctypes.windll.shell32.SHGetFileInfoW
    get_info.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, ctypes.POINTER(SHFILEINFO), ctypes.c_uint, ctypes.c_uint]
    get_info.restype = ctypes.c_size_t
    info = SHFILEINFO()
    if not get_info(str(path), 0, ctypes.byref(info), ctypes.sizeof(info), 0x100):  # SHGFI_ICON
        return None
    screen = win32gui.GetDC(0)
    dc = win32ui.CreateDCFromHandle(screen)
    memory = dc.CreateCompatibleDC()
    bitmap = win32ui.CreateBitmap()
    bitmap.CreateCompatibleBitmap(dc, 64, 64)
    previous = memory.SelectObject(bitmap)
    try:
        backgrounds = []
        for color in (0x000000, 0xFFFFFF):
            memory.FillSolidRect((0, 0, 64, 64), color)
            win32gui.DrawIconEx(memory.GetSafeHdc(), 0, 0, info.hIcon, 64, 64, 0, None, 3)
            backgrounds.append(Image.frombuffer("RGB", (64, 64), bitmap.GetBitmapBits(True), "raw", "BGRX", 0, 1))
        # Recover transparency for both legacy masked icons and modern alpha icons.
        pixels = []
        for black, white in zip(backgrounds[0].getdata(), backgrounds[1].getdata()):
            alpha = 255 - max(w - b for w, b in zip(white, black))
            pixels.append(tuple(min(255, round(c * 255 / alpha)) for c in black) + (alpha,) if alpha else (0, 0, 0, 0))
        image = Image.new("RGBA", (64, 64))
        image.putdata(pixels)
        return image
    finally:
        memory.SelectObject(previous)
        win32gui.DeleteObject(bitmap.GetHandle())
        memory.DeleteDC()
        win32gui.ReleaseDC(0, screen)
        win32gui.DestroyIcon(info.hIcon)
