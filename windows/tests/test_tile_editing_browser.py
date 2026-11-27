import base64
import unittest
from io import BytesIO
from unittest.mock import patch
from PIL import Image
import test_artwork_and_keyboard as fixture
from models import DeckTile
from page_store import BrowserPageProvider, PageStore
from icons import get_icon
from browser_tabs import favicon_from_tab


class TileEditingTests(unittest.TestCase):
    setUp = fixture.ArtworkAndKeyboardTests.setUp
    # Reuse the existing server fixture without duplicating its test cases.
    def test_custom_icon_survives_edit_save_reload_and_artwork_refresh(self):
        page=self.app.page_store.pages[0]
        image=BytesIO();Image.new('RGB',(800,400),'magenta').save(image,'JPEG')
        body=dict(pageId=page.id,slotIndex=0,customLabel='My control',customIcon=base64.b64encode(image.getvalue()).decode())
        self.assertTrue(self.server.handle_api('/api/edit_tile',body)['success'])
        tile=page.tiles[0]
        self.assertTrue(tile.customIcon)
        data=tile.iconData
        with Image.open(BytesIO(base64.b64decode(data))) as img: self.assertEqual(img.size,(256,128))
        self.assertTrue(self.server.handle_api('/api/edit_tile',dict(pageId=page.id,slotIndex=0,customLabel='Renamed'))['success'])
        self.assertEqual(tile.iconData,data)
        with patch('windeck.fetch_favicon',return_value=None): self.app.refresh_artwork()
        self.assertEqual(tile.iconData,data)
        restored=PageStore(storage_dir=self.temp.name).pages[0].tiles[0]
        self.assertTrue(restored.customIcon)
        self.assertEqual(restored.iconData,data)
        self.assertTrue(self.server.handle_api('/api/edit_tile',dict(pageId=page.id,slotIndex=0,customIcon=None))['success'])
        self.assertFalse(tile.customIcon)
        self.assertNotEqual(tile.iconData,data)

    def test_invalid_icon_does_not_overwrite_tile(self):
        page=self.app.page_store.pages[0]; before=page.tiles[0].to_dict()
        result=self.server.handle_api('/api/edit_tile',dict(pageId=page.id,slotIndex=0,customLabel='broken',customIcon='not an image'))
        self.assertFalse(result['success']);self.assertEqual(page.tiles[0].to_dict(),before)
        result=self.server.handle_api('/api/edit_tile',dict(pageId='live-page',slotIndex=0,customIcon=None))
        self.assertFalse(result['success'])

    def test_swapping_then_removing_preserves_custom_artwork(self):
        page=self.app.page_store.pages[0];tile=page.tiles[0];tile.customIcon=True
        self.server.handle_api('/api/swap_tiles',dict(pageId=page.id,slotA=0,slotB=1))
        self.assertIs(page.tiles[1],tile);self.assertEqual(tile.slotIndex,1);self.assertTrue(tile.customIcon)
        self.server.handle_api('/api/clear_tile',dict(pageId=page.id,slotIndex=1))
        self.assertIsNone(page.tiles[1])

    def test_browser_icons_and_tab_favicons_reach_wire_format(self):
        tab_icon=get_icon('website')
        page=BrowserPageProvider.get_browser_page([dict(title='Example website',iconData=tab_icon)])
        self.assertEqual(page.tiles[0].to_dict()['iconData'],tab_icon)
        self.assertEqual(page.tiles[0].customLabel,'Example website')
        self.assertEqual(len({tile.iconData for tile in page.tiles[1:10]}),9)
        self.assertEqual(page.tiles[5].tileType.action,'back')

    def test_favicon_capture_is_limited_to_tab_icon_region(self):
        with patch('browser_tabs.ImageGrab.grab',return_value=Image.new('RGB',(16,16),'red')) as grab:
            data=favicon_from_tab((100,20,350,60))
            grab.assert_called_once_with(bbox=(116,32,132,48),all_screens=True)
            with Image.open(BytesIO(base64.b64decode(data))) as img:
                self.assertEqual(img.size,(128,128));self.assertEqual(img.getpixel((64,64)),(255,0,0,255))
