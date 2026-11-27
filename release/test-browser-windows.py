"""CI smoke test against real Edge tabs and their rendered favicons."""
import os
import sys
import subprocess
import tempfile
import threading
import time
import base64
from io import BytesIO
from pathlib import Path
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from functools import partial
from PIL import Image
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'windows'))
from browser_tabs import read_browser_tabs
import win32gui
import psutil

edge=next((Path(root)/'Microsoft/Edge/Application/msedge.exe' for root in [os.environ.get('PROGRAMFILES(X86)',''),os.environ.get('PROGRAMFILES','')] if (Path(root)/'Microsoft/Edge/Application/msedge.exe').exists()),None)
assert edge, 'Edge is required for the browser capture smoke test'
with tempfile.TemporaryDirectory(prefix='windeck-browser-smoke-',ignore_cleanup_errors=True) as temp:
    root=Path(temp); profile=root/'profile'; pages=root/'pages';pages.mkdir()
    for name,color in [('Red','red'),('Green','lime')]:
        Image.new('RGB',(32,32),color).save(pages/(name+'.png'))
        (pages/(name+'.html')).write_text(f'<html><head><title>WinDeck {name} Fixture</title><link rel="icon" href="/{name}.png"></head><body>Browser favicon fixture</body></html>')
    with ThreadingHTTPServer(('127.0.0.1',0),partial(SimpleHTTPRequestHandler,directory=str(pages))) as server:
        threading.Thread(target=server.serve_forever,daemon=True).start()
        base=f'http://127.0.0.1:{server.server_port}'
        process=subprocess.Popen([str(edge),'--no-first-run','--no-default-browser-check','--disable-features=msEdgeFirstRunExperience','--force-renderer-accessibility',f'--user-data-dir={profile}',base+'/Red.html',base+'/Green.html'])
        try:
            tabs=[]
            for _ in range(30):
                time.sleep(1)
                windows=[]
                win32gui.EnumWindows(lambda hwnd,_: windows.append(hwnd) if 'WinDeck' in win32gui.GetWindowText(hwnd) and 'Fixture' in win32gui.GetWindowText(hwnd) else None,None)
                if windows:
                    try: win32gui.SetForegroundWindow(windows[0])
                    except Exception: pass
                tabs=read_browser_tabs()
                if all(any(f'WinDeck {name} Fixture' in tab['title'] for tab in tabs) for name in ['Red','Green']): break
            print('Captured tab titles:',[tab['title'] for tab in tabs],flush=True)
            for name,channel in [('Red',0),('Green',1)]:
                tab=next(tab for tab in tabs if f'WinDeck {name} Fixture' in tab['title'])
                assert tab['iconData'],f'{name} favicon missing'
                image=Image.open(BytesIO(base64.b64decode(tab['iconData'])))
                image.save(root/(name+'-captured.png'))
                pixels=list(image.crop((38,38,90,90)).convert('RGB').getdata())
                assert sum(pixel[channel]>180 and pixel[1-channel]<100 for pixel in pixels)>len(pixels)*.5, f'{name} favicon crop did not contain the website icon'
            print('Native Edge tab titles and both website favicons verified.',flush=True)
        finally:
            for item in psutil.process_iter(['name','cmdline']):
                try:
                    if item.info['name'].lower()=='msedge.exe' and any(str(profile) in part for part in item.info['cmdline'] or []):
                        children=item.children(recursive=True)
                        for child in children:
                            try: child.kill()
                            except psutil.Error: pass
                        item.kill()
                except psutil.Error: pass
            server.shutdown()
