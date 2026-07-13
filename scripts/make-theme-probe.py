#!/usr/bin/env python3
"""Generate a canonical Bluefold theme-probe PDF.

One reference document that exercises every page element that reacts to a
theme's page-render filter (invert / tint) and to LinkBoxColorizer — so we can
open it under each of the 11 themes and see exactly how each part transforms.

Mirrors the real Calibre library (Axler LADR etc.): LaTeX tcolorbox theorem
boxes, hyperref link boxes, colored cross-ref text, math, a color figure.

Run:  /tmp/.venv_pil/bin/python scripts/make-theme-probe.py
Out:  docs/theme-probe.pdf
"""
import colorsys
import math
import os

from PIL import Image
from reportlab.lib.pagesizes import letter
from reportlab.lib.units import inch
from reportlab.pdfgen import canvas
from reportlab.lib.colors import Color, HexColor

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(HERE, "docs", "theme-probe.pdf")
IMG = "/tmp/theme-probe-phase.png"

PAGE_W, PAGE_H = letter
MARGIN = 0.75 * inch


def make_phase_image(path, size=360):
    """A domain-coloring / phase-portrait wheel: hue = angle, brightness
    ripples with radius. Colorful photo-like content — the case where a
    difference-invert produces garish results worth seeing."""
    img = Image.new("RGB", (size, size), "white")
    px = img.load()
    c = size / 2
    for y in range(size):
        for x in range(size):
            dx, dy = (x - c) / c, (y - c) / c
            r = math.hypot(dx, dy)
            if r > 1:
                px[x, y] = (255, 255, 255)
                continue
            ang = (math.atan2(dy, dx) / (2 * math.pi)) % 1.0
            val = 0.5 + 0.5 * abs(math.sin(6 * math.pi * r))
            sat = 0.85
            rr, gg, bb = colorsys.hsv_to_rgb(ang, sat, val)
            px[x, y] = (int(rr * 255), int(gg * 255), int(bb * 255))
    img.save(path)


def box(c, x, y, w, h, title, body_lines, title_bg, body_bg, border,
        title_fg, body_fg):
    """A tcolorbox-style theorem container: title band + body, rounded, bordered."""
    title_h = 26
    c.setFillColor(body_bg)
    c.setStrokeColor(border)
    c.setLineWidth(1.2)
    c.roundRect(x, y - h, w, h, 8, stroke=1, fill=1)
    # title band (clipped-ish: a filled rect across the top)
    c.setFillColor(title_bg)
    c.roundRect(x, y - title_h, w, title_h, 8, stroke=0, fill=1)
    c.setFillColor(title_bg)
    c.rect(x, y - title_h, w, title_h - 8, stroke=0, fill=1)
    c.setStrokeColor(border)
    c.line(x, y - title_h, x + w, y - title_h)
    c.setFillColor(title_fg)
    c.setFont("Times-BoldItalic", 12)
    c.drawString(x + 12, y - 18, title)
    c.setFillColor(body_fg)
    c.setFont("Times-Roman", 12)
    ty = y - title_h - 18
    for line in body_lines:
        c.drawString(x + 12, ty, line)
        ty -= 18
    return h


def swatch_strip(c, x, y, w):
    cells = [
        ("white", HexColor("#FFFFFF")), ("black", HexColor("#000000")),
        ("red", HexColor("#E03131")), ("green", HexColor("#2F9E44")),
        ("blue", HexColor("#1971C2")), ("cyan", HexColor("#0CA6C2")),
        ("magenta", HexColor("#C2255C")), ("yellow", HexColor("#F2C200")),
        ("paper", HexColor("#FEFEFD")), ("ink", HexColor("#2A2620")),
    ]
    cw = w / len(cells)
    for i, (name, col) in enumerate(cells):
        cx = x + i * cw
        c.setFillColor(col)
        c.setStrokeColor(HexColor("#999999"))
        c.setLineWidth(0.5)
        c.rect(cx, y - 34, cw - 3, 34, stroke=1, fill=1)
        c.setFillColor(HexColor("#000000") if name in
                       ("white", "yellow", "paper", "cyan") else HexColor("#FFFFFF"))
        c.setFont("Helvetica", 7)
        c.drawCentredString(cx + (cw - 3) / 2, y - 20, name)


def mark(c, key, title, level, y):
    """Bookmark a position on the current page + add an outline entry, so the
    reader's Contents sidebar shows a real multi-level tree."""
    c.bookmarkHorizontalAbsolute(key, y + 12)
    c.addOutlineEntry(title, key, level=level, closed=0)


def header(c, page_no):
    c.setFillColor(HexColor("#000000"))
    c.setFont("Times-Roman", 10)
    c.drawString(MARGIN, PAGE_H - MARGIN + 8, "186   Chapter 6   Inner Product Spaces")
    c.drawRightString(PAGE_W - MARGIN, PAGE_H - MARGIN + 8, f"Bluefold theme probe · p.{page_no}")
    c.setStrokeColor(HexColor("#000000"))
    c.setLineWidth(0.6)
    c.line(MARGIN, PAGE_H - MARGIN + 2, PAGE_W - MARGIN, PAGE_H - MARGIN + 2)


def build():
    make_phase_image(IMG)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    c = canvas.Canvas(OUT, pagesize=letter)
    contentW = PAGE_W - 2 * MARGIN

    # ---- Page 1 ----
    header(c, 1)
    y = PAGE_H - MARGIN - 20
    mark(c, "ch6", "Chapter 6 — Inner Product Spaces", 0, y)
    mark(c, "s6a", "6A. Inner Products and Norms", 1, y)
    c.setFillColor(HexColor("#000000"))
    c.setFont("Times-Italic", 20)
    c.drawString(MARGIN, y, "Norms")
    mark(c, "norms", "Norms", 2, y)
    y -= 26
    c.setFont("Times-Roman", 12)
    for line in [
        "Body text on white paper. Each inner product determines a norm; working with",
        "norms squared is usually easier than working directly with the norms themselves.",
    ]:
        c.drawString(MARGIN, y, line)
        y -= 17
    y -= 12

    # Colored theorem containers — the elements the owner flagged.
    mark(c, "d67", "6.7  Definition: norm", 2, y)
    y -= box(c, MARGIN, y, contentW, 66, "6.7   definition: norm",
             ["For v in V, the norm of v, denoted ||v||, is defined by",
              "     ||v|| = sqrt(<v, v>)."],
             HexColor("#2C4B8E"), HexColor("#E8EDF6"), HexColor("#2C4B8E"),
             HexColor("#FFFFFF"), HexColor("#12233F")) + 16

    mark(c, "d69", "6.9  Basic properties of the norm", 2, y)
    y -= box(c, MARGIN, y, contentW, 84, "6.9   basic properties of the norm",
             ["Suppose v in V.",
              "(a)  ||v|| = 0 if and only if v = 0.",
              "(b)  ||λv|| = |λ| ||v|| for all λ in F."],
             HexColor("#8A7B5C"), HexColor("#EFE9DC"), HexColor("#8A7B5C"),
             HexColor("#FFFFFF"), HexColor("#2A2114")) + 16

    mark(c, "d610", "6.10  Definition: orthogonal", 2, y)
    y -= box(c, MARGIN, y, contentW, 48, "6.10   definition: orthogonal",
             ["Two vectors u, v in V are called orthogonal if <u, v> = 0."],
             HexColor("#E8D44D"), HexColor("#FBF6D0"), HexColor("#C9B94A"),
             HexColor("#3A3410"), HexColor("#2A2610")) + 16

    mark(c, "d611", "6.11  Orthogonality and 0", 2, y)
    y -= box(c, MARGIN, y, contentW, 66, "6.11   orthogonality and 0",
             ["(a)  0 is orthogonal to every vector in V.",
              "(b)  0 is the only vector in V orthogonal to itself."],
             HexColor("#7A8290"), HexColor("#E6E9EE"), HexColor("#7A8290"),
             HexColor("#FFFFFF"), HexColor("#20242B")) + 16

    mark(c, "d612", "6.12  Pythagorean theorem", 2, y)
    y -= box(c, MARGIN, y, contentW, 48, "6.12   Pythagorean theorem (green)",
             ["Suppose u, v in V. If u and v are orthogonal, then ||u+v||^2 = ||u||^2 + ||v||^2."],
             HexColor("#3F7A5A"), HexColor("#E4F0E9"), HexColor("#3F7A5A"),
             HexColor("#FFFFFF"), HexColor("#16261D")) + 20

    # Links: a hyperref-style RED boxed cross-ref + a blue colored-text ref.
    c.setFillColor(HexColor("#000000"))
    c.setFont("Times-Roman", 12)
    c.drawString(MARGIN, y, "Cross-references: see ")
    lx = MARGIN + c.stringWidth("Cross-references: see ", "Times-Roman", 12)
    label = "Thm 2.5"
    lw = c.stringWidth(label, "Times-Roman", 12)
    c.setFillColor(HexColor("#000000"))
    c.drawString(lx, y, label)
    # A REAL hyperref-style Link ANNOTATION with a red border (not a content
    # rectangle) — this is what LinkBoxColorizer recolors to the theme accent.
    c.linkURL("https://example.com/thm", (lx - 2, y - 3, lx + lw + 2, y + 13),
              thickness=1.2, color=HexColor("#E0301E"))
    rest_x = lx + lw + 6
    c.drawString(rest_x, y, "and the colored ref ")
    bx = rest_x + c.stringWidth("and the colored ref ", "Times-Roman", 12)
    c.setFillColor(HexColor("#1971C2"))  # colorlinks=true blue text
    c.drawString(bx, y, "§4.1")
    c.setFillColor(HexColor("#000000"))
    c.drawString(bx + c.stringWidth("§4.1", "Times-Roman", 12), y, ".")
    y -= 30

    # Pure-color swatch strip: read the filter's exact color mapping.
    c.setFillColor(HexColor("#000000"))
    c.setFont("Times-Italic", 11)
    c.drawString(MARGIN, y, "Color swatches (how the filter maps pure colors):")
    y -= 8
    swatch_strip(c, MARGIN, y, contentW)

    c.showPage()

    # ---- Page 2: color figure + table ----
    header(c, 2)
    y = PAGE_H - MARGIN - 10
    mark(c, "figs", "Figures and tables", 1, y)
    mark(c, "phase", "Phase-portrait figure", 2, y)
    c.setFillColor(HexColor("#000000"))
    c.setFont("Times-Italic", 14)
    c.drawString(MARGIN, y, "Color figure (phase portrait) — how images survive the filter")
    y -= 12
    img_w = 3.2 * inch
    c.drawImage(IMG, MARGIN, y - img_w, img_w, img_w)
    c.setFont("Times-Roman", 11)
    c.drawString(MARGIN + img_w + 20, y - 40,
                 "A domain-coloring image like the")
    c.drawString(MARGIN + img_w + 20, y - 56,
                 "phase portraits in Visual Complex")
    c.drawString(MARGIN + img_w + 20, y - 72,
                 "Functions. Under a dark (invert)")
    c.drawString(MARGIN + img_w + 20, y - 88,
                 "theme, photographic color inverts")
    c.drawString(MARGIN + img_w + 20, y - 104,
                 "to its complement — worth seeing.")
    y -= img_w + 30

    # Table with a colored header row.
    mark(c, "table", "Norm table", 2, y)
    c.setFont("Times-Italic", 12)
    c.drawString(MARGIN, y, "Table with a colored header row:")
    y -= 18
    rows = [["n", "norm", "squared"], ["1", "1.00", "1.00"],
            ["2", "1.41", "2.00"], ["3", "1.73", "3.00"]]
    col_w = contentW / 3
    rh = 22
    for ri, row in enumerate(rows):
        ry = y - ri * rh
        if ri == 0:
            c.setFillColor(HexColor("#2C4B8E"))
            c.rect(MARGIN, ry - rh, contentW, rh, stroke=0, fill=1)
            c.setFillColor(HexColor("#FFFFFF"))
            c.setFont("Times-Bold", 11)
        else:
            c.setFillColor(HexColor("#F2F0EB") if ri % 2 else HexColor("#FFFFFF"))
            c.rect(MARGIN, ry - rh, contentW, rh, stroke=0, fill=1)
            c.setFillColor(HexColor("#000000"))
            c.setFont("Times-Roman", 11)
        for ci, cell in enumerate(row):
            c.drawString(MARGIN + ci * col_w + 8, ry - 15, cell)
    c.setStrokeColor(HexColor("#CCCCCC"))
    c.setLineWidth(0.5)
    c.rect(MARGIN, y - rh * len(rows), contentW, rh * len(rows), stroke=1, fill=0)

    c.showPage()
    c.save()
    print("wrote", OUT)


if __name__ == "__main__":
    build()
