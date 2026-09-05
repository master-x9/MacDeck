import os
import subprocess
import json
from PIL import Image, ImageDraw, ImageFilter

def create_macdeck_icon(size=1024, transparent=False):
    SS = 4
    W = size * SS
    H = size * SS
    
    # Base canvas
    canvas = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    
    if not transparent:
        # Apple macOS standard squircle background (padding ~9%)
        pad_x = int(W * 0.085)
        pad_y = int(H * 0.085)
        radius = int(W * 0.22)
        
        # Soft Drop Shadow under squircle
        shadow_layer = Image.new('RGBA', (W, H), (0, 0, 0, 0))
        s_draw = ImageDraw.Draw(shadow_layer)
        s_draw.rounded_rectangle([pad_x, pad_y + int(14 * SS), W - pad_x, H - pad_y + int(20 * SS)], radius=radius, fill=(0, 0, 0, 170))
        shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(int(16 * SS)))
        canvas = Image.alpha_composite(canvas, shadow_layer)
        
        # Squircle Background with Deep Slate Gradient
        bg_layer = Image.new('RGBA', (W, H), (0, 0, 0, 0))
        bg_draw = ImageDraw.Draw(bg_layer)
        for y in range(pad_y, H - pad_y):
            prog = (y - pad_y) / float(H - 2 * pad_y)
            r = int(24 * (1 - prog) + 11 * prog)
            g = int(25 * (1 - prog) + 12 * prog)
            b = int(32 * (1 - prog) + 15 * prog)
            bg_draw.line([(pad_x, y), (W - pad_x, y)], fill=(r, g, b, 255))
            
        mask = Image.new('L', (W, H), 0)
        m_draw = ImageDraw.Draw(mask)
        m_draw.rounded_rectangle([pad_x, pad_y, W - pad_x, H - pad_y], radius=radius, fill=255)
        
        sq_img = Image.new('RGBA', (W, H), (0, 0, 0, 0))
        sq_img.paste(bg_layer, (0, 0), mask)
        
        # Razor thin highlight border on squircle
        sq_draw = ImageDraw.Draw(sq_img)
        sq_draw.rounded_rectangle([pad_x, pad_y, W - pad_x, H - pad_y], radius=radius, outline=(255, 255, 255, 26), width=int(2.5 * SS))
        sq_draw.line([pad_x + radius, pad_y, W - pad_x - radius, pad_y], fill=(255, 255, 255, 55), width=int(2 * SS))
        
        canvas = Image.alpha_composite(canvas, sq_img)

    # --- MacBook Geometry ---
    if transparent:
        mb_w = int(W * 0.76)
        mb_h = int(W * 0.52)
        mb_x = (W - mb_w) // 2
        mb_y = int(H * 0.20)
        base_w = int(W * 0.90)
    else:
        mb_w = int(W * 0.58)
        mb_h = int(W * 0.40)
        mb_x = (W - mb_w) // 2
        mb_y = int(H * 0.245)
        base_w = int(W * 0.70)
    
    lid_radius = int(mb_w * 0.072)
    bezel_thickness = int(mb_w * 0.042)
    
    # Outer Lid (Silver aluminum)
    macbook_layer = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    mb_draw = ImageDraw.Draw(macbook_layer)
    
    # Lid Shadow
    lid_shadow = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    ls_draw = ImageDraw.Draw(lid_shadow)
    ls_draw.rounded_rectangle([mb_x, mb_y + int(6 * SS), mb_x + mb_w, mb_y + mb_h + int(10 * SS)], radius=lid_radius, fill=(0, 0, 0, 110))
    lid_shadow = lid_shadow.filter(ImageFilter.GaussianBlur(int(8 * SS)))
    canvas = Image.alpha_composite(canvas, lid_shadow)
    
    # Lid Bezel Fill
    mb_draw.rounded_rectangle(
        [mb_x, mb_y, mb_x + mb_w, mb_y + mb_h],
        radius=lid_radius,
        fill=(242, 243, 247, 255)
    )
    
    # Screen Area (Deep OLED Display)
    sc_x1 = mb_x + bezel_thickness
    sc_y1 = mb_y + bezel_thickness
    sc_x2 = mb_x + mb_w - bezel_thickness
    sc_y2 = mb_y + mb_h - bezel_thickness
    sc_radius = int(lid_radius * 0.65)
    
    mb_draw.rounded_rectangle(
        [sc_x1, sc_y1, sc_x2, sc_y2],
        radius=sc_radius,
        fill=(12, 13, 16, 255)
    )
    
    # 4 Color Deck Tiles
    screen_w = sc_x2 - sc_x1
    screen_h = sc_y2 - sc_y1
    
    pad_h = int(screen_w * 0.11)
    pad_v = int(screen_h * 0.11)
    gap_x = int(screen_w * 0.08)
    gap_y = int(screen_h * 0.08)
    
    t_w = (screen_w - 2 * pad_h - gap_x) // 2
    t_h = (screen_h - 2 * pad_v - gap_y) // 2
    t_rad = int(min(t_w, t_h) * 0.32)
    
    tiles = [
        (sc_x1 + pad_h, sc_y1 + pad_v, (10, 132, 255, 255)),               # Top-Left: Blue (#0A84FF)
        (sc_x1 + pad_h + t_w + gap_x, sc_y1 + pad_v, (48, 209, 88, 255)),  # Top-Right: Green (#30D158)
        (sc_x1 + pad_h, sc_y1 + pad_v + t_h + gap_y, (255, 159, 10, 255)), # Bottom-Left: Orange (#FF9F0A)
        (sc_x1 + pad_h + t_w + gap_x, sc_y1 + pad_v + t_h + gap_y, (255, 69, 58, 255)), # Bottom-Right: Red (#FF453A)
    ]
    
    for tx, ty, fill_col in tiles:
        # Tile shadow
        mb_draw.rounded_rectangle([tx, ty + int(2 * SS), tx + t_w, ty + t_h + int(3 * SS)], radius=t_rad, fill=(0, 0, 0, 100))
        # Tile body
        mb_draw.rounded_rectangle([tx, ty, tx + t_w, ty + t_h], radius=t_rad, fill=fill_col)
        # Subtle top inner highlight
        if t_w > int(6 * SS) and t_h > int(6 * SS):
            mb_draw.rounded_rectangle([tx + int(1.5*SS), ty + int(1.5*SS), tx + t_w - int(1.5*SS), ty + t_h - int(1.5*SS)], radius=int(t_rad * 0.85), outline=(255, 255, 255, 50), width=int(1.5 * SS))
        
    # --- MacBook Bottom Base ---
    base_h = int(mb_h * 0.16)
    base_x = (W - base_w) // 2
    base_y = mb_y + mb_h + int(W * 0.008)
    base_radius = int(base_h * 0.44)
    
    # Base Shadow
    b_shadow = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    bs_draw = ImageDraw.Draw(b_shadow)
    bs_draw.rounded_rectangle([base_x, base_y + int(4 * SS), base_x + base_w, base_y + base_h + int(8 * SS)], radius=base_radius, fill=(0, 0, 0, 120))
    b_shadow = b_shadow.filter(ImageFilter.GaussianBlur(int(6 * SS)))
    canvas = Image.alpha_composite(canvas, b_shadow)
    
    # Base Body
    mb_draw.rounded_rectangle(
        [base_x, base_y, base_x + base_w, base_y + base_h],
        radius=base_radius,
        fill=(242, 243, 247, 255)
    )
    
    # Sleek Center Thumb Notch Indent
    notch_w = int(base_w * 0.16)
    notch_h = int(base_h * 0.45)
    notch_x = (W - notch_w) // 2
    notch_y = base_y
    notch_rad = int(notch_h * 0.65)
    
    notch_color = (20, 21, 26, 255) if not transparent else (14, 14, 18, 255)
    mb_draw.rounded_rectangle(
        [notch_x, notch_y, notch_x + notch_w, notch_y + notch_h],
        radius=notch_rad,
        fill=notch_color
    )
    
    canvas = Image.alpha_composite(canvas, macbook_layer)
    
    # Downsample cleanly to final output size
    res = canvas.resize((size, size), Image.Resampling.LANCZOS)
    return res

if __name__ == '__main__':
    os.makedirs('app_icons', exist_ok=True)
    print("Rendering Master App Icons (1024x1024)...")

    # Master 1024 Icons
    master_icon = create_macdeck_icon(1024, transparent=False)
    master_icon.save('app_icons/macdeck_app_icon_1024.png', 'PNG')
    
    master_transparent = create_macdeck_icon(1024, transparent=True)
    master_transparent.save('app_icons/macdeck_app_icon_transparent_1024.png', 'PNG')

    # Generate all downscaled sizes from master for pixel perfection
    for s in [512, 256, 128, 64, 32, 16]:
        resized = master_icon.resize((s, s), Image.Resampling.LANCZOS)
        resized.save(f'app_icons/macdeck_app_icon_{s}.png', 'PNG')
        
        if s in [512, 256, 128]:
            resized_t = master_transparent.resize((s, s), Image.Resampling.LANCZOS)
            resized_t.save(f'app_icons/macdeck_app_icon_transparent_{s}.png', 'PNG')

    print("Generating SVG vector versions...")

    svg_content = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <!-- Background Gradient -->
    <linearGradient id="bgGrad" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#191920" />
      <stop offset="100%" stop-color="#0b0b0e" />
    </linearGradient>
    
    <!-- Screen Gradient -->
    <linearGradient id="screenGrad" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#14151a" />
      <stop offset="100%" stop-color="#0c0d10" />
    </linearGradient>

    <!-- Aluminum Bezel Gradient -->
    <linearGradient id="aluminumGrad" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#ffffff" />
      <stop offset="100%" stop-color="#e1e2e8" />
    </linearGradient>

    <!-- Drop Shadow Filter -->
    <filter id="appShadow" x="-10%" y="-10%" width="120%" height="125%" filterUnits="userSpaceOnUse">
      <feDropShadow dx="0" dy="24" stdDeviation="28" flood-color="#000000" flood-opacity="0.65" />
    </filter>
    
    <filter id="laptopShadow" x="-10%" y="-10%" width="120%" height="125%" filterUnits="userSpaceOnUse">
      <feDropShadow dx="0" dy="16" stdDeviation="16" flood-color="#000000" flood-opacity="0.45" />
    </filter>
  </defs>

  <!-- Squircle App Icon Background -->
  <rect x="92" y="92" width="840" height="840" rx="230" fill="url(#bgGrad)" filter="url(#appShadow)" stroke="rgba(255,255,255,0.12)" stroke-width="2.5" />

  <!-- MacBook Group -->
  <g filter="url(#laptopShadow)">
    <!-- MacBook Screen Lid -->
    <rect x="215" y="250" width="594" height="420" rx="42" fill="url(#aluminumGrad)" />
    
    <!-- OLED Screen Interior -->
    <rect x="240" y="275" width="544" height="370" rx="28" fill="url(#screenGrad)" />

    <!-- 4 Colored Stream Deck Tiles -->
    <!-- Top-Left: Blue -->
    <rect x="300" y="325" width="200" height="120" rx="30" fill="#0A84FF" />
    <!-- Top-Right: Green -->
    <rect x="524" y="325" width="200" height="120" rx="30" fill="#30D158" />
    <!-- Bottom-Left: Orange -->
    <rect x="300" y="475" width="200" height="120" rx="30" fill="#FF9F0A" />
    <!-- Bottom-Right: Red -->
    <rect x="524" y="475" width="200" height="120" rx="30" fill="#FF453A" />

    <!-- MacBook Base Deck -->
    <path d="M153 686 C153 670 166 657 182 657 H430 C436 657 442 662 445 668 L449 676 C453 684 461 689 470 689 H554 C563 689 571 684 575 676 L579 668 C582 662 588 657 594 657 H842 C858 657 871 670 871 686 V694 C871 712 856 726 838 726 H186 C168 726 153 712 153 694 Z" fill="url(#aluminumGrad)" />
  </g>
</svg>
'''

    with open('app_icons/macdeck_app_icon.svg', 'w') as f:
        f.write(svg_content)

    svg_transparent = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <linearGradient id="screenGradT" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#14151a" />
      <stop offset="100%" stop-color="#0c0d10" />
    </linearGradient>
    <linearGradient id="aluminumGradT" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#ffffff" />
      <stop offset="100%" stop-color="#e1e2e8" />
    </linearGradient>
    <filter id="laptopShadowT" x="-10%" y="-10%" width="120%" height="125%" filterUnits="userSpaceOnUse">
      <feDropShadow dx="0" dy="16" stdDeviation="16" flood-color="#000000" flood-opacity="0.45" />
    </filter>
  </defs>

  <g filter="url(#laptopShadowT)">
    <rect x="215" y="250" width="594" height="420" rx="42" fill="url(#aluminumGradT)" />
    <rect x="240" y="275" width="544" height="370" rx="28" fill="url(#screenGradT)" />
    <rect x="300" y="325" width="200" height="120" rx="30" fill="#0A84FF" />
    <rect x="524" y="325" width="200" height="120" rx="30" fill="#30D158" />
    <rect x="300" y="475" width="200" height="120" rx="30" fill="#FF9F0A" />
    <rect x="524" y="475" width="200" height="120" rx="30" fill="#FF453A" />
    <path d="M153 686 C153 670 166 657 182 657 H430 C436 657 442 662 445 668 L449 676 C453 684 461 689 470 689 H554 C563 689 571 684 575 676 L579 668 C582 662 588 657 594 657 H842 C858 657 871 670 871 686 V694 C871 712 856 726 838 726 H186 C168 726 153 712 153 694 Z" fill="url(#aluminumGradT)" />
  </g>
</svg>
'''

    with open('app_icons/macdeck_app_icon_transparent.svg', 'w') as f:
        f.write(svg_transparent)

    print("Building macOS AppIcon.icns & AppIcon.appiconset...")

    iconset_dir = 'app_icons/MacDeck.iconset'
    os.makedirs(iconset_dir, exist_ok=True)

    icon_map = {
        'icon_16x16.png': 16,
        'icon_16x16@2x.png': 32,
        'icon_32x32.png': 32,
        'icon_32x32@2x.png': 64,
        'icon_128x128.png': 128,
        'icon_128x128@2x.png': 256,
        'icon_256x256.png': 256,
        'icon_256x256@2x.png': 512,
        'icon_512x512.png': 512,
        'icon_512x512@2x.png': 1024,
    }

    for fname, s in icon_map.items():
        resized = master_icon.resize((s, s), Image.Resampling.LANCZOS)
        resized.save(os.path.join(iconset_dir, fname), 'PNG')

    # Run iconutil
    try:
        subprocess.run(['iconutil', '-c', 'icns', iconset_dir, '-o', 'app_icons/MacDeck.icns'], check=True)
        print("Generated app_icons/MacDeck.icns!")
    except Exception as e:
        print("iconutil info:", e)

    # Populate Xcode Assets.xcassets/AppIcon.appiconset
    xc_appicon_dir = 'Assets.xcassets/AppIcon.appiconset'
    if os.path.exists(xc_appicon_dir):
        for fname, s in icon_map.items():
            resized = master_icon.resize((s, s), Image.Resampling.LANCZOS)
            resized.save(os.path.join(xc_appicon_dir, fname), 'PNG')
        
        xc_contents = {
            "images": [
                {"idiom": "mac", "scale": "1x", "size": "16x16", "filename": "icon_16x16.png"},
                {"idiom": "mac", "scale": "2x", "size": "16x16", "filename": "icon_16x16@2x.png"},
                {"idiom": "mac", "scale": "1x", "size": "32x32", "filename": "icon_32x32.png"},
                {"idiom": "mac", "scale": "2x", "size": "32x32", "filename": "icon_32x32@2x.png"},
                {"idiom": "mac", "scale": "1x", "size": "128x128", "filename": "icon_128x128.png"},
                {"idiom": "mac", "scale": "2x", "size": "128x128", "filename": "icon_128x128@2x.png"},
                {"idiom": "mac", "scale": "1x", "size": "256x256", "filename": "icon_256x256.png"},
                {"idiom": "mac", "scale": "2x", "size": "256x256", "filename": "icon_256x256@2x.png"},
                {"idiom": "mac", "scale": "1x", "size": "512x512", "filename": "icon_512x512.png"},
                {"idiom": "mac", "scale": "2x", "size": "512x512", "filename": "icon_512x512@2x.png"}
            ],
            "info": {
                "author": "xcode",
                "version": 1
            }
        }
        with open(os.path.join(xc_appicon_dir, 'Contents.json'), 'w') as f:
            json.dump(xc_contents, f, indent=2)
        print("Updated Xcode Assets.xcassets/AppIcon.appiconset!")

    print("All App Icon formats successfully generated!")
