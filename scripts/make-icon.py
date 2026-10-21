#!/usr/bin/env python3
"""Render the app icon: dark squircle (panel palette, Theme.swift), the
menu-bar mark (SessionsMark.swift: three session rows) with each row's dot in a
state colour — waiting (orange), working (green), finished (blue check).

    python3 scripts/make-icon.py            # → assets/AppIcon.icns (+ AppIcon-1024.png)
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets"
S = 4                      # supersampling
N = 1024 * S

INK = (232, 239, 237)      # Theme.ink
GO = (52, 211, 153)        # Theme.go
DONE = (96, 165, 250)      # Theme.finished
WAIT = (255, 159, 10)      # Theme.waiting
TOP = (30, 40, 43)
BOTTOM = (11, 16, 18)      # ~ panelScrim #0F1416


def squircle_mask(size, inset, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle((inset, inset, size - inset, size - inset), radius, fill=255)
    return m


def render():
    inset, radius = 100 * S, 185 * S          # macOS 824 pt body on the 1024 grid
    canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))

    # Drop shadow under the body.
    shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((inset, inset + 12 * S, N - inset, N - inset + 12 * S),
                                             radius, fill=(0, 0, 0, 110))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18 * S)))

    # Body: vertical gradient + faint teal glow at the top.
    body = Image.new("RGBA", (N, N))
    d = ImageDraw.Draw(body)
    for y in range(N):
        t = y / N
        d.line((0, y, N, y), fill=tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)) + (255,))
    glow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((N * .18, -N * .25, N * .82, N * .38), fill=(47, 230, 200, 38))
    body.alpha_composite(glow.filter(ImageFilter.GaussianBlur(60 * S)))
    mask = squircle_mask(N, inset, radius)
    canvas.paste(body, (0, 0), mask)

    # Hairline border (white .12).
    ImageDraw.Draw(canvas).rounded_rectangle((inset, inset, N - inset, N - inset), radius,
                                             outline=(255, 255, 255, 34), width=3 * S)

    # The mark on its 24-unit grid (SessionsMarkShape), each dot in a state colour.
    d = ImageDraw.Draw(canvas)
    unit = 24 * S
    ox, oy = N / 2 - 12 * unit, N / 2 - 12 * unit + 8 * S
    rows = ((5, 22, WAIT), (12, 18, GO), (19, 20.5, DONE))
    dot_r, bar_h = 2.4, 3.6
    for y, bar_end, color in rows:
        cx, cy = ox + 4.2 * unit, oy + y * unit
        r = dot_r * unit
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=color)
        d.rounded_rectangle((ox + 9 * unit, oy + (y - bar_h / 2) * unit, ox + bar_end * unit, oy + (y + bar_h / 2) * unit),
                            radius=bar_h / 2 * unit, fill=INK)
        if color == DONE:                                # finished → check
            w = 11 * S
            d.line(((cx - 20 * S, cy + 1 * S), (cx - 6 * S, cy + 15 * S), (cx + 20 * S, cy - 14 * S)),
                   fill=BOTTOM, width=w, joint="curve")

    return canvas.resize((1024, 1024), Image.LANCZOS)


def main():
    OUT.mkdir(exist_ok=True)
    big = render()
    big.save(OUT / "AppIcon-1024.png")
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for pt in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                px = pt * scale
                name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
                big.resize((px, px), Image.LANCZOS).save(iconset / name)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT / "AppIcon.icns")], check=True)
    print(OUT / "AppIcon.icns")


if __name__ == "__main__":
    sys.exit(main())
