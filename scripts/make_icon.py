#!/usr/bin/env python3
"""Draws the app icon and writes Resources/AppIcon.icns (needs Pillow).

Usage: python3 scripts/make_icon.py [output.icns]
"""
import sys
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SCALE = 4  # supersample for smooth edges


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def draw_icon() -> Image.Image:
    s = SIZE * SCALE
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    # macOS-style tile: 824 px rounded square centred on a 1024 canvas.
    margin = 100 * SCALE
    tile = (margin, margin, s - margin, s - margin)
    radius = 185 * SCALE

    # Soft shadow under the tile.
    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (tile[0], tile[1] + 12 * SCALE, tile[2], tile[3] + 12 * SCALE), radius, fill=(0, 0, 0, 90)
    )
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18 * SCALE)))

    # Vertical gradient: deep indigo to teal.
    gradient = Image.new("RGBA", (s, s))
    top, bottom = (30, 41, 110), (8, 145, 178)
    gd = ImageDraw.Draw(gradient)
    for y in range(s):
        gd.line([(0, y), (s, y)], fill=lerp(top, bottom, y / s) + (255,))
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle(tile, radius, fill=255)
    img.paste(gradient, (0, 0), mask)

    d = ImageDraw.Draw(img)

    # Phone outline (tall, like an Xperia's 21:9 screen).
    cx = s // 2
    pw, ph = 330 * SCALE, 600 * SCALE
    phone = (cx - pw // 2, s // 2 - ph // 2, cx + pw // 2, s // 2 + ph // 2)
    d.rounded_rectangle(phone, 52 * SCALE, fill=(15, 23, 42, 255), outline=(241, 245, 249, 255), width=22 * SCALE)

    # Circular "restore" arrow inside the screen.
    r = 105 * SCALE
    cy = s // 2 - 10 * SCALE
    box = (cx - r, cy - r, cx + r, cy + r)
    start_deg, end_deg = -40, 215
    d.arc(box, start=start_deg, end=end_deg, fill=(56, 189, 248, 255), width=30 * SCALE)
    # Arrow head at the arc's end, pointing along the (clockwise) direction of travel.
    theta = math.radians(end_deg)
    ex, ey = cx + r * math.cos(theta), cy + r * math.sin(theta)
    tx, ty = -math.sin(theta), math.cos(theta)  # tangent
    nx, ny = math.cos(theta), math.sin(theta)  # radial normal
    length, half_width = 70 * SCALE, 48 * SCALE
    d.polygon(
        [
            (ex + tx * length, ey + ty * length),
            (ex + nx * half_width - tx * 6 * SCALE, ey + ny * half_width - ty * 6 * SCALE),
            (ex - nx * half_width - tx * 6 * SCALE, ey - ny * half_width - ty * 6 * SCALE),
        ],
        fill=(56, 189, 248, 255),
    )

    # Lightning bolt (flash mode) in the middle of the arrow.
    b = SCALE
    bolt = [
        (cx + 18 * b, cy - 78 * b),
        (cx - 46 * b, cy + 14 * b),
        (cx - 4 * b, cy + 14 * b),
        (cx - 22 * b, cy + 82 * b),
        (cx + 46 * b, cy - 14 * b),
        (cx + 4 * b, cy - 14 * b),
    ]
    d.polygon(bolt, fill=(251, 191, 36, 255))

    # Small speaker slot at the top of the phone.
    d.rounded_rectangle((cx - 40 * b, phone[1] + 46 * b, cx + 40 * b, phone[1] + 60 * b), 7 * b, fill=(71, 85, 105, 255))

    return img.resize((SIZE, SIZE), Image.LANCZOS)


def main() -> None:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "Resources" / "AppIcon.icns")
    icon = draw_icon()
    out.parent.mkdir(parents=True, exist_ok=True)
    icon.save(out, format="ICNS", sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
    icon.save(out.with_suffix(".png"))
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
