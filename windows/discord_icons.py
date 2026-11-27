"""Small, state-aware Discord tile artwork shared by the Windows editor and phone."""
import base64
from functools import lru_cache
from io import BytesIO

from PIL import Image, ImageDraw, ImageFont

from icons import get_icon


@lru_cache(maxsize=128)
def icon(action, badge=None, avatar=None, name=None):
    if action == "openDiscord":
        return get_icon("discordControl")
    image = Image.new("RGB", (128, 128), "#5865F2")
    d = ImageDraw.Draw(image)
    white = "white"
    if name is not None:
        colors = ("#285d78", "#614580", "#82532f", "#286756", "#774659", "#3f5482")
        d.rectangle((0, 0, 128, 128), fill=colors[sum(name.encode()) % len(colors)])
        initials = "".join(word[0] for word in name.split()[:2]).upper()
        if avatar:
            with Image.open(BytesIO(avatar)) as source:
                image.paste(source.convert("RGB").resize((76, 76), Image.Resampling.LANCZOS), (26, 7))
        else:
            d.text((64, 48), initials, font=ImageFont.load_default(size=48), anchor="mm", fill=white)
        font = ImageFont.load_default(size=20)
        caption = name
        while caption and d.textlength(caption, font=font) > 119:
            caption = caption[:-2].rstrip() + "…" if len(caption) > 2 else "…"
        d.text((64, 100), caption, font=font, anchor="mm", fill=white)
    elif action in ("mute", "unmute", "toggleMute"):
        d.rounded_rectangle((52, 20, 76, 71), radius=12, fill=white)
        d.arc((38, 35, 90, 87), 0, 180, fill=white, width=7)
        d.line([(64, 86), (64, 102)], fill=white, width=7)
        d.line([(46, 104), (82, 104)], fill=white, width=7)
    elif action in ("deafen", "undeafen", "toggleDeafen"):
        d.arc((25, 25, 103, 104), 180, 360, fill=white, width=8)
        for x in (26, 82):
            d.rounded_rectangle((x, 60, x + 20, 98), radius=6, fill=white)
    elif action in ("cameraOn", "cameraOff"):
        d.rounded_rectangle((20, 40, 75, 88), radius=8, fill=white)
        d.polygon([(78, 54), (105, 39), (105, 89), (78, 75)], fill=white)
    elif action in ("share", "stopShare"):
        d.rounded_rectangle((18, 26, 110, 87), radius=7, outline=white, width=6)
        d.line([(64, 87), (64, 98)], fill=white, width=7)
        d.line([(43, 100), (85, 100)], fill=white, width=7)
        if action == "stopShare":
            d.rectangle((54, 47, 74, 67), fill=white)
    elif action == "disconnect":
        d.arc((19, 46, 109, 101), 185, 355, fill=white, width=12)
        for x in (19, 86):
            d.rounded_rectangle((x, 64, x + 22, 82), radius=6, fill=white)
    elif action == "server":
        for x in (53, 77):
            d.line([(x + 8, 24), (x - 8, 98)], fill=white, width=7)
        for y in (47, 76):
            d.line([(32, y), (97, y)], fill=white, width=7)
    else:
        if avatar:
            with Image.open(BytesIO(avatar)) as source:
                image.paste(source.convert("RGB").resize((128, 128), Image.Resampling.LANCZOS))
        else:
            d.ellipse((46, 21, 82, 57), fill=white)
            d.rounded_rectangle((28, 62, 100, 105), radius=22, fill=white)
    if action in ("unmute", "undeafen", "cameraOn"):
        for width, color in [(12, "#5865F2"), (6, white)]:
            d.line([(23, 22), (103, 103)], fill=color, width=width)
    if action == "answer":
        d.ellipse((77, 77, 127, 127), fill="#15803d")
        d.arc((85, 85, 118, 118), 80, 185, fill=white, width=6)
        d.rounded_rectangle((85, 89, 94, 101), radius=3, fill=white)
        d.rounded_rectangle((102, 108, 115, 117), radius=3, fill=white)
    elif badge:
        font = ImageFont.load_default(size=22)
        width = max(34, int(d.textlength(badge, font=font)) + 14)
        x = 125 - width
        y = 3 if name else 79
        d.rounded_rectangle((x, y, 125, y + 34), radius=10, fill="#bf2637")
        d.polygon([(x+6, y+29), (x+4, y+42), (x+19, y+29)], fill="#bf2637")
        d.text((x+width/2, y+16), badge, font=font, anchor="mm", fill=white)
    result = BytesIO()
    image.save(result, format="PNG")
    return base64.b64encode(result.getvalue()).decode()
