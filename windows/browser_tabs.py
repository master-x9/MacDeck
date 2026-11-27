"""Read the foreground browser's visible tab strip without changing focus or tabs."""
import base64
import logging
import sys
from io import BytesIO

from PIL import Image, ImageDraw, ImageGrab


def favicon_from_tab(rect, scale=1.0, icon_rect=None):
    """Capture only the favicon-sized region of a visible native browser tab."""
    left, top, right, bottom = rect
    if right-left < 20*scale or bottom-top < 16*scale:
        return None
    size = round(16*scale)
    if icon_rect:
        x, y, r, b = icon_rect
        if r-x > 40*scale or b-y > 40*scale or r <= x or b <= y:
            return None
        box = icon_rect
    else:
        # Chromium/Firefox horizontal tabs: favicon before title; pinned tabs center it.
        x = round((left+right-size)/2) if right-left < 64*scale else round(left+16*scale)
        y = round((top+bottom-size)/2)
        box = (x, y, x+size, y+size)
    image = ImageGrab.grab(bbox=tuple(map(int, box)), all_screens=True).convert('RGBA')
    image = image.resize((72,72), Image.Resampling.LANCZOS)
    canvas = Image.new('RGBA',(128,128))
    ImageDraw.Draw(canvas).rounded_rectangle((4,4,124,124),radius=24,fill='#303030')
    canvas.alpha_composite(image,(28,28))
    out=BytesIO();canvas.save(out,'PNG')
    return base64.b64encode(out.getvalue()).decode('ascii')


def read_browser_tabs():
    """Return the first five visible tabs. No screen images or titles are persisted."""
    if sys.platform != 'win32':
        return []
    import ctypes
    import pythoncom
    import win32gui
    from pywinauto import Desktop
    from action_engine import ActionEngine, BROWSERS
    if ActionEngine.foreground_executable() not in BROWSERS:
        return []
    hwnd=win32gui.GetForegroundWindow()
    pythoncom.CoInitialize()
    try:
        scale=ctypes.windll.user32.GetDpiForWindow(hwnd)/96 or 1
        window=Desktop(backend='uia').window(handle=hwnd).wrapper_object()
        window_top=window.rectangle().top
        strip=None
        # Limit the search to native browser chrome, excluding ARIA tabs inside webpages.
        for candidate in window.descendants(control_type='Tab', depth=5):
            items=candidate.descendants(control_type='TabItem', depth=2)
            if items and items[0].rectangle().top < window_top+130*scale:
                strip=items
                break
        if strip is None:
            return []
        result=[]
        for tab in strip[:5]:
            rect=tab.rectangle()
            title=tab.window_text().strip()
            icon=None
            if tab.is_visible() and win32gui.GetForegroundWindow()==hwnd:
                images=tab.descendants(control_type='Image', depth=2)
                image_rect=images[0].rectangle() if images else None
                icon_rect=(image_rect.left,image_rect.top,image_rect.right,image_rect.bottom) if image_rect else None
                try:
                    icon=favicon_from_tab((rect.left,rect.top,rect.right,rect.bottom),scale,icon_rect)
                except Exception:
                    logging.getLogger('WinDeck.Browser').debug('Tab icon unavailable',exc_info=True)
            result.append(dict(title=title,iconData=icon))
        return result if win32gui.GetForegroundWindow()==hwnd else []
    except Exception:
        logging.getLogger('WinDeck.Browser').debug('Browser tab strip unavailable',exc_info=True)
        return []
    finally:
        pythoncom.CoUninitialize()
