#!/usr/bin/env python3
import json
import math
import os
from PIL import Image, ImageDraw, ImageFilter

def create_master_icon(size=2048):
    # Base dark gradient
    img = Image.new("RGBA", (size, size), (7, 11, 14, 255))
    draw = ImageDraw.Draw(img)

    cx, cy = size / 2.0, size / 2.0

    # Subtle radial background glow
    bg_glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    bg_draw = ImageDraw.Draw(bg_glow)
    for r in range(int(size * 0.48), 0, -16):
        alpha = int(22 * (1.0 - r / (size * 0.48)))
        bg_draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(18, 38, 35, alpha))
    bg_glow = bg_glow.filter(ImageFilter.GaussianBlur(32))
    img = Image.alpha_composite(img, bg_glow)

    # Outer rounded squircle container
    pad = size * 0.05
    box = [pad, pad, size - pad, size - pad]
    radius = size * 0.22

    plate = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    plate_draw = ImageDraw.Draw(plate)
    # Subtle dark inner plate
    plate_draw.rounded_rectangle(box, radius=radius, fill=(12, 19, 23, 240), outline=(36, 52, 58, 255), width=int(size * 0.012))
    img = Image.alpha_composite(img, plate)

    # Glow layer for mesh links and nodes
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)

    # Sharp foreground layer
    fg = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    fg_draw = ImageDraw.Draw(fg)

    # Geometry for the MGS Mesh "M" constellation
    # Central M vertices
    p1 = (cx - size * 0.25, cy + size * 0.22)   # Left foot
    p2 = (cx - size * 0.16, cy - size * 0.16)   # Left peak
    p3 = (cx, cy + size * 0.04)                # Center valley
    p4 = (cx + size * 0.16, cy - size * 0.16)   # Right peak
    p5 = (cx + size * 0.25, cy + size * 0.22)   # Right foot

    # Secondary mesh cross-nodes (showing peer connections)
    s_top = (cx, cy - size * 0.30)              # Wi-Fi / Top wireless apex
    s_left = (cx - size * 0.32, cy - size * 0.02)
    s_right = (cx + size * 0.32, cy - size * 0.02)
    s_bottom = (cx, cy + size * 0.28)           # USB / Base link

    all_nodes = [p1, p2, p3, p4, p5, s_top, s_left, s_right, s_bottom]

    links = [
        # Main M trunk
        (p1, p2, (201, 255, 106), 26),
        (p2, p3, (201, 255, 106), 26),
        (p3, p4, (98, 230, 200), 26),
        (p4, p5, (98, 230, 200), 26),
        # Inter-mesh lattice cross links
        (p2, p4, (80, 160, 150), 12),
        (p1, p3, (120, 190, 100), 12),
        (p3, p5, (70, 180, 170), 12),
        (p2, s_top, (98, 230, 200), 14),
        (p4, s_top, (98, 230, 200), 14),
        (p1, s_left, (160, 220, 100), 10),
        (p2, s_left, (160, 220, 100), 10),
        (p4, s_right, (70, 190, 180), 10),
        (p5, s_right, (70, 190, 180), 10),
        (p1, s_bottom, (140, 200, 110), 12),
        (p5, s_bottom, (80, 180, 170), 12),
        (p3, s_bottom, (98, 230, 200), 14),
    ]

    # Draw wireless broadcast arcs above top apex (representing Wi-Fi & BLE waves)
    for wave_r, wave_w, wave_alpha in [(size * 0.14, 14, 180), (size * 0.22, 12, 130), (size * 0.30, 10, 80)]:
        arc_box = [cx - wave_r, s_top[1] - wave_r * 0.7, cx + wave_r, s_top[1] + wave_r * 1.3]
        glow_draw.arc(arc_box, start=205, end=335, fill=(98, 230, 200, 220), width=int(wave_w * 2.2))
        fg_draw.arc(arc_box, start=205, end=335, fill=(98, 230, 200, wave_alpha), width=wave_w)

    # Draw link tubes (glow + sharp line)
    for (start, end, col, w) in links:
        # Glow pass
        glow_draw.line([start, end], fill=(col[0], col[1], col[2], 180), width=int(w * 2.8))
        # Sharp core pass
        fg_draw.line([start, end], fill=(col[0], col[1], col[2], 240), width=w)
        # Inner white-hot specular center
        fg_draw.line([start, end], fill=(245, 255, 240, 120), width=max(2, int(w * 0.28)))

    # Draw nodes
    for idx, (nx, ny) in enumerate(all_nodes):
        if idx in (1, 2, 3, 5): # Major peaks / center / top
            nr = size * 0.042
            col = (201, 255, 106) if idx in (1, 2) else (98, 230, 200)
        elif idx in (0, 4):     # Base feet
            nr = size * 0.038
            col = (201, 255, 106) if idx == 0 else (98, 230, 200)
        else:                   # Satellites
            nr = size * 0.026
            col = (110, 210, 190)

        # Multi-stage glow
        for gr, ga in [(nr * 2.5, 70), (nr * 1.7, 140), (nr * 1.2, 220)]:
            glow_draw.ellipse([nx - gr, ny - gr, nx + gr, ny + gr], fill=(col[0], col[1], col[2], ga))

        # Sharp node body
        fg_draw.ellipse([nx - nr, ny - nr, nx + nr, ny + nr], fill=(col[0], col[1], col[2], 255))
        # Outer dark ring
        fg_draw.ellipse([nx - nr, ny - nr, nx + nr, ny + nr], outline=(7, 11, 14, 255), width=int(size * 0.005))
        # White specular core
        in_r = nr * 0.45
        fg_draw.ellipse([nx - in_r, ny - in_r, nx + in_r, ny + in_r], fill=(255, 255, 255, 240))

    # Apply Gaussian blur to glow layer
    glow_blurred = glow.filter(ImageFilter.GaussianBlur(size * 0.016))
    glow_soft = glow.filter(ImageFilter.GaussianBlur(size * 0.045))

    img = Image.alpha_composite(img, glow_soft)
    img = Image.alpha_composite(img, glow_blurred)
    img = Image.alpha_composite(img, fg)

    # Downscale to 1024x1024 with LANCZOS
    master_1024 = img.resize((1024, 1024), Image.Resampling.LANCZOS)
    return master_1024

def generate_all(base_dir):
    print("Generating master icon...")
    master = create_master_icon(2048)

    # 1. Assets master
    assets_dir = os.path.join(base_dir, "assets", "icon")
    os.makedirs(assets_dir, exist_ok=True)
    master_path = os.path.join(assets_dir, "app_icon.png")
    master.save(master_path, "PNG")
    print(f"Saved {master_path}")

    # 2. Android mipmaps
    android_res = os.path.join(base_dir, "android", "app", "src", "main", "res")
    mipmap_targets = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    for folder, px in mipmap_targets.items():
        folder_path = os.path.join(android_res, folder)
        os.makedirs(folder_path, exist_ok=True)
        out_path = os.path.join(folder_path, "ic_launcher.png")
        resized = master.resize((px, px), Image.Resampling.LANCZOS)
        resized.save(out_path, "PNG")
        print(f"Saved Android {folder} ({px}x{px}) -> {out_path}")

    # 3. iOS icons
    ios_icon_dir = os.path.join(base_dir, "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset")
    contents_path = os.path.join(ios_icon_dir, "Contents.json")
    if os.path.exists(contents_path):
        with open(contents_path, "r", encoding="utf-8") as f:
            meta = json.load(f)
        for entry in meta.get("images", []):
            fn = entry.get("filename")
            size_str = entry.get("size")
            scale_str = entry.get("scale", "1x")
            if fn and size_str:
                base_w, base_h = [float(x) for x in size_str.split("x")]
                scale = float(scale_str.replace("x", ""))
                px_w = int(round(base_w * scale))
                px_h = int(round(base_h * scale))
                out_path = os.path.join(ios_icon_dir, fn)
                resized = master.resize((px_w, px_h), Image.Resampling.LANCZOS)
                resized.save(out_path, "PNG")
                print(f"Saved iOS {fn} ({px_w}x{px_h}) -> {out_path}")

    # 4. Windows ICO
    win_ico_path = os.path.join(base_dir, "windows", "runner", "resources", "app_icon.ico")
    ico_sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    master.save(win_ico_path, format="ICO", sizes=ico_sizes)
    print(f"Saved Windows ICO -> {win_ico_path}")

if __name__ == "__main__":
    import sys
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    generate_all(root)
