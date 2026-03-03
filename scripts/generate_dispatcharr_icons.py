#!/usr/bin/env python3
from pathlib import Path
import argparse
import re

import numpy as np
from PIL import Image, ImageDraw, ImageFilter


BG_TOP = np.array([0x31, 0x5C, 0x88], dtype=np.float32)
BG_MID = np.array([0x1B, 0x3F, 0x5F], dtype=np.float32)
BG_BOT = np.array([0x0D, 0x16, 0x0F], dtype=np.float32)

# Chrome palette for TV frame
CHROME_DARK = np.array([0x1E, 0x22, 0x26], dtype=np.float32)
CHROME_MID = np.array([0x6B, 0x73, 0x7A], dtype=np.float32)
CHROME_LIGHT = np.array([0xC8, 0xD0, 0xD8], dtype=np.float32)
CHROME_EDGE = np.array([0x99, 0xA3, 0xAC], dtype=np.float32)

SCREEN_TOP = np.array([0x2B, 0x4D, 0x73], dtype=np.float32)
SCREEN_BOT = np.array([0x14, 0x2A, 0x43], dtype=np.float32)
PLAY_TOP = np.array([0x97, 0xFF, 0xD7], dtype=np.float32)
PLAY_BOT = np.array([0x53, 0xF2, 0xA4], dtype=np.float32)
ANT = (0x7A, 0x8F, 0x89)
ANT_DOT = (0x8E, 0xFF, 0xC9)
REC = (0xFF, 0x5A, 0x5A)
INNER = (0x0F, 0x15, 0x17)


def rounded_mask(size, rect, radius):
    m = Image.new('L', size, 0)
    ImageDraw.Draw(m).rounded_rectangle(rect, radius=radius, fill=255)
    return m


def bg_gradient(w, h):
    y = np.linspace(0, 1, h, dtype=np.float32)
    arr = np.zeros((h, w, 3), dtype=np.float32)
    split = 0.50
    for i, yy in enumerate(y):
        if yy <= split:
            t = yy / split
            c = BG_TOP * (1 - t) + BG_MID * t
        else:
            t = (yy - split) / (1 - split)
            c = BG_MID * (1 - t) + BG_BOT * t
        arr[i, :, :] = c

    xx = np.linspace(-1, 1, w, dtype=np.float32)
    yy = np.linspace(-1, 1, h, dtype=np.float32)
    X, Y = np.meshgrid(xx, yy)

    R = np.sqrt((X * 0.85 - 0.0) ** 2 + (Y + 1.05) ** 2)
    glow = np.clip(1 - R / 1.9, 0, 1)
    arr += glow[..., None] * 20

    R2 = np.sqrt((X) ** 2 + (Y * 1.15) ** 2)
    vig = np.clip((R2 - 0.55) / 0.9, 0, 1)
    arr *= (1 - 0.16 * vig[..., None])

    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), 'RGB')


def apply_glass(img, strength=0.12):
    w, h = img.size
    base = np.array(img).astype(np.float32)
    xx = np.linspace(-1, 1, w, dtype=np.float32)
    yy = np.linspace(-1, 1, h, dtype=np.float32)
    X, Y = np.meshgrid(xx, yy)
    R = np.sqrt((X + 0.55) ** 2 + (Y + 0.8) ** 2)
    g = np.clip(1 - R / 1.95, 0, 1)
    a = strength * g
    out = base * (1 - a[..., None]) + 255 * a[..., None]
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), 'RGB')


def chrome_fill(w, h):
    yy = np.linspace(0, 1, h, dtype=np.float32)[:, None]
    xx = np.linspace(0, 1, w, dtype=np.float32)[None, :]

    # Base metallic gradient + slight diagonal component
    t = 0.70 * yy + 0.30 * xx
    c = np.zeros((h, w, 3), dtype=np.float32)
    m = t < 0.45
    tt = np.zeros_like(t)
    tt[m] = t[m] / 0.45
    c[m] = CHROME_DARK * (1 - tt[m, None]) + CHROME_MID * tt[m, None]
    tt[~m] = (t[~m] - 0.45) / 0.55
    c[~m] = CHROME_MID * (1 - tt[~m, None]) + CHROME_LIGHT * tt[~m, None]

    # Specular bands (classic chrome look)
    band1 = np.exp(-((yy - 0.18) / 0.06) ** 2)
    band2 = np.exp(-((yy - 0.34) / 0.045) ** 2)
    band3 = np.exp(-((yy - 0.62) / 0.08) ** 2)
    spec = (0.22 * band1 + 0.12 * band2 + 0.08 * band3)
    c += spec[..., None] * 255

    return Image.fromarray(np.clip(c, 0, 255).astype(np.uint8), 'RGB')


def draw_scanlines(img, x1, y1, x2, y2, step, width):
    w, h = img.size
    ov = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    base = np.array([0x8C, 0xA8, 0xC7], dtype=np.float32)
    ys = list(range(int(y1), int(y2), max(1, int(step))))
    n = max(1, len(ys) - 1)

    for i, y in enumerate(ys):
        t = i / n
        alpha = int(34 + 62 * (1.0 - abs(2 * t - 1)) + 22 * np.sin((i * 0.9)))
        alpha = max(22, min(110, alpha))
        drift = int(2 * np.sin(i * 0.55) + np.sin(i * 0.23))
        tone = base * (0.86 + 0.24 * (1.0 - t))
        color = (int(tone[0]), int(tone[1]), int(tone[2]), alpha)
        d.line((x1 + drift, y, x2 + drift, y), fill=color, width=max(1, int(width)))

    # Film-like grain between scan lines to avoid a flat digital look.
    grain_count = max(220, int((x2 - x1) * (y2 - y1) / 140))
    for _ in range(grain_count):
        gx = np.random.randint(int(x1), int(x2))
        gy = np.random.randint(int(y1), int(y2))
        g = np.random.randint(108, 176)
        a = np.random.randint(8, 28)
        ov.putpixel((gx, gy), (g, g + np.random.randint(-6, 8), g + np.random.randint(4, 18), a))

    ov = ov.filter(ImageFilter.GaussianBlur(radius=max(0.6, width * 0.35)))
    return Image.alpha_composite(img.convert('RGBA'), ov).convert('RGB')


def draw_scene(w, h, center_x_ratio=0.5):
    img = bg_gradient(w, h)
    img = apply_glass(img, 0.10)
    draw = ImageDraw.Draw(img)

    s = h / 512.0
    cx = int(round(w * center_x_ratio))
    ox = cx - int(round(256 * s))
    oy = 0

    def X(v):
        return ox + v * s

    def Y(v):
        return oy + v * s

    def Rv(v):
        return max(1.0, v * s)

    lw_ant = int(round(Rv(7)))
    draw.line((X(194), Y(138), X(152), Y(80)), fill=ANT, width=max(1, lw_ant))
    draw.line((X(318), Y(138), X(360), Y(80)), fill=ANT, width=max(1, lw_ant))
    rdot = Rv(6)
    draw.ellipse((X(152) - rdot, Y(80) - rdot, X(152) + rdot, Y(80) + rdot), fill=ANT_DOT)
    draw.ellipse((X(360) - rdot, Y(80) - rdot, X(360) + rdot, Y(80) + rdot), fill=ANT_DOT)

    sh = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sh)
    sd.rounded_rectangle((X(92), Y(148), X(420), Y(400)), radius=Rv(34), fill=(0, 0, 0, 120))
    sh = sh.filter(ImageFilter.GaussianBlur(radius=Rv(11)))
    img = Image.alpha_composite(img.convert('RGBA'), sh).convert('RGB')

    chrome = chrome_fill(w, h)
    shell_mask = rounded_mask((w, h), (X(92), Y(138), X(420), Y(390)), Rv(34))
    img.paste(chrome, mask=shell_mask)
    draw = ImageDraw.Draw(img)

    draw.rounded_rectangle(
        (X(92), Y(138), X(420), Y(390)),
        radius=Rv(34),
        outline=tuple(CHROME_EDGE.astype(int)),
        width=max(1, int(round(Rv(2.2))))
    )

    draw.rounded_rectangle((X(116), Y(162), X(396), Y(366)), radius=Rv(18), fill=INNER)

    ys = np.linspace(0, 1, h, dtype=np.float32)[:, None]
    scr = (SCREEN_TOP * (1 - ys) + SCREEN_BOT * ys).astype(np.uint8)
    scr = np.repeat(scr[:, None, :], w, axis=1)
    screen = Image.fromarray(scr, 'RGB')
    screen_mask = rounded_mask((w, h), (X(128), Y(174), X(384), Y(354)), Rv(12))
    img.paste(screen, mask=screen_mask)

    img = draw_scanlines(
        img,
        X(132), Y(194), X(380), Y(321),
        step=max(1, Rv(16)),
        width=max(1, Rv(1.9))
    )

    img = apply_glass(img, 0.045)
    draw = ImageDraw.Draw(img)

    draw.polygon([(X(234), Y(226)), (X(234), Y(304)), (X(304), Y(265))], fill=tuple(PLAY_BOT.astype(int)))
    draw.polygon([(X(242), Y(236)), (X(242), Y(294)), (X(295), Y(265))], fill=tuple(PLAY_TOP.astype(int)))

    rr = Rv(8.5)
    draw.ellipse((X(360) - rr, Y(190) - rr, X(360) + rr, Y(190) + rr), fill=REC)

    return img


def render_ssaa(w, h, center_x_ratio=0.5, ss=4):
    hi = draw_scene(w * ss, h * ss, center_x_ratio=center_x_ratio)
    lo = hi.resize((w, h), Image.Resampling.LANCZOS)
    lo = lo.filter(ImageFilter.UnsharpMask(radius=0.7, percent=80, threshold=1))
    return lo


def main():
    parser = argparse.ArgumentParser(description='Generate DispatcherPVR app/tv icon and top shelf assets.')
    parser.add_argument(
        '--assets-root',
        default='/Users/jfdufour/git-repositories/NexusPVR/DispatcherPVR/Assets.xcassets',
        help='Path to Assets.xcassets root'
    )
    parser.add_argument('--ssaa', type=int, default=4, help='Supersampling factor (default: 4)')
    args = parser.parse_args()

    root = Path(args.assets_root)
    icon_files = sorted(set(
        list((root / 'AppIcon.appiconset').glob('*.png')) +
        [p for p in (root / 'tv.brandassets').rglob('icon_*.png') if 'App Icon' in str(p)]
    ))
    shelf_files = sorted((root / 'tv.brandassets').rglob('shelf_*.png'))

    for p in icon_files:
        with Image.open(p) as im:
            w, h = im.size
        render_ssaa(w, h, center_x_ratio=0.5, ss=args.ssaa).save(p, format='PNG', optimize=True)

    for p in shelf_files:
        m = re.search(r'shelf(?:_wide)?_(\d+)x(\d+)\.png$', p.name)
        if not m:
            continue
        w, h = int(m.group(1)), int(m.group(2))
        render_ssaa(w, h, center_x_ratio=0.5, ss=args.ssaa).save(p, format='PNG', optimize=True)

    print(f'UPDATED {len(icon_files)} icon-layer files + {len(shelf_files)} shelf files (chrome frame)')


if __name__ == '__main__':
    main()
