#!/usr/bin/env python3
# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""Generate the tray's status icons.

    tools/make-icons.py            # writes share/icons/hicolor/{scalable,16x16}/status
    tools/make-icons.py --ascii    # also prints each icon at 16px, for the eye

The shield is Timeshift's own: the path from src/share/timeshift/images/
timeshift-shield-*.svg scaled onto a 16px grid, filled solid, with the state
cut out of it as a white glyph -- the device the brand shields use. Two sets
come out of the same geometry:

  timeshift-tray-<state>-symbolic   one colour, recoloured by the panel
  timeshift-tray-<state>            the brand colours, for when it must be seen

Everything is a filled path with the evenodd rule and nothing else. No
strokes: GTK recolours a symbolic icon by forcing `fill` on every shape and
leaves `stroke` alone, so an outlined shield would come back solid. No masks
or clipPaths: QtSvg, which Plasma renders through, does not implement them.

The badges on warning and error overlap the shield with a one-pixel halo so
they read as a separate shape when everything is one colour. A halo is a hole,
and a hole in a single-colour icon can only be made by parity -- but a circle
cut out with evenodd is a hole only where it lies INSIDE the shield and a
filled disc where it lies outside. So the halo is the intersection of the
shield polygon and the halo shape, computed here by Sutherland-Hodgman, which
is why this is a script and not five hand-written files.
"""

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SCALABLE = os.path.join(ROOT, "share/icons/hicolor/scalable/status")
PNG16 = os.path.join(ROOT, "share/icons/hicolor/16x16/status")

# --- the brand shield ----------------------------------------------------------

# Cubic segments of the 64px brand shield, top centre first, clockwise.
# (from timeshift-shield-high.svg: m 32 8 c ... z)
_BRAND = [
    ((32, 8), (45.846, 8.001), (52, 14.711), (52, 14.711)),
    ((52, 14.711), (52, 32.283), (52, 32.283), (52, 32.283)),
    ((52, 32.283), (52, 48.393), (32, 55.865), (32, 55.865)),
    ((32, 55.865), (12, 48.395), (12, 32.283), (12, 32.283)),
    ((12, 32.283), (12, 14.711), (12, 14.711), (12, 14.711)),
    ((12, 14.711), (12, 14.711), (18.154, 8.001), (32, 8)),
]

SCALE = 0.3
TX, TY = -1.6, -1.6      # 40x48 -> 12x14.4, centred, top at y=0.8


def _bez(p0, p1, p2, p3, t):
    u = 1 - t
    return (u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
            u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1])


def shield_polygon(inset=0.0, steps=12):
    """The shield as a closed polygon in 16px units, optionally inset."""
    pts = []
    for p0, p1, p2, p3 in _BRAND:
        for i in range(steps):
            x, y = _bez(p0, p1, p2, p3, i / steps)
            pts.append((x * SCALE + TX, y * SCALE + TY))
    if inset:
        cx = sum(p[0] for p in pts) / len(pts)
        cy = sum(p[1] for p in pts) / len(pts)
        w = max(p[0] for p in pts) - min(p[0] for p in pts)
        h = max(p[1] for p in pts) - min(p[1] for p in pts)
        fx = 1 - 2 * inset / w
        fy = 1 - 2 * inset / h
        pts = [(cx + (x - cx) * fx, cy + (y - cy) * fy) for x, y in pts]
    return pts


def circle(cx, cy, r, n=40):
    return [(cx + r * math.cos(2 * math.pi * i / n),
             cy + r * math.sin(2 * math.pi * i / n)) for i in range(n)]


def rect(x0, y0, x1, y1):
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


def rotated_rect(cx, cy, length, width, degrees):
    a = math.radians(degrees)
    ux, uy = math.cos(a) * length / 2, math.sin(a) * length / 2
    vx, vy = -math.sin(a) * width / 2, math.cos(a) * width / 2
    return [(cx - ux - vx, cy - uy - vy), (cx + ux - vx, cy + uy - vy),
            (cx + ux + vx, cy + uy + vy), (cx - ux + vx, cy - uy + vy)]


def scaled_about(poly, cx, cy, factor):
    return [(cx + (x - cx) * factor, cy + (y - cy) * factor) for x, y in poly]


def clip(subject, clipper):
    """Sutherland-Hodgman: subject polygon clipped to a CONVEX clipper.

    Both wound consistently; the clipper's winding is detected so the caller
    need not care.
    """
    def area(p):
        return sum(p[i][0] * p[(i + 1) % len(p)][1] - p[(i + 1) % len(p)][0] * p[i][1]
                   for i in range(len(p))) / 2

    sign = 1 if area(clipper) > 0 else -1

    def inside(pt, a, b):
        return sign * ((b[0] - a[0]) * (pt[1] - a[1]) - (b[1] - a[1]) * (pt[0] - a[0])) >= 0

    def intersect(p, q, a, b):
        dx, dy = q[0] - p[0], q[1] - p[1]
        ex, ey = b[0] - a[0], b[1] - a[1]
        den = dx * ey - dy * ex
        if abs(den) < 1e-12:
            return q
        t = ((a[0] - p[0]) * ey - (a[1] - p[1]) * ex) / den
        return (p[0] + t * dx, p[1] + t * dy)

    out = list(subject)
    for i in range(len(clipper)):
        a, b = clipper[i], clipper[(i + 1) % len(clipper)]
        inp, out = out, []
        if not inp:
            break
        s = inp[-1]
        for e in inp:
            if inside(e, a, b):
                if not inside(s, a, b):
                    out.append(intersect(s, e, a, b))
                out.append(e)
            elif inside(s, a, b):
                out.append(intersect(s, e, a, b))
            s = e
    return out


def d(poly):
    return "M" + " ".join("%.2f %.2f" % p for p in poly) + "z"


def path_d(*polys):
    return "".join(d(p) for p in polys)


# --- the glyphs ----------------------------------------------------------------

SHIELD = shield_polygon()

TICK = [(4.6, 8.2), (6.0, 6.8), (7.4, 8.2), (10.6, 5.0), (12.0, 6.4), (7.4, 11.0)]

RING_OUTER = circle(8, 8.2, 3.4)
RING_INNER = circle(8, 8.2, 1.6)

# Apex up, base on the pixel row at y=15.2 so it does not antialias away.
WARN_BADGE = [(11.5, 7.6), (15.7, 15.2), (7.3, 15.2)]
_warn_incentre = (11.5, 12.72)
WARN_HALO = scaled_about(WARN_BADGE, *_warn_incentre, factor=1.42)
WARN_BAR = rect(10.7, 10.4, 12.3, 12.7)
WARN_DOT = rect(10.7, 13.4, 12.3, 14.6)

ERR_BADGE = circle(11.6, 11.5, 3.7)
ERR_HALO = circle(11.6, 11.5, 4.8)
ERR_X1 = rotated_rect(11.6, 11.5, 4.2, 1.7, 45)
ERR_X2 = rotated_rect(11.6, 11.5, 4.2, 1.7, -45)

INACTIVE_INNER = shield_polygon(inset=1.6)

# Brand colours, from src/share/timeshift/images/timeshift-shield-*.svg.
GREEN = "#79d073"
AMBER = "#eec758"
RED = "#ee545b"
RED_DARK = "#c94b51"
GREY = "#9a9996"
WHITE = "#ffffff"

# The single colour the symbolic set is authored in. Every host replaces it.
SYMBOLIC = "#2e3436"


def symbolic(shapes):
    """One evenodd path: every polygon toggles parity."""
    return ['<path fill-rule="evenodd" d="%s"/>' % path_d(*shapes)]


STATES = {
    # name: (title, symbolic polygons in parity order, colour layers)
    "ok": (
        "Snapshots are up to date",
        [SHIELD, TICK],
        [(GREEN, [SHIELD]), (WHITE, [TICK])],
    ),
    "busy": (
        "A snapshot is running",
        [SHIELD, RING_OUTER, RING_INNER],
        [(GREEN, [SHIELD]), (WHITE, [RING_OUTER, RING_INNER])],
    ),
    "warning": (
        "Snapshots need attention",
        [SHIELD, clip(SHIELD, WARN_HALO), WARN_BADGE, WARN_BAR, WARN_DOT],
        [(AMBER, [SHIELD, clip(SHIELD, WARN_HALO)]),
         (RED, [WARN_BADGE]), (WHITE, [WARN_BAR, WARN_DOT])],
    ),
    "error": (
        "Snapshots are failing",
        [SHIELD, clip(SHIELD, ERR_HALO), ERR_BADGE, ERR_X1, ERR_X2],
        [(RED, [SHIELD, clip(SHIELD, ERR_HALO)]),
         (RED_DARK, [ERR_BADGE]), (WHITE, [ERR_X1, ERR_X2])],
    ),
    "inactive": (
        "Timeshift status is unavailable",
        [SHIELD, INACTIVE_INNER],
        [(GREY, [SHIELD, INACTIVE_INNER])],
    ),
}


def svg(title, body, symbolic_set):
    head = ['<?xml version="1.0" encoding="UTF-8"?>',
            '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">',
            "  <title>%s</title>" % title,
            "  <!-- Generated by tools/make-icons.py; edit that, not this. -->"]
    if symbolic_set:
        head.append('  <style type="text/css" class="current-color-scheme">'
                    '.ColorScheme-Text{color:%s;}</style>' % SYMBOLIC)
        head.append('  <g class="ColorScheme-Text" fill="currentColor">')
    else:
        head.append("  <g>")
    return "\n".join(head + ["    " + line for line in body] + ["  </g>", "</svg>", ""])


def build_all():
    out = {}
    for state, (title, parity, layers) in STATES.items():
        out["timeshift-tray-%s-symbolic" % state] = svg(title, symbolic(parity), True)
        colour_body = ['<path fill="%s" fill-rule="evenodd" d="%s"/>' % (fill, path_d(*polys))
                       for fill, polys in layers]
        out["timeshift-tray-%s" % state] = svg(title, colour_body, False)
    return out


def write_png(svg_path, png_path):
    import gi
    gi.require_version("GdkPixbuf", "2.0")
    from gi.repository import GdkPixbuf
    pix = GdkPixbuf.Pixbuf.new_from_file_at_size(svg_path, 16, 16)
    pix.savev(png_path, "png", [], [])
    return pix


def ascii_art(pix):
    width, height = pix.get_width(), pix.get_height()
    stride, n = pix.get_rowstride(), pix.get_n_channels()
    data = pix.get_pixels()
    rows = []
    for y in range(height):
        row = ""
        for x in range(width):
            a = data[y * stride + x * n + 3]
            row += "██" if a > 200 else ("▒▒" if a > 80 else "··")
        rows.append(row)
    return "\n".join(rows)


def contact_sheet(names, path, size=48, pad=8):
    """Every icon at `size`px on one PNG, colour row over symbolic row."""
    import gi
    gi.require_version("GdkPixbuf", "2.0")
    from gi.repository import GdkPixbuf
    cols = len(names) // 2
    sheet = GdkPixbuf.Pixbuf.new(GdkPixbuf.Colorspace.RGB, True, 8,
                                 cols * (size + pad) + pad, 2 * (size + pad) + pad)
    sheet.fill(0xf6f5f4ff)
    for i, name in enumerate(names):
        pix = GdkPixbuf.Pixbuf.new_from_file_at_size(
            os.path.join(SCALABLE, name + ".svg"), size, size)
        row, col = (1 if name.endswith("-symbolic") else 0), i % cols
        pix.composite(sheet, pad + col * (size + pad), pad + row * (size + pad),
                      size, size, pad + col * (size + pad), pad + row * (size + pad),
                      1, 1, GdkPixbuf.InterpType.BILINEAR, 255)
    sheet.savev(path, "png", [], [])


def main(argv):
    show = "--ascii" in argv
    preview = None
    if "--preview" in argv:
        preview = argv[argv.index("--preview") + 1]
    os.makedirs(SCALABLE, exist_ok=True)
    os.makedirs(PNG16, exist_ok=True)
    for name, text in sorted(build_all().items()):
        svg_path = os.path.join(SCALABLE, name + ".svg")
        with open(svg_path, "w") as handle:
            handle.write(text)
        pix = write_png(svg_path, os.path.join(PNG16, name + ".png"))
        size = os.path.getsize(svg_path)
        print("%-32s %5d bytes" % (name, size))
        if show:
            print(ascii_art(pix))
            print()
    if preview:
        names = sorted(build_all())
        contact_sheet([n for n in names if not n.endswith("-symbolic")]
                      + [n for n in names if n.endswith("-symbolic")], preview)
        print("preview:", preview)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
