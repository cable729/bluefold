#!/usr/bin/env python3
"""Render the theme-probe page under all 10 concrete themes as a contact sheet.

Applies each theme's page-render filter (the SAME math as ThemedPDFPage.draw:
multiply / difference-invert / invert-then-screen) to a Quick Look render of
the probe page, frames each with the theme's chrome color + name, and tiles
them so every theme's page treatment can be compared side by side.

Prereq:  qlmanage -t -s 1600 -o /tmp/ql docs/theme-probe.pdf   (page render)
Run:     /tmp/.venv_pil/bin/python scripts/make-theme-contact-sheet.py
Out:     docs/theme-contact-sheet.png
"""
import os
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = "/tmp/ql/theme-probe.pdf.png"
OUT = os.path.join(HERE, "docs", "theme-contact-sheet.png")

def hx(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))

# (name, family, filter, tint, chromeTop, ink) — user's order.
THEMES = [
    ("Foldblue", "light", "multiply", "#F1E3CC", "#EADFC8", "#14385F"),
    ("Light", "light", "none", None, "#F2EBE2", "#0E2849"),
    ("Sepia", "light", "multiply", "#F5EDE1", "#EEE1CE", "#4A3A24"),
    ("Solarized Light", "light", "multiply", "#FDF6E3", "#EEE8D5", "#586E75"),
    ("Gruvbox Light", "light", "multiply", "#FBF1C7", "#EBDBB2", "#3C3836"),
    ("Bluefold", "dark", "invertTinted", "#0E2849", "#14294A", "#E3DEDA"),
    ("Dark", "dark", "invert", None, "#1A2C47", "#E3DEDA"),
    ("Gruvbox", "dark", "invertTinted", "#282828", "#3C3836", "#EBDBB2"),
    ("Solarized Dark", "dark", "invertTinted", "#002B36", "#073642", "#93A1A1"),
    ("Dracula", "dark", "invertTinted", "#282A36", "#44475A", "#F8F8F2"),
    ("Nord", "dark", "invertTinted", "#2E3440", "#3B4252", "#D8DEE9"),
]


def apply_filter(img, kind, tint_hex):
    img = img.convert("RGB")
    if kind == "none":
        return img
    r, g, b = img.split()
    if kind == "invert":
        f = lambda i: 255 - i
        return Image.merge("RGB", (r.point(f), g.point(f), b.point(f)))
    tint = hx(tint_hex)
    if kind == "multiply":
        chans = [c.point([int(i * t / 255) for i in range(256)])
                 for c, t in zip((r, g, b), tint)]
    else:  # invertTinted: invert, then screen the tint
        chans = [c.point([int(255 - i * (255 - t) / 255) for i in range(256)])
                 for c, t in zip((r, g, b), tint)]
    return Image.merge("RGB", chans)


def font(size):
    for path in ("/System/Library/Fonts/Helvetica.ttc",
                 "/System/Library/Fonts/Supplemental/Arial.ttf"):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def build():
    base = Image.open(BASE)
    thumb_w = 320
    thumb_h = int(base.height * thumb_w / base.width)
    bar = 30
    pad = 16
    cols, rows = 4, 3
    cw, ch = thumb_w, thumb_h + bar
    sheet_w = cols * cw + (cols + 1) * pad
    sheet_h = rows * ch + (rows + 1) * pad + 40
    sheet = Image.new("RGB", (sheet_w, sheet_h), (245, 245, 245))
    d = ImageDraw.Draw(sheet)
    d.text((pad, 12), "Bluefold theme probe — page filter under each theme",
           fill=(30, 30, 30), font=font(20))

    for i, (name, fam, kind, tint, chrome, ink) in enumerate(THEMES):
        col, row = i % cols, i // cols
        x = pad + col * (cw + pad)
        y = 40 + pad + row * (ch + pad)
        page = apply_filter(base, kind, tint).resize((thumb_w, thumb_h))
        card = Image.new("RGB", (cw, ch), hx(chrome))
        card.paste(page, (0, bar))
        cd = ImageDraw.Draw(card)
        cd.text((8, 8), name, fill=hx(ink), font=font(14))
        cd.text((cw - 46, 10), fam.upper(), fill=hx(ink), font=font(9))
        sheet.paste(card, (x, y))
        d.rectangle([x, y, x + cw - 1, y + ch - 1], outline=(180, 180, 180))

    sheet.save(OUT)
    print("wrote", OUT, sheet.size)


if __name__ == "__main__":
    build()
