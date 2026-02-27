#!/usr/bin/env python3
"""
Generate all app icon, launch logo, tvOS, and shelf image assets.

Usage:
    python3 scripts/generate_assets.py nexuspvr
    python3 scripts/generate_assets.py dispatcherpvr
    python3 scripts/generate_assets.py all

Requires Pillow:
    python3 -m venv /private/tmp/imgvenv
    source /private/tmp/imgvenv/bin/activate
    pip install Pillow
"""

import argparse
import json
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

# ---------------------------------------------------------------------------
# Brand palettes
# ---------------------------------------------------------------------------

BRANDS = {
    "nexuspvr": {
        "name": "NexusPVR",
        "assets_dir": "NexusPVR/Assets.xcassets",
        # Radial gradient for icon background
        "gradient_center": (42, 107, 153),   # light blue
        "gradient_edge": (15, 35, 60),       # dark blue
        # Recording indicator dot
        "recording_dot": (233, 30, 99),      # #e91e63
        # AccentColor.colorset (None = no color defined, uses system default)
        "accent_rgb": None,
        # LaunchBackground.colorset
        "launch_bg_rgb": (0.059, 0.059, 0.059),  # #0f0f0f
    },
    "dispatcherpvr": {
        "name": "DispatcherPVR",
        "assets_dir": "DispatcherPVR/Assets.xcassets",
        # Radial gradient for icon background
        "gradient_center": (55, 130, 115),   # lighter teal
        "gradient_edge": (12, 38, 33),       # very dark teal
        # Recording indicator dot
        "recording_dot": (217, 72, 72),      # #d94848
        # AccentColor.colorset
        "accent_rgb": (0.263, 0.561, 0.498), # #438f7f
        # LaunchBackground.colorset
        "launch_bg_rgb": (0.071, 0.071, 0.078),  # #121214
    },
}

# ---------------------------------------------------------------------------
# Drawing helpers
# ---------------------------------------------------------------------------

def create_radial_gradient(width, height, center_color, edge_color):
    """Create a radial gradient image from center_color to edge_color."""
    img = Image.new("RGB", (width, height))
    pixels = img.load()
    cx, cy = width / 2, height / 2
    max_dist = math.sqrt((width / 2) ** 2 + (height / 2) ** 2)

    for y in range(height):
        for x in range(width):
            dist = math.sqrt((x - cx) ** 2 + (y - cy) ** 2)
            ratio = min(dist / max_dist, 1.0) ** 0.8  # ease for smoother falloff
            r = int(center_color[0] + (edge_color[0] - center_color[0]) * ratio)
            g = int(center_color[1] + (edge_color[1] - center_color[1]) * ratio)
            b = int(center_color[2] + (edge_color[2] - center_color[2]) * ratio)
            pixels[x, y] = (r, g, b)
    return img


def draw_play_button(draw, cx, cy, scale, color=(255, 255, 255, 255)):
    """Draw a play triangle centred around (cx, cy)."""
    s = 70 * scale
    px = cx - s * 0.15
    points = [
        (px - s * 0.45, cy - s * 0.6),
        (px - s * 0.45, cy + s * 0.6),
        (px + s * 0.55, cy),
    ]
    draw.polygon(points, fill=color)


def draw_recording_dot(draw, cx, cy, scale, dot_color):
    """Draw a recording indicator dot."""
    r = 12 * scale
    dx = cx + 55 * scale
    dy = cy - 45 * scale
    draw.ellipse([dx - r, dy - r, dx + r, dy + r], fill=dot_color + (255,))


# ---------------------------------------------------------------------------
# Asset generators
# ---------------------------------------------------------------------------

def create_app_icon(size, brand):
    """Square app icon with radial gradient, rounded corners, play button, dot."""
    bg = create_radial_gradient(size, size, brand["gradient_center"], brand["gradient_edge"])

    # Rounded-corner mask
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size, size], radius=int(size * 0.22), fill=255)

    rounded = Image.new("RGB", (size, size), brand["gradient_edge"])
    rounded.paste(bg, (0, 0), mask)

    # Foreground overlay
    overlay = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    s = size / 1024.0 * 2.5
    draw_play_button(draw, size / 2, size / 2, s)
    draw_recording_dot(draw, size / 2, size / 2, s, brand["recording_dot"])

    result = Image.new("RGBA", (size, size))
    result.paste(rounded, (0, 0))
    return Image.alpha_composite(result, overlay).convert("RGB")


def create_tvos_back(width, height, brand):
    return create_radial_gradient(width, height, brand["gradient_center"], brand["gradient_edge"])


def create_tvos_front(width, height, brand):
    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    s = width / 400
    draw_play_button(draw, width / 2, height / 2, s)
    draw_recording_dot(draw, width / 2, height / 2, s, brand["recording_dot"])
    return img


def create_tvos_middle(width, height):
    return Image.new("RGBA", (width, height), (0, 0, 0, 0))


def create_shelf_image(width, height, brand):
    """Top shelf image: app icon centred on dark background with subtle glow."""
    bg_color = tuple(int(c * 255) for c in brand["launch_bg_rgb"])
    img = Image.new("RGB", (width, height), bg_color)

    # Centred icon
    icon_h = int(height * 0.6)
    icon_w = icon_h
    icon_bg = create_radial_gradient(icon_w, icon_h, brand["gradient_center"], brand["gradient_edge"])

    # Rounded mask
    mask = Image.new("L", (icon_w, icon_h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, icon_w, icon_h], radius=int(icon_h * 0.15), fill=255)

    # Subtle glow
    glow_size = int(icon_h * 1.4)
    glow = Image.new("RGBA", (glow_size, glow_size), (0, 0, 0, 0))
    gc = brand["gradient_center"]
    ImageDraw.Draw(glow).ellipse([0, 0, glow_size, glow_size], fill=(gc[0], gc[1], gc[2], 30))
    glow = glow.filter(ImageFilter.GaussianBlur(radius=glow_size // 4))

    img_rgba = img.convert("RGBA")
    glow_layer = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    glow_layer.paste(glow, ((width - glow_size) // 2, (height - glow_size) // 2))
    img_rgba = Image.alpha_composite(img_rgba, glow_layer)

    # Paste icon
    ix, iy = (width - icon_w) // 2, (height - icon_h) // 2
    img_rgba.paste(icon_bg, (ix, iy), mask)

    # Foreground elements
    draw = ImageDraw.Draw(img_rgba)
    s = icon_h / 400
    draw_play_button(draw, width / 2, height / 2, s)
    draw_recording_dot(draw, width / 2, height / 2, s, brand["recording_dot"])

    return img_rgba.convert("RGB")


def create_launch_logo(size, brand):
    """Launch-screen logo: icon with transparent background."""
    bg = create_radial_gradient(size, size, brand["gradient_center"], brand["gradient_edge"])

    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size, size], radius=int(size * 0.22), fill=255)

    result = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    result.paste(bg, (0, 0), mask)

    draw = ImageDraw.Draw(result)
    s = size / 400
    draw_play_button(draw, size / 2, size / 2, s)
    draw_recording_dot(draw, size / 2, size / 2, s, brand["recording_dot"])

    return result


# ---------------------------------------------------------------------------
# VHS cassette icon (DispatcherPVR) — uses pre-processed source image
# ---------------------------------------------------------------------------

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
VHS_SOURCE = os.path.join(SCRIPT_DIR, "vhs_source.png")


def _load_vhs_source():
    """Load the VHS source image (black cassette, transparent bg, mirrored)."""
    return Image.open(VHS_SOURCE).convert("RGBA")


def _place_vhs_on_canvas(canvas_w, canvas_h, vhs_fraction=0.85, with_triangle=True):
    """Scale and centre the VHS source image on an RGBA canvas, with optional play triangle."""
    vhs = _load_vhs_source()
    canvas = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))

    margin = int(min(canvas_w, canvas_h) * (1 - vhs_fraction) / 2)
    avail_w = canvas_w - 2 * margin
    avail_h = canvas_h - 2 * margin
    scale = min(avail_w / vhs.width, avail_h / vhs.height)
    new_w, new_h = int(vhs.width * scale), int(vhs.height * scale)
    vhs_scaled = vhs.resize((new_w, new_h), Image.LANCZOS)

    paste_x = (canvas_w - new_w) // 2
    paste_y = (canvas_h - new_h) // 2
    canvas.paste(vhs_scaled, (paste_x, paste_y), vhs_scaled)

    if with_triangle:
        draw = ImageDraw.Draw(canvas)
        tri_cx = paste_x + int(new_w * 0.516)
        tri_cy = paste_y + int(new_h * 0.422)
        tri_size = int(new_h * 0.055)
        angle = math.radians(22)

        def rot(px, py, cx, cy, a):
            dx, dy = px - cx, py - cy
            return cx + dx * math.cos(a) - dy * math.sin(a), cy + dx * math.sin(a) + dy * math.cos(a)

        pts = [
            (tri_cx - tri_size * 0.5, tri_cy - tri_size * 0.7),
            (tri_cx - tri_size * 0.5, tri_cy + tri_size * 0.7),
            (tri_cx + tri_size * 0.8, tri_cy),
        ]
        draw.polygon([rot(*p, tri_cx, tri_cy, angle) for p in pts], fill=(220, 40, 30, 255))

    return canvas


def create_vhs_icon(size, brand):
    """Square app icon: VHS cassette on branded gradient background."""
    bg = create_radial_gradient(size, size, brand["gradient_center"], brand["gradient_edge"])
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size, size],
                                           radius=int(size * 0.22), fill=255)
    result = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    result.paste(bg, (0, 0), mask)

    vhs_layer = _place_vhs_on_canvas(size, size, vhs_fraction=0.85)
    result = Image.alpha_composite(result, vhs_layer)
    final = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    final.paste(result, (0, 0), mask)
    return final.convert("RGB")


def create_vhs_tvos_front(width, height, brand):
    """tvOS front layer: VHS cassette on transparent background."""
    return _place_vhs_on_canvas(width, height, vhs_fraction=0.80)


def create_vhs_launch_logo(size, brand):
    """Launch logo: VHS cassette on transparent background."""
    return _place_vhs_on_canvas(size, size, vhs_fraction=0.80)


def create_vhs_shelf_image(width, height, brand):
    """Top shelf: VHS cassette centred on dark background with glow."""
    bg_color = tuple(int(c * 255) for c in brand["launch_bg_rgb"])
    img = Image.new("RGB", (width, height), bg_color)

    gc = brand["gradient_center"]
    glow_size = int(height * 1.2)
    glow = Image.new("RGBA", (glow_size, glow_size), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([0, 0, glow_size, glow_size],
                                 fill=(gc[0], gc[1], gc[2], 30))
    glow = glow.filter(ImageFilter.GaussianBlur(radius=glow_size // 4))

    img_rgba = img.convert("RGBA")
    glow_layer = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    glow_layer.paste(glow, ((width - glow_size) // 2, (height - glow_size) // 2))
    img_rgba = Image.alpha_composite(img_rgba, glow_layer)

    vhs_layer = _place_vhs_on_canvas(width, height, vhs_fraction=0.50)
    img_rgba = Image.alpha_composite(img_rgba, vhs_layer)
    return img_rgba.convert("RGB")


# ---------------------------------------------------------------------------
# CRT TV icon (Dispatchy / DispatcherPVR) — Matrix green monochrome theme
# ---------------------------------------------------------------------------

CRT_BG = (14, 31, 21)
CRT_TV_BODY = (30, 48, 37)
CRT_SCREEN = (10, 26, 16)
CRT_PLAY = (100, 255, 150)
CRT_REC = (229, 57, 53)
CRT_ANTENNA = (58, 90, 58)
CRT_LEG = (42, 74, 42)
CRT_KNOB = (50, 80, 50)
CRT_SCANLINE = (20, 50, 30)
CRT_BEZEL = (24, 40, 30)


def _draw_crt_on(draw, width, height, s, include_bg=True):
    """Draw CRT TV elements scaled by factor s on a draw context.

    Coordinates are based on a 200x200 reference, offset to centre in (width, height).
    """
    ox = (width - int(200 * s)) // 2
    oy = (height - int(200 * s)) // 2

    if include_bg:
        draw.rectangle([0, 0, width, height], fill=CRT_BG)

    # TV body
    bx1, by1 = ox + int(30 * s), oy + int(45 * s)
    bx2, by2 = ox + int(170 * s), oy + int(155 * s)
    draw.rounded_rectangle([bx1, by1, bx2, by2], radius=int(12 * s), fill=CRT_TV_BODY)

    # Bezel
    draw.rounded_rectangle(
        [bx1 + int(2 * s), by1 + int(2 * s), bx2 - int(2 * s), by2 - int(2 * s)],
        radius=int(10 * s), outline=CRT_BEZEL, width=max(int(1.5 * s), 1),
    )

    # Screen
    sx1, sy1 = ox + int(40 * s), oy + int(55 * s)
    sx2, sy2 = ox + int(145 * s), oy + int(135 * s)
    draw.rounded_rectangle([sx1, sy1, sx2, sy2], radius=int(8 * s), fill=CRT_SCREEN)

    # Scan lines
    for y_line in range(sy1, sy2, max(int(4 * s), 2)):
        draw.line([(sx1, y_line), (sx2, y_line)], fill=CRT_SCANLINE, width=1)

    # Play triangle on screen
    scx = (sx1 + sx2) / 2
    scy = (sy1 + sy2) / 2
    ts = 18 * s
    points = [
        (scx - ts * 0.4, scy - ts * 0.6),
        (scx - ts * 0.4, scy + ts * 0.6),
        (scx + ts * 0.6, scy),
    ]
    draw.polygon(points, fill=CRT_PLAY)

    # REC dot — proportional, smaller at small sizes
    rec_r = max(int(3 * s), 1)
    if int(200 * s) <= 32:
        rec_r = max(int(2 * s), 1)
    rec_cx = ox + int(155 * s)
    rec_cy = oy + int(60 * s)
    draw.ellipse(
        [rec_cx - rec_r, rec_cy - rec_r, rec_cx + rec_r, rec_cy + rec_r],
        fill=CRT_REC,
    )

    # Knobs
    k1x, k1y = ox + int(155 * s), oy + int(110 * s)
    k2x, k2y = ox + int(155 * s), oy + int(130 * s)
    kr = max(int(4 * s), 2)
    if int(200 * s) <= 32:
        kr = max(int(3 * s), 1)
    draw.ellipse([k1x - kr, k1y - kr, k1x + kr, k1y + kr], fill=CRT_KNOB)
    draw.ellipse([k2x - kr, k2y - kr, k2x + kr, k2y + kr], fill=CRT_KNOB)

    # Antennas
    aw = max(int(2.5 * s), 1)
    ant_bl = (ox + int(70 * s), oy + int(45 * s))
    ant_br = (ox + int(130 * s), oy + int(45 * s))
    ant_tl = (ox + int(50 * s), oy + int(18 * s))
    ant_tr = (ox + int(150 * s), oy + int(18 * s))
    draw.line([ant_bl, ant_tl], fill=CRT_ANTENNA, width=aw)
    draw.line([ant_br, ant_tr], fill=CRT_ANTENNA, width=aw)
    tip_r = max(int(2.5 * s), 1)
    for t in (ant_tl, ant_tr):
        draw.ellipse([t[0] - tip_r, t[1] - tip_r, t[0] + tip_r, t[1] + tip_r], fill=CRT_ANTENNA)

    # Legs
    lw = max(int(3 * s), 1)
    draw.line([(ox + int(55 * s), oy + int(155 * s)), (ox + int(45 * s), oy + int(175 * s))], fill=CRT_LEG, width=lw)
    draw.line([(ox + int(145 * s), oy + int(155 * s)), (ox + int(155 * s), oy + int(175 * s))], fill=CRT_LEG, width=lw)
    fw = max(int(4 * s), 2)
    draw.line([(ox + int(38 * s), oy + int(175 * s)), (ox + int(52 * s), oy + int(175 * s))], fill=CRT_LEG, width=fw)
    draw.line([(ox + int(148 * s), oy + int(175 * s)), (ox + int(162 * s), oy + int(175 * s))], fill=CRT_LEG, width=fw)


def create_crt_icon(size, brand):
    """Square CRT TV app icon."""
    img = Image.new("RGB", (size, size), CRT_BG)
    draw = ImageDraw.Draw(img)
    s = size / 200.0
    _draw_crt_on(draw, size, size, s)
    return img


def create_crt_tvos_back(width, height, brand):
    """tvOS back layer: CRT background fill."""
    return Image.new("RGB", (width, height), CRT_BG)


def create_crt_tvos_front(width, height, brand):
    """tvOS front layer: CRT TV on transparent background."""
    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    s = min(width, height) / 200.0
    _draw_crt_on(draw, width, height, s, include_bg=False)
    return img


def create_crt_launch_logo(size, brand):
    """Launch logo: CRT TV on transparent background."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    s = size / 200.0
    _draw_crt_on(draw, size, size, s, include_bg=False)
    return img


def create_crt_shelf_image(width, height, brand):
    """Top shelf: CRT TV centred on dark background."""
    bg_color = tuple(int(c * 255) for c in brand["launch_bg_rgb"])
    img = Image.new("RGB", (width, height), bg_color)
    draw = ImageDraw.Draw(img)
    s = min(width, height) / 200.0 * 0.6
    _draw_crt_on(draw, width, height, s)
    return img


# ---------------------------------------------------------------------------
# Colorset JSON helpers
# ---------------------------------------------------------------------------

def write_accent_colorset(assets_dir, accent_rgb):
    """Write AccentColor.colorset/Contents.json."""
    path = os.path.join(assets_dir, "AccentColor.colorset", "Contents.json")
    if accent_rgb is None:
        data = {
            "colors": [{"idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
        }
    else:
        data = {
            "colors": [{
                "color": {
                    "color-space": "srgb",
                    "components": {
                        "alpha": "1.000",
                        "blue": f"{accent_rgb[2]:.3f}",
                        "green": f"{accent_rgb[1]:.3f}",
                        "red": f"{accent_rgb[0]:.3f}",
                    },
                },
                "idiom": "universal",
            }],
            "info": {"author": "xcode", "version": 1},
        }
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"  {os.path.relpath(path, assets_dir)}")


def write_launch_bg_colorset(assets_dir, rgb):
    """Write LaunchBackground.colorset/Contents.json."""
    path = os.path.join(assets_dir, "LaunchBackground.colorset", "Contents.json")
    data = {
        "colors": [{
            "color": {
                "color-space": "srgb",
                "components": {
                    "alpha": "1.000",
                    "blue": f"{rgb[2]:.3f}",
                    "green": f"{rgb[1]:.3f}",
                    "red": f"{rgb[0]:.3f}",
                },
            },
            "idiom": "universal",
        }],
        "info": {"author": "xcode", "version": 1},
    }
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"  {os.path.relpath(path, assets_dir)}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def save(img, path, force_rgb=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if force_rgb and img.mode != "RGB":
        img = img.convert("RGB")
    img.save(path)
    kb = os.path.getsize(path) // 1024
    print(f"  {os.path.basename(path)} ({img.size[0]}x{img.size[1]}, {img.mode}) — {kb}KB")


def generate(brand_key):
    brand = BRANDS[brand_key]
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    assets = os.path.join(root, brand["assets_dir"])
    is_crt = brand_key == "dispatcherpvr"

    print(f"\n{'='*50}")
    print(f"  {brand['name']} Assets {'(CRT TV style)' if is_crt else ''}")
    print(f"{'='*50}\n")

    # ── App Icons ──────────────────────────────────────
    print("App Icons:")
    icon_dir = os.path.join(assets, "AppIcon.appiconset")
    icon_sizes = {
        "AppIcon-1024.png": 1024,
        "AppIcon-512@2x.png": 1024,
        "AppIcon-512.png": 512,
        "AppIcon-256@2x.png": 512,
        "AppIcon-256.png": 256,
        "AppIcon-128@2x.png": 256,
        "AppIcon-128.png": 128,
        "AppIcon-32@2x.png": 64,
        "AppIcon-32.png": 32,
        "AppIcon-16@2x.png": 32,
        "AppIcon-16.png": 16,
    }
    cache = {}
    for filename, sz in icon_sizes.items():
        if sz not in cache:
            cache[sz] = create_crt_icon(sz, brand) if is_crt else create_app_icon(sz, brand)
        save(cache[sz], os.path.join(icon_dir, filename), force_rgb=True)

    # ── Launch Logo ────────────────────────────────────
    print("\nLaunch Logo:")
    logo_dir = os.path.join(assets, "LaunchLogo.imageset")
    for suffix, sz in [("LaunchLogo.png", 120), ("LaunchLogo@2x.png", 240), ("LaunchLogo@3x.png", 360)]:
        logo = create_crt_launch_logo(sz, brand) if is_crt else create_launch_logo(sz, brand)
        save(logo, os.path.join(logo_dir, suffix))

    # ── Launch Background ──────────────────────────────
    print("\nLaunch Background:")
    bg_dir = os.path.join(assets, "LaunchBG.imageset")
    for suffix, sz in [("LaunchBG.png", 120), ("LaunchBG@2x.png", 240), ("LaunchBG@3x.png", 360)]:
        bg_img = Image.new("RGB", (sz, sz), CRT_BG if is_crt else tuple(int(c * 255) for c in brand["launch_bg_rgb"]))
        save(bg_img, os.path.join(bg_dir, suffix), force_rgb=True)

    # ── tvOS App Icon (400×240) ────────────────────────
    print("\ntvOS App Icon (400x240):")
    tv = os.path.join(assets, "tv.brandassets", "App Icon.imagestack")
    for w, h, tag in [(400, 240, "icon_400x240.png"), (800, 480, "icon_800x480.png")]:
        back = create_crt_tvos_back(w, h, brand) if is_crt else create_tvos_back(w, h, brand)
        save(back, os.path.join(tv, "Back.imagestacklayer", "Content.imageset", tag), force_rgb=True)
        save(create_tvos_middle(w, h), os.path.join(tv, "Middle.imagestacklayer", "Content.imageset", tag))
        front = create_crt_tvos_front(w, h, brand) if is_crt else create_tvos_front(w, h, brand)
        save(front, os.path.join(tv, "Front.imagestacklayer", "Content.imageset", tag))

    # ── tvOS App Store Icon (1280×768) ─────────────────
    print("\ntvOS App Store Icon (1280x768):")
    tvs = os.path.join(assets, "tv.brandassets", "App Icon - App Store.imagestack")
    tag = "icon_1280x768.png"
    back = create_crt_tvos_back(1280, 768, brand) if is_crt else create_tvos_back(1280, 768, brand)
    save(back, os.path.join(tvs, "Back.imagestacklayer", "Content.imageset", tag), force_rgb=True)
    save(create_tvos_middle(1280, 768), os.path.join(tvs, "Middle.imagestacklayer", "Content.imageset", tag))
    front = create_crt_tvos_front(1280, 768, brand) if is_crt else create_tvos_front(1280, 768, brand)
    save(front, os.path.join(tvs, "Front.imagestacklayer", "Content.imageset", tag))

    # ── Top Shelf ──────────────────────────────────────
    print("\nTop Shelf Image:")
    shelf = os.path.join(assets, "tv.brandassets", "Top Shelf Image.imageset")
    shelf_fn = create_crt_shelf_image if is_crt else create_shelf_image
    save(shelf_fn(1920, 720, brand), os.path.join(shelf, "shelf_1920x720.png"), force_rgb=True)
    save(shelf_fn(3840, 1440, brand), os.path.join(shelf, "shelf_3840x1440.png"), force_rgb=True)

    print("\nTop Shelf Image Wide:")
    shelfw = os.path.join(assets, "tv.brandassets", "Top Shelf Image Wide.imageset")
    save(shelf_fn(2320, 720, brand), os.path.join(shelfw, "shelf_wide_2320x720.png"), force_rgb=True)
    save(shelf_fn(4640, 1440, brand), os.path.join(shelfw, "shelf_wide_4640x1440.png"), force_rgb=True)

    # ── Color sets ─────────────────────────────────────
    print("\nColorsets:")
    write_accent_colorset(assets, brand["accent_rgb"])
    write_launch_bg_colorset(assets, brand["launch_bg_rgb"])

    print()


def main():
    parser = argparse.ArgumentParser(description="Generate NexusPVR / DispatcherPVR image assets.")
    parser.add_argument(
        "brand",
        choices=["nexuspvr", "dispatcherpvr", "all"],
        help="Which brand to generate assets for (or 'all' for both)",
    )
    args = parser.parse_args()

    if args.brand == "all":
        for key in BRANDS:
            generate(key)
    else:
        generate(args.brand)

    print("Done.")


if __name__ == "__main__":
    main()
