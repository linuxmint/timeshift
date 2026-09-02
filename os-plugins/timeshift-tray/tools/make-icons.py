#!/usr/bin/env python3
# Copyright 2026 makeafide <willsmit4433@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
"""Generate every icon the tray ships.

    tools/make-icons.py                 # writes share/icons/... and share/timeshift-tray/dots
    tools/make-icons.py --ascii         # also prints each status icon at 16px, for the eye
    tools/make-icons.py --preview P.png # also renders a contact sheet

Three families come out of one description of the geometry:

  status icons   share/icons/hicolor/{scalable,16x16}/status/timeshift-tray-<state>[-symbolic]
                 Timeshift's shield with the state cut out of it. The symbolic
                 set is one colour and the panel recolours it; the colour set
                 is the ShadowMorph palette, drawn as-is. `busy-0`..`busy-7`
                 are the running state with the ring filled in eighths, so
                 the panel shows progress without the menu being opened.
  launcher icon  share/icons/hicolor/<size>/apps/timeshift-tray
                 The shield in ink on the brand gradient, in the composition
                 of shadowmorph.com's own mark: gradient ground, dark shape.
  status dots    share/timeshift-tray/dots/<key>.png
                 16px discs for the menu rows, sent as dbusmenu `icon-data`.

Palette: shadowmorph.com's stylesheet (styles-*.css), read rather than guessed.

Everything is a filled path with the evenodd rule; gradients are plain
<linearGradient>, which librsvg and QtSvg both implement. No strokes: GTK
recolours a symbolic icon by forcing `fill` on every shape and leaves
`stroke` alone, so an outlined shield would come back solid. No masks or
clipPaths: QtSvg, which Plasma renders through, has neither.

The badges on warning and error overlap the shield with a one-pixel halo so
they read as a separate shape when everything is one colour. A halo is a hole,
and a hole in a single-colour icon can only be made by parity -- but a circle
cut out with evenodd is a hole only where it lies INSIDE the shield and a
filled disc where it lies outside. So the halo is the intersection of the
shield polygon and the halo shape, computed here by Sutherland-Hodgman, which
is why this is a script and not a folder of hand-written files.
"""

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
HICOLOR = os.path.join(ROOT, "share/icons/hicolor")
SCALABLE = os.path.join(HICOLOR, "scalable/status")
PNG16 = os.path.join(HICOLOR, "16x16/status")
DOTS = os.path.join(ROOT, "share/timeshift-tray/dots")

APP_ICON = "timeshift-tray"
APP_SIZES = (16, 22, 24, 32, 48, 64, 128, 256)

PROGRESS_STEPS = 8

# --- the palette (shadowmorph.com) ------------------------------------------------

INK = "#070e16"          # --c-ink: the dark ground
GREEN = "#22c55e"        # --gc-hue-green
YELLOW = "#eab308"       # --gc-hue-yellow
RED = "#ef4444"          # --gc-hue-red
RED_DEEP = "#b91c1c"     # --c-error (light scheme)
BLUE = "#3b82f6"         # --gc-hue-blue
MUTED = "#888ea8"        # --c-muted (dark scheme)
WHITE = "#ffffff"

# --gradient-brand, six stops, purple to blue.
BRAND_STOPS = (("0", "#b100ff"), (".11", "#a704ff"), (".3", "#8e11ff"),
               (".53", "#6425ff"), (".81", "#2b42ff"), ("1", "#0058ff"))
BRAND = "url(#brand)"

# The single colour the symbolic set is authored in. Every host replaces it.
SYMBOLIC = INK

# --- the brand shield ----------------------------------------------------------

# Cubic segments of the 64px Timeshift shield, top centre first, clockwise
# (from src/share/timeshift/images/timeshift-shield-high.svg: m 32 8 c ... z).
_BRAND_SHIELD = [
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
    for p0, p1, p2, p3 in _BRAND_SHIELD:
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


def annular_sector(cx, cy, r_out, r_in, fraction, n=64):
    """The ring between two radii, from 12 o'clock clockwise for `fraction`."""
    if fraction <= 0:
        return []
    steps = max(2, int(round(n * fraction)))
    start = -math.pi / 2
    sweep = 2 * math.pi * min(1.0, fraction)
    outer = [(cx + r_out * math.cos(start + sweep * i / steps),
              cy + r_out * math.sin(start + sweep * i / steps)) for i in range(steps + 1)]
    inner = [(cx + r_in * math.cos(start + sweep * i / steps),
              cy + r_in * math.sin(start + sweep * i / steps)) for i in range(steps, -1, -1)]
    return outer + inner


def rect(x0, y0, x1, y1):
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


def rounded_square(size, radius, n=12):
    pts = []
    for cx, cy, a0 in ((size - radius, radius, -90), (size - radius, size - radius, 0),
                       (radius, size - radius, 90), (radius, radius, 180)):
        for i in range(n + 1):
            a = math.radians(a0 + 90 * i / n)
            pts.append((cx + radius * math.cos(a), cy + radius * math.sin(a)))
    return pts


def rotated_rect(cx, cy, length, width, degrees):
    a = math.radians(degrees)
    ux, uy = math.cos(a) * length / 2, math.sin(a) * length / 2
    vx, vy = -math.sin(a) * width / 2, math.cos(a) * width / 2
    return [(cx - ux - vx, cy - uy - vy), (cx + ux - vx, cy + uy - vy),
            (cx + ux + vx, cy + uy + vy), (cx - ux + vx, cy - uy + vy)]


def scaled_about(poly, cx, cy, factor):
    return [(cx + (x - cx) * factor, cy + (y - cy) * factor) for x, y in poly]


def scaled(poly, factor, dx=0, dy=0):
    return [(x * factor + dx, y * factor + dy) for x, y in poly]


def clip(subject, clipper):
    """Sutherland-Hodgman: subject polygon clipped to a CONVEX clipper."""
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
    return "".join(d(p) for p in polys if p)


# --- the glyphs (16px status icons) --------------------------------------------

SHIELD = shield_polygon()

TICK = [(4.6, 8.2), (6.0, 6.8), (7.4, 8.2), (10.6, 5.0), (12.0, 6.4), (7.4, 11.0)]

RING_C = (8, 8.2)
RING_R_OUT, RING_R_IN = 3.4, 1.6
RING_OUTER = circle(*RING_C, RING_R_OUT)
RING_INNER = circle(*RING_C, RING_R_IN)

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


def gradient_defs():
    stops = "".join('<stop offset="%s" stop-color="%s"/>' % s for s in BRAND_STOPS)
    # 225deg in CSS terms: purple at the top right, blue at the bottom left.
    return ('<defs><linearGradient id="brand" x1="1" y1="0" x2="0" y2="1">'
            '%s</linearGradient></defs>' % stops)


def status_icons():
    """name -> (title, symbolic polygons in parity order, colour layers).

    A colour layer is (fill, polygons) or (fill, polygons, opacity).
    """
    out = {
        "ok": ("Snapshots are up to date",
               [SHIELD, TICK],
               [(GREEN, [SHIELD]), (WHITE, [TICK])]),
        "busy": ("A snapshot is running",
                 [SHIELD, RING_OUTER, RING_INNER],
                 [(BRAND, [SHIELD]), (WHITE, [RING_OUTER, RING_INNER])]),
        "warning": ("Snapshots need attention",
                    [SHIELD, clip(SHIELD, WARN_HALO), WARN_BADGE, WARN_BAR, WARN_DOT],
                    [(YELLOW, [SHIELD, clip(SHIELD, WARN_HALO)]),
                     (RED, [WARN_BADGE]), (WHITE, [WARN_BAR, WARN_DOT])]),
        "error": ("Snapshots are failing",
                  [SHIELD, clip(SHIELD, ERR_HALO), ERR_BADGE, ERR_X1, ERR_X2],
                  [(RED, [SHIELD, clip(SHIELD, ERR_HALO)]),
                   (RED_DEEP, [ERR_BADGE]), (WHITE, [ERR_X1, ERR_X2])]),
        "inactive": ("Timeshift status is unavailable",
                     [SHIELD, INACTIVE_INNER],
                     [(MUTED, [SHIELD, INACTIVE_INNER])]),
    }
    for n in range(PROGRESS_STEPS):
        sector = annular_sector(*RING_C, RING_R_OUT, RING_R_IN, n / PROGRESS_STEPS)
        out["busy-%d" % n] = (
            "A snapshot is running, %d%% done" % (100 * n // PROGRESS_STEPS),
            # The ring is a hole (parity 2); the sector fills it back in (3).
            [SHIELD, RING_OUTER, RING_INNER, sector],
            [(BRAND, [SHIELD]),
             (WHITE, [RING_OUTER, RING_INNER], 0.35),
             (WHITE, [sector])])
    return out


# --- writing -------------------------------------------------------------------

def svg(title, body, size=16, symbolic_set=False, defs=""):
    head = ['<?xml version="1.0" encoding="UTF-8"?>',
            '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">'
            % (size, size, size, size),
            "  <title>%s</title>" % title,
            "  <!-- Generated by tools/make-icons.py; edit that, not this. -->"]
    if defs:
        head.append("  " + defs)
    if symbolic_set:
        head.append('  <style type="text/css" class="current-color-scheme">'
                    '.ColorScheme-Text{color:%s;}</style>' % SYMBOLIC)
        head.append('  <g class="ColorScheme-Text" fill="currentColor">')
    else:
        head.append("  <g>")
    return "\n".join(head + ["    " + line for line in body] + ["  </g>", "</svg>", ""])


def colour_body(layers):
    body = []
    for layer in layers:
        fill, polys = layer[0], layer[1]
        opacity = ' fill-opacity="%s"' % layer[2] if len(layer) > 2 else ""
        body.append('<path fill="%s"%s fill-rule="evenodd" d="%s"/>'
                    % (fill, opacity, path_d(*polys)))
    return body


def status_svgs():
    out = {}
    for state, (title, parity, layers) in status_icons().items():
        out["timeshift-tray-%s-symbolic" % state] = svg(
            title, ['<path fill-rule="evenodd" d="%s"/>' % path_d(*parity)],
            symbolic_set=True)
        uses_brand = any(layer[0] == BRAND for layer in layers)
        out["timeshift-tray-%s" % state] = svg(
            title, colour_body(layers), defs=gradient_defs() if uses_brand else "")
    return out


def app_icon_svg(size=512):
    """The launcher icon: ink shield with a white tick on the brand gradient."""
    ground = rounded_square(size, size * 0.22)
    # The 16px shield spans y 0.8..15.2; scale it to ~58% of the tile.
    factor = size * 0.58 / 14.4
    dx = size / 2 - 8 * factor
    dy = size / 2 - 8 * factor
    shield = scaled(SHIELD, factor, dx, dy)
    tick = scaled(TICK, factor, dx, dy)
    body = ['<path fill="%s" d="%s"/>' % (BRAND, d(ground)),
            '<path fill="%s" fill-rule="evenodd" d="%s"/>' % (INK, path_d(shield, tick))]
    return svg("Timeshift Tray", body, size=size, defs=gradient_defs())


DOT_FILLS = {
    "green": GREEN,
    "yellow": YELLOW,
    "red": RED,
    "blue": BLUE,
    "grey": MUTED,
    "brand": BRAND,
}


def dot_svg(fill, size=16, r=5):
    defs = gradient_defs() if fill == BRAND else ""
    return svg("status", ['<path fill="%s" d="%s"/>' % (fill, d(circle(size / 2, size / 2, r)))],
               size=size, defs=defs)


def write_png(svg_path, png_path, size):
    import gi
    gi.require_version("GdkPixbuf", "2.0")
    from gi.repository import GdkPixbuf
    pix = GdkPixbuf.Pixbuf.new_from_file_at_size(svg_path, size, size)
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
    """The named icons at `size`px, colour row over symbolic row, on ink."""
    import gi
    gi.require_version("GdkPixbuf", "2.0")
    from gi.repository import GdkPixbuf
    cols = (len(names) + 1) // 2
    sheet = GdkPixbuf.Pixbuf.new(GdkPixbuf.Colorspace.RGB, True, 8,
                                 cols * (size + pad) + pad, 2 * (size + pad) + pad)
    sheet.fill(0x070e16ff)
    # The symbolic row is authored in ink, so give it the site's light ground.
    light = GdkPixbuf.Pixbuf.new(GdkPixbuf.Colorspace.RGB, True, 8,
                                 sheet.get_width(), size + pad)
    light.fill(0xe0e6edff)
    light.copy_area(0, 0, light.get_width(), light.get_height(), sheet,
                    0, size + pad + pad // 2)
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
    preview = argv[argv.index("--preview") + 1] if "--preview" in argv else None

    os.makedirs(SCALABLE, exist_ok=True)
    os.makedirs(PNG16, exist_ok=True)
    svgs = status_svgs()
    for name in sorted(svgs):
        svg_path = os.path.join(SCALABLE, name + ".svg")
        with open(svg_path, "w") as handle:
            handle.write(svgs[name])
        pix = write_png(svg_path, os.path.join(PNG16, name + ".png"), 16)
        print("%-34s %5d bytes" % (name, os.path.getsize(svg_path)))
        if show:
            print(ascii_art(pix))
            print()

    apps_scalable = os.path.join(HICOLOR, "scalable/apps")
    os.makedirs(apps_scalable, exist_ok=True)
    app_svg = os.path.join(apps_scalable, APP_ICON + ".svg")
    with open(app_svg, "w") as handle:
        handle.write(app_icon_svg())
    for size in APP_SIZES:
        folder = os.path.join(HICOLOR, "%dx%d/apps" % (size, size))
        os.makedirs(folder, exist_ok=True)
        write_png(app_svg, os.path.join(folder, APP_ICON + ".png"), size)
    print("%-34s %s" % (APP_ICON, ", ".join(str(s) for s in APP_SIZES)))

    os.makedirs(DOTS, exist_ok=True)
    for key, fill in DOT_FILLS.items():
        svg_path = os.path.join(DOTS, key + ".svg")
        with open(svg_path, "w") as handle:
            handle.write(dot_svg(fill))
        write_png(svg_path, os.path.join(DOTS, key + ".png"), 16)
        os.remove(svg_path)
    print("%-34s %s" % ("dots", ", ".join(DOT_FILLS)))

    if preview:
        base = sorted(n for n in svgs if not n.split("-symbolic")[0][-1].isdigit())
        steps = ["timeshift-tray-busy-%d" % n for n in (2, 5)]
        names = ([n for n in base if not n.endswith("-symbolic")] + steps
                 + [n for n in base if n.endswith("-symbolic")]
                 + [s + "-symbolic" for s in steps])
        contact_sheet(names, preview)
        print("preview:", preview)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
