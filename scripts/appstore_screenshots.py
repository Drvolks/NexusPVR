#!/usr/bin/env python3
"""
Convert simulator screenshots to App Store-compatible dimensions.

Usage:
    python3 scripts/appstore_screenshots.py <input_dir_or_files...> [--output <dir>]

Examples:
    # Convert all PNGs on the Desktop
    python3 scripts/appstore_screenshots.py ~/Desktop/Simulator*.png

    # Convert a directory of screenshots
    python3 scripts/appstore_screenshots.py ~/Desktop/screenshots/ --output ~/Desktop/appstore/

    # Force macOS sizing for all input files
    python3 scripts/appstore_screenshots.py ~/Desktop/Capture*.png -d mac

    # Force macOS with a custom background color
    python3 scripts/appstore_screenshots.py ~/Desktop/Capture*.png -d mac --mac-bg 000000

App Store required sizes:
    iPhone 6.5"   : 1242 x 2688 (portrait) or 2688 x 1242 (landscape)
    iPhone 6.7"   : 1284 x 2778 (portrait) or 2778 x 1284 (landscape)
    iPad Pro 11"  : 2064 x 2752 (portrait) or 2752 x 2064 (landscape)
    iPad Pro 12.9": 2048 x 2732 (portrait) or 2732 x 2048 (landscape)
    Mac           : 2560 x 1600, 2880 x 1800 (landscape only)

The script auto-detects iPhone / iPad / Mac from the screenshot dimensions,
auto-detects orientation, and scales to fill then center-crops.

For macOS, window screenshots are centered on a solid background (default:
dark navy #1a1a2e) at 85% max size, preserving the window chrome and shadow.
"""

import argparse
import os
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("Pillow is required. Install with: pip install Pillow")
    sys.exit(1)

# App Store required sizes: (width, height) for portrait
IPHONE_TARGETS = {
    "iphone_6.5": (1242, 2688),
    "iphone_6.7": (1284, 2778),
}

IPAD_TARGETS = {
    "ipad_11": (2064, 2752),
    "ipad_12_9": (2048, 2732),
}

# Mac targets are always landscape (width > height)
MAC_TARGETS = {
    "mac_2560": (2560, 1600),
    "mac_2880": (2880, 1800),
}

# Common macOS screenshot widths (1x and 2x for standard resolutions)
MAC_WIDTHS = {1280, 1440, 1470, 1512, 1552, 1680, 1728, 1800, 1920,
              2560, 2880, 2940, 3024, 3104, 3360, 3456, 3600, 3840}


def detect_device(img: Image.Image) -> str:
    """Detect if screenshot is from iPhone, iPad, or Mac."""
    w, h = img.size
    # Mac screenshots are landscape with typical macOS resolutions
    if w > h and w in MAC_WIDTHS:
        return "mac"
    # Use portrait aspect ratio (narrower / taller)
    ratio = min(w, h) / max(w, h)
    # Mac: 16:10 = 0.625, iPad: ~0.69, iPhone: ~0.46
    # Landscape iPad is ~0.69 (still > 0.625), landscape iPhone is ~0.46
    if w > h and ratio <= 0.625:
        return "mac"
    # iPhone aspect ratios are ~0.46, iPad ~0.69+
    return "iphone" if ratio < 0.55 else "ipad"


def scale_and_crop(img: Image.Image, target_w: int, target_h: int) -> Image.Image:
    """Scale image to fill target dimensions (maintaining aspect ratio), then center-crop."""
    src_w, src_h = img.size

    # Match orientation: if source is landscape and target is portrait, swap target
    src_landscape = src_w > src_h
    tgt_landscape = target_w > target_h
    if src_landscape != tgt_landscape:
        target_w, target_h = target_h, target_w

    # Scale factor: fill both dimensions (use the larger scale)
    scale = max(target_w / src_w, target_h / src_h)
    new_w = round(src_w * scale)
    new_h = round(src_h * scale)

    img = img.resize((new_w, new_h), Image.LANCZOS)

    # Center-crop to exact target
    left = (new_w - target_w) // 2
    top = (new_h - target_h) // 2
    img = img.crop((left, top, left + target_w, top + target_h))

    return img


# Background color for macOS screenshots (matches app dark theme)
MAC_BG_COLOR = (26, 26, 46)


def scale_and_place_mac(img: Image.Image, target_w: int, target_h: int,
                        bg_color: tuple = MAC_BG_COLOR) -> Image.Image:
    """Scale macOS window screenshot to fit within target, centered on a solid background.

    Unlike iPhone screenshots (which fill and crop), macOS screenshots are
    typically window captures that should be displayed at a nice size on a
    solid background — not stretched or cropped.
    """
    src_w, src_h = img.size

    # Scale the window to fit inside the target with some padding (85% max)
    max_w = int(target_w * 0.85)
    max_h = int(target_h * 0.85)
    scale = min(max_w / src_w, max_h / src_h, 1.0)  # don't upscale
    new_w = round(src_w * scale)
    new_h = round(src_h * scale)

    if scale < 1.0:
        img = img.resize((new_w, new_h), Image.LANCZOS)

    # Center on background
    canvas = Image.new("RGB", (target_w, target_h), bg_color)
    x = (target_w - new_w) // 2
    y = (target_h - new_h) // 2

    # Handle alpha channel if present (macOS window screenshots have transparency)
    if img.mode == "RGBA":
        canvas.paste(img, (x, y), img)
    else:
        canvas.paste(img, (x, y))

    return canvas


def process_file(input_path: Path, output_dir: Path,
                  force_device: str | None = None,
                  mac_bg: tuple = MAC_BG_COLOR) -> int:
    """Process a single screenshot file, generating App Store sizes for the detected device."""
    img = Image.open(input_path)
    stem = input_path.stem
    device = force_device or detect_device(img)
    targets = {"iphone": IPHONE_TARGETS, "ipad": IPAD_TARGETS, "mac": MAC_TARGETS}[device]

    print(f"  {input_path.name} ({img.size[0]}x{img.size[1]}) [{device}]")

    for label, (tw, th) in targets.items():
        if device == "mac":
            result = scale_and_place_mac(img.copy(), tw, th, bg_color=mac_bg)
        else:
            result = scale_and_crop(img.copy(), tw, th)
        actual_w, actual_h = result.size
        out_name = f"{device}_{stem}_{label}_{actual_w}x{actual_h}.png"
        out_path = output_dir / out_name
        result.save(out_path, "PNG")
        print(f"    -> {out_name}")

    return len(targets)


def main():
    parser = argparse.ArgumentParser(description="Convert simulator screenshots to App Store sizes")
    parser.add_argument("inputs", nargs="+", help="Input PNG files or directories")
    parser.add_argument("--output", "-o", default=None, help="Output directory (default: <input_dir>/appstore/)")
    parser.add_argument("--device", "-d", choices=["iphone", "ipad", "mac"], default=None,
                        help="Force device type (skip auto-detection)")
    parser.add_argument("--mac-bg", default="1a1a2e",
                        help="Hex background color for macOS screenshots (default: 1a1a2e)")
    args = parser.parse_args()

    # Parse macOS background color
    hex_bg = args.mac_bg.lstrip("#")
    mac_bg = tuple(int(hex_bg[i:i+2], 16) for i in (0, 2, 4))

    # Collect input files
    files: list[Path] = []
    for inp in args.inputs:
        p = Path(inp)
        if p.is_dir():
            files.extend(sorted(p.glob("*.png")))
        elif p.is_file() and p.suffix.lower() == ".png":
            files.append(p)
        else:
            print(f"Skipping: {inp}")

    if not files:
        print("No PNG files found.")
        sys.exit(1)

    # Output directory
    if args.output:
        output_dir = Path(args.output)
    else:
        output_dir = files[0].parent / "appstore"
    output_dir.mkdir(parents=True, exist_ok=True)

    print(f"Processing {len(files)} screenshot(s) -> {output_dir}/\n")

    total = 0
    for f in files:
        total += process_file(f, output_dir, force_device=args.device, mac_bg=mac_bg)

    print(f"\nDone! {total} images saved to {output_dir}/")


if __name__ == "__main__":
    main()
