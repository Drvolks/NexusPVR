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

def save(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    kb = os.path.getsize(path) // 1024
    print(f"  {os.path.basename(path)} ({img.size[0]}x{img.size[1]}) — {kb}KB")


def generate(brand_key):
    brand = BRANDS[brand_key]
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    assets = os.path.join(root, brand["assets_dir"])

    print(f"\n{'='*50}")
    print(f"  {brand['name']} Assets")
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
            cache[sz] = create_app_icon(sz, brand)
        save(cache[sz], os.path.join(icon_dir, filename))

    # ── Launch Logo ────────────────────────────────────
    print("\nLaunch Logo:")
    logo_dir = os.path.join(assets, "LaunchLogo.imageset")
    for suffix, sz in [("LaunchLogo.png", 120), ("LaunchLogo@2x.png", 240), ("LaunchLogo@3x.png", 360)]:
        save(create_launch_logo(sz, brand), os.path.join(logo_dir, suffix))

    # ── tvOS App Icon (400×240) ────────────────────────
    print("\ntvOS App Icon (400x240):")
    tv = os.path.join(assets, "tv.brandassets", "App Icon.imagestack")
    for w, h, tag in [(400, 240, "icon_400x240.png"), (800, 480, "icon_800x480.png")]:
        save(create_tvos_back(w, h, brand), os.path.join(tv, "Back.imagestacklayer", "Content.imageset", tag))
        save(create_tvos_middle(w, h), os.path.join(tv, "Middle.imagestacklayer", "Content.imageset", tag))
        save(create_tvos_front(w, h, brand), os.path.join(tv, "Front.imagestacklayer", "Content.imageset", tag))

    # ── tvOS App Store Icon (1280×768) ─────────────────
    print("\ntvOS App Store Icon (1280x768):")
    tvs = os.path.join(assets, "tv.brandassets", "App Icon - App Store.imagestack")
    tag = "icon_1280x768.png"
    save(create_tvos_back(1280, 768, brand), os.path.join(tvs, "Back.imagestacklayer", "Content.imageset", tag))
    save(create_tvos_middle(1280, 768), os.path.join(tvs, "Middle.imagestacklayer", "Content.imageset", tag))
    save(create_tvos_front(1280, 768, brand), os.path.join(tvs, "Front.imagestacklayer", "Content.imageset", tag))

    # ── Top Shelf ──────────────────────────────────────
    print("\nTop Shelf Image:")
    shelf = os.path.join(assets, "tv.brandassets", "Top Shelf Image.imageset")
    save(create_shelf_image(1920, 720, brand), os.path.join(shelf, "shelf_1920x720.png"))
    save(create_shelf_image(3840, 1440, brand), os.path.join(shelf, "shelf_3840x1440.png"))

    print("\nTop Shelf Image Wide:")
    shelfw = os.path.join(assets, "tv.brandassets", "Top Shelf Image Wide.imageset")
    save(create_shelf_image(2320, 720, brand), os.path.join(shelfw, "shelf_wide_2320x720.png"))
    save(create_shelf_image(4640, 1440, brand), os.path.join(shelfw, "shelf_wide_4640x1440.png"))

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
