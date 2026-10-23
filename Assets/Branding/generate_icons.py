#!/usr/bin/env python3
"""XT-Player brand generator.

The mark: two green leaves crossed into an "X" on a clean white ground. Each leaf is built from
its midrib (a cubic Bezier), with a two-tone folded blade, veins, a stem and a waxy highlight.
Every app icon the Apple targets need is rendered from this one description with headless
Chromium (Playwright):

  Assets/AppIcon.xcassets/AppIcon.appiconset        iOS/iPadOS (default, dark, tinted) + macOS
  Assets/AppIcon-tvOS.xcassets/...brandassets       tvOS 3-layer parallax icons + Top Shelf
  Assets/Shared.xcassets/BrandMark.imageset         transparent mark used inside the app
  Assets/Branding/dmg-background*.png               macOS installer (DMG) window background
  Assets/Branding/svg/                              vector masters (mark + iOS icon)

Usage:  python3 Assets/Branding/generate_icons.py
Requires: numpy, pillow, playwright (+ `playwright install chromium`).
"""
from __future__ import annotations

import json
import math
import shutil
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "Assets"
BRANDING = ASSETS / "Branding"
SVG_OUT = BRANDING / "svg"
INFO = {"author": "xcode", "version": 1}

# ----------------------------------------------------------------------------
# Leaf geometry (1024 x 1024 design space)
# ----------------------------------------------------------------------------


def _bezier(p, t):
    t = t[:, None]
    return ((1 - t) ** 3) * p[0] + 3 * ((1 - t) ** 2) * t * p[1] + 3 * (1 - t) * t ** 2 * p[2] + t ** 3 * p[3]


def _bezier_d(p, t):
    t = t[:, None]
    return 3 * ((1 - t) ** 2) * (p[1] - p[0]) + 6 * (1 - t) * t * (p[2] - p[1]) + 3 * t ** 2 * (p[3] - p[2])


def _path(points) -> str:
    return "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in points) + "Z"


def _polyline(points) -> str:
    return "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in points)


class Leaf:
    """A blade around a curved midrib, pointed tip, rounded base, short stem."""

    def __init__(self, base, tip, bow, width, light_side, asym=0.06, stem=84, samples=200):
        base, tip = np.array(base, float), np.array(tip, float)
        axis = tip - base
        length = np.linalg.norm(axis)
        u = axis / length
        perp = np.array([u[1], -u[0]])
        self.p = np.array([base, base + axis * 0.32 + perp * bow, base + axis * 0.68 + perp * bow * 0.9, tip])
        self.t = np.linspace(0.0, 1.0, samples)
        self.c = _bezier(self.p, self.t)
        d = _bezier_d(self.p, self.t)
        d /= np.linalg.norm(d, axis=1)[:, None]
        self.d = d
        self.n = np.stack([d[:, 1], -d[:, 0]], axis=1)  # left-hand normal
        self.light = light_side  # +1: left half faces the light, -1: right half
        t = self.t
        # widest at ~40 % from the base, rounded base, long pointed tip
        prof = np.sin(math.pi * np.clip(t, 0, 1) ** 0.86) ** 0.78
        prof *= 1 - 0.18 * t
        self.half = width / 2 * prof
        self.asym = asym
        self.length = length
        self.stem_len = stem
        self.base, self.tip = base, tip

    def _edge(self, side: int, scale: float = 1.0, grow: float = 0.0):
        k = 1 + self.asym * side * self.light
        return self.c + self.n * (self.half[:, None] * k * scale + grow) * side

    def outline(self, grow: float = 0.0) -> str:
        return _path(np.concatenate([self._edge(+1, grow=grow), self._edge(-1, grow=grow)[::-1]]))

    def half_blade(self, side: int) -> str:
        return _path(np.concatenate([self._edge(side), self.c[::-1]]))

    def band(self, side: int, lo: float, hi: float, t0=0.0, t1=1.0) -> str:
        m = (self.t >= t0) & (self.t <= t1)
        k = 1 + self.asym * side * self.light
        a = self.c[m] + self.n[m] * (self.half[m][:, None] * k * hi) * side
        b = self.c[m] + self.n[m] * (self.half[m][:, None] * k * lo) * side
        return _path(np.concatenate([a, b[::-1]]))

    def midrib(self) -> str:
        m = self.t <= 0.93
        w = 5.5 * (1 - self.t[m]) + 0.8
        a = self.c[m] + self.n[m] * (w[:, None] / 2)
        b = self.c[m] - self.n[m] * (w[:, None] / 2)
        return _path(np.concatenate([a, b[::-1]]))

    def veins(self, side: int) -> list[str]:
        out = []
        k = 1 + self.asym * side * self.light
        for tv in (0.16, 0.27, 0.38, 0.49, 0.60, 0.71, 0.81):
            i = int(tv * (len(self.t) - 1))
            start = self.c[i]
            reach = self.half[i] * k * 0.86
            # veins sweep toward the tip and curve gently outwards
            j = min(len(self.t) - 1, i + int(len(self.t) * 0.11))
            end = self.c[j] + self.n[j] * reach * side
            ctrl = self.c[i] + self.d[i] * reach * 0.25 + self.n[i] * reach * 0.62 * side
            out.append(f"M{start[0]:.1f},{start[1]:.1f} Q{ctrl[0]:.1f},{ctrl[1]:.1f} {end[0]:.1f},{end[1]:.1f}")
        return out

    def stem(self) -> str:
        d0 = self.d[0]
        n0 = self.n[0]
        pts_a, pts_b = [], []
        for s in np.linspace(0, 1, 24):
            # slight curl at the stem's end
            pos = self.base + d0 * 10 - d0 * self.stem_len * s + n0 * (self.stem_len * 0.22 * s * s) * self.light
            w = 15 - 8 * s
            pts_a.append(pos + n0 * w / 2)
            pts_b.append(pos - n0 * w / 2)
        return _path(np.concatenate([np.array(pts_a), np.array(pts_b)[::-1]]))


# Mirror-symmetric pair: back leaf "/" (stem bottom-left), front leaf "\" (stem bottom-right).
BACK = Leaf(base=(262, 792), tip=(822, 212), bow=-40, width=292, light_side=+1)
FRONT = Leaf(base=(762, 792), tip=(202, 212), bow=40, width=292, light_side=-1)

GREENS = {
    "back": {"light": ("#2DB35A", "#9BE07A"), "dark": ("#0C7A3B", "#3FAE56"), "stem": "#16753A"},
    "front": {"light": ("#34C759", "#B3EC86"), "dark": ("#118A42", "#4CBF5E"), "stem": "#1A8A44"},
}


def _grad(gid, leaf: Leaf, c0, c1):
    (x1, y1), (x2, y2) = leaf.base, leaf.tip
    return (f'<linearGradient id="{gid}" gradientUnits="userSpaceOnUse" x1="{x1:.0f}" y1="{y1:.0f}" '
            f'x2="{x2:.0f}" y2="{y2:.0f}"><stop offset="0" stop-color="{c0}"/><stop offset="1" stop-color="{c1}"/>'
            f'</linearGradient>')


FILTERS = """
<filter id="soft" x="-10%" y="-10%" width="120%" height="120%"><feGaussianBlur stdDeviation="3"/></filter>
<filter id="sheen" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="11"/></filter>
<filter id="gap" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="9"/></filter>
<filter id="drop" x="-30%" y="-30%" width="160%" height="160%">
  <feGaussianBlur in="SourceAlpha" stdDeviation="16"/><feOffset dy="18" result="b"/>
  <feFlood flood-color="#0A3B1C" flood-opacity="0.26"/><feComposite in2="b" operator="in" result="s"/>
  <feMerge><feMergeNode in="s"/><feMergeNode in="SourceGraphic"/></feMerge>
</filter>
"""


def _leaf_svg(key: str, leaf: Leaf, palette, mono: str | None = None, gloss: bool = True) -> tuple[str, str]:
    lit, shade = leaf.light, -leaf.light
    defs, body = [], []
    if mono:
        body.append(f'<path d="{leaf.stem()}" fill="{mono}"/>')
        body.append(f'<path d="{leaf.outline()}" fill="{mono}"/>')
        body.append(f'<path d="{leaf.midrib()}" fill="#000" fill-opacity="0.55"/>')
        return "", "".join(body)
    defs.append(_grad(f"{key}L", leaf, *palette["light"]))
    defs.append(_grad(f"{key}D", leaf, *palette["dark"]))
    defs.append(f'<clipPath id="{key}clip"><path d="{leaf.outline()}"/></clipPath>')
    body.append(f'<path d="{leaf.stem()}" fill="{palette["stem"]}"/>')
    body.append(f'<path d="{leaf.half_blade(lit)}" fill="url(#{key}L)"/>')
    body.append(f'<path d="{leaf.half_blade(shade)}" fill="url(#{key}D)"/>')
    veins = "".join(f'<path d="{v}"/>' for v in leaf.veins(lit))
    body.append(f'<g clip-path="url(#{key}clip)" fill="none" stroke="#F2FFE9" stroke-opacity="0.42" '
                f'stroke-width="3.2" stroke-linecap="round">{veins}</g>')
    veins = "".join(f'<path d="{v}"/>' for v in leaf.veins(shade))
    body.append(f'<g clip-path="url(#{key}clip)" fill="none" stroke="#CFF5C0" stroke-opacity="0.26" '
                f'stroke-width="3.2" stroke-linecap="round">{veins}</g>')
    if gloss:
        # waxy sheen on the lit half + soft shading near the shaded edge
        body.append(f'<g clip-path="url(#{key}clip)"><path d="{leaf.band(lit, 0.28, 0.82, 0.06, 0.82)}" '
                    f'fill="#FFFFFF" fill-opacity="0.34" filter="url(#sheen)"/>'
                    f'<path d="{leaf.band(shade, 0.70, 1.05)}" fill="#04381A" fill-opacity="0.22" filter="url(#soft)"/></g>')
    body.append(f'<path d="{leaf.midrib()}" fill="#E9FFDC" fill-opacity="0.85"/>')
    body.append(f'<path d="{leaf.outline()}" fill="none" stroke="#0B5E2C" stroke-opacity="0.35" stroke-width="1.6"/>')
    return "".join(defs), "".join(body)


def mark_group(mono: str | None = None, gloss: bool = True) -> tuple[str, str]:
    db, bb = _leaf_svg("b", BACK, GREENS["back"], mono, gloss)
    df, bf = _leaf_svg("f", FRONT, GREENS["front"], mono, gloss)
    # the front leaf's shadow falls on the back leaf where they cross
    shadow_op = 0.0 if mono else 0.30
    gap = (f'<clipPath id="backclip"><path d="{BACK.outline()}"/></clipPath>'
           f'<g clip-path="url(#backclip)"><path d="{FRONT.outline(grow=6)}" fill="#03301A" '
           f'fill-opacity="{shadow_op}" filter="url(#gap)" transform="translate(0,10)"/></g>')
    if mono:
        gap = (f'<clipPath id="backclip"><path d="{BACK.outline()}"/></clipPath>'
               f'<g clip-path="url(#backclip)"><path d="{FRONT.outline(grow=10)}" fill="#000"/></g>')
    return FILTERS + db + df, f"<g>{bb}{gap}{bf}</g>"


def placed_mark(scale, cx, cy, mono=None, gloss=True, shadow=True):
    d, g = mark_group(mono, gloss)
    tx, ty = cx - 512 * scale, cy - 512 * scale
    filt = ' filter="url(#drop)"' if shadow else ""
    return d, f'<g transform="translate({tx:.2f},{ty:.2f}) scale({scale:.4f})"><g{filt}>{g}</g></g>'


def background(w, h, tint=True) -> tuple[str, str]:
    defs = ('<radialGradient id="bg" cx="0.5" cy="0.42" r="0.75">'
            '<stop offset="0" stop-color="#FFFFFF"/><stop offset="0.7" stop-color="#FBFDFB"/>'
            '<stop offset="1" stop-color="#EEF5EF"/></radialGradient>'
            '<radialGradient id="halo" cx="0.5" cy="0.5" r="0.5">'
            '<stop offset="0" stop-color="#C9F0CF" stop-opacity="0.55"/>'
            '<stop offset="1" stop-color="#C9F0CF" stop-opacity="0"/></radialGradient>')
    s = min(w, h)
    body = f'<rect width="{w}" height="{h}" fill="url(#bg)"/>'
    if tint:
        body += f'<ellipse cx="{w / 2}" cy="{h / 2}" rx="{s * 0.40}" ry="{s * 0.38}" fill="url(#halo)"/>'
    return defs, body


def svg(w, h, defs, body) -> str:
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">'
            f'<defs>{defs}</defs>{body}</svg>')


# ----------------------------------------------------------------------------
# Compositions
# ----------------------------------------------------------------------------

def ios_icon(appearance="light") -> str:
    W = 1024
    if appearance == "tinted":
        d, m = placed_mark(0.92, 512, 512, mono="#FFFFFF", shadow=False)
        return svg(W, W, d, f'<rect width="{W}" height="{W}" fill="#000"/>{m}')
    if appearance == "dark":
        d, m = placed_mark(0.92, 512, 512)
        return svg(W, W, d, m)  # transparent: iOS draws the dark backdrop
    bd, bb = background(W, W)
    d, m = placed_mark(0.92, 512, 500)
    return svg(W, W, bd + d, bb + m)


def mac_icon() -> str:
    W, S, R = 1024, 824, 185
    o = (W - S) / 2
    bd, bb = background(S, S)
    d, m = placed_mark(0.74, S / 2, S / 2 - 8)
    clip = f'<clipPath id="sq"><rect width="{S}" height="{S}" rx="{R}"/></clipPath>'
    shadow = ('<filter id="macshadow" x="-20%" y="-20%" width="140%" height="140%">'
              '<feGaussianBlur in="SourceAlpha" stdDeviation="14"/><feOffset dy="12"/>'
              '<feComponentTransfer><feFuncA type="linear" slope="0.30"/></feComponentTransfer>'
              '<feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>')
    body = (f'<g transform="translate({o},{o - 10})" filter="url(#macshadow)"><g clip-path="url(#sq)">{bb}{m}</g>'
            f'<rect x="1" y="1" width="{S - 2}" height="{S - 2}" rx="{R}" fill="none" stroke="#000" '
            f'stroke-opacity="0.08" stroke-width="2"/></g>')
    return svg(W, W, bd + d + clip + shadow, body)


def tv_layers(w, h) -> dict[str, str]:
    """Back = white ground, Middle = the leaves, Front = waxy highlights (parallax gloss)."""
    bd, bb = background(w, h)
    scale = h / 1024 * 1.16
    cy = h / 2 + h * 0.02
    d, m = placed_mark(scale, w / 2, cy, gloss=False)
    tx, ty = w / 2 - 512 * scale, cy - 512 * scale
    sheen = "".join(
        f'<path d="{leaf.band(leaf.light, 0.30, 0.80, 0.08, 0.72)}" fill="#FFFFFF" fill-opacity="0.30" filter="url(#sheen)"/>'
        for leaf in (BACK, FRONT)
    )
    front = (f'<g transform="translate({tx:.2f},{ty:.2f}) scale({scale:.4f})">{sheen}</g>'
             f'<ellipse cx="{w * 0.36:.1f}" cy="{h * 0.30:.1f}" rx="{h * 0.10:.1f}" ry="{h * 0.035:.1f}" '
             f'transform="rotate(-38 {w * 0.36:.1f} {h * 0.30:.1f})" fill="#FFFFFF" fill-opacity="0.35" filter="url(#sheen)"/>')
    return {"Back": svg(w, h, bd, bb), "Middle": svg(w, h, d, m), "Front": svg(w, h, FILTERS, front)}


WORD_FONT = "Inter Display, Inter, SF Pro Display, Helvetica Neue, sans-serif"


def top_shelf(w, h) -> str:
    bd, bb = background(w, h, tint=False)
    s = h / 720
    d, m = placed_mark(0.50 * s, w * 0.5 - 320 * s, h / 2 + 6 * s)
    text = (f'<text x="{w * 0.5 - 70 * s}" y="{h / 2 + 30 * s}" font-family="{WORD_FONT}" font-weight="800" '
            f'font-size="{124 * s}" letter-spacing="{-2 * s}" fill="#0F2A18">XT-Player</text>'
            f'<text x="{w * 0.5 - 64 * s}" y="{h / 2 + 92 * s}" font-family="Inter, sans-serif" font-weight="600" '
            f'font-size="{29 * s}" letter-spacing="{8 * s}" fill="#1E8E45">4K · HDR · DOLBY VISION · LOSSLESS</text>')
    return svg(w, h, bd + d, bb + m + text)


def dmg_background(w, h, scale) -> str:
    bd, bb = background(w, h, tint=False)
    s = scale
    d, m = placed_mark(0.11 * s, 54 * s, 46 * s, shadow=False)
    arrow = (f'<path d="M{262 * s},{190 * s} C{300 * s},{172 * s} {360 * s},{172 * s} {398 * s},{190 * s}" fill="none" '
             f'stroke="#34C759" stroke-width="{5 * s}" stroke-linecap="round"/>'
             f'<path d="M{388 * s},{176 * s} L{404 * s},{193 * s} L{382 * s},{200 * s}" fill="none" stroke="#34C759" '
             f'stroke-width="{5 * s}" stroke-linecap="round" stroke-linejoin="round"/>')
    text = (f'<text x="{90 * s}" y="{54 * s}" font-family="{WORD_FONT}" font-weight="800" font-size="{26 * s}" fill="#0F2A18">XT-Player</text>'
            f'<text x="{w / 2}" y="{352 * s}" text-anchor="middle" font-family="Inter, sans-serif" font-weight="500" '
            f'font-size="{15 * s}" fill="#4B5B50">Kéo XT-Player vào Applications để cài đặt</text>')
    return svg(w, h, bd + d, bb + m + arrow + text)


def brand_mark() -> str:
    d, m = placed_mark(1.0, 512, 512, shadow=False)
    return svg(1024, 1024, d, m)


# ----------------------------------------------------------------------------
# Rendering + asset catalogs
# ----------------------------------------------------------------------------

def render(jobs):
    """Rasterise each SVG at exactly w x h px; opaque outputs lose their alpha channel."""
    import re

    from PIL import Image
    from playwright.sync_api import sync_playwright

    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(device_scale_factor=1)
        for markup, out, w, h, opaque in jobs:
            out.parent.mkdir(parents=True, exist_ok=True)
            sized = re.sub(r'width="[^"]+" height="[^"]+"', f'width="{w}" height="{h}"', markup, count=1)
            page.set_viewport_size({"width": w, "height": h})
            page.set_content('<html><body style="margin:0;background:transparent">'
                             f'<div style="width:{w}px;height:{h}px;line-height:0">{sized}</div></body></html>')
            page.evaluate("document.fonts.ready")
            page.screenshot(path=str(out), omit_background=not opaque, clip={"x": 0, "y": 0, "width": w, "height": h})
            img = Image.open(out)
            (img.convert("RGB") if opaque else img).save(out, optimize=True)
        browser.close()


def write_json(path: Path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2) + "\n")


def main(only_preview: bool = False):
    shutil.rmtree(SVG_OUT, ignore_errors=True)
    SVG_OUT.mkdir(parents=True, exist_ok=True)
    jobs = []

    def job(markup, out, w, h, opaque):
        jobs.append((markup, out, w, h, opaque))

    # iOS + macOS
    appicon = ASSETS / "AppIcon.xcassets" / "AppIcon.appiconset"
    shutil.rmtree(appicon, ignore_errors=True)
    write_json(ASSETS / "AppIcon.xcassets" / "Contents.json", {"info": INFO})
    light, dark, tinted, mac = ios_icon("light"), ios_icon("dark"), ios_icon("tinted"), mac_icon()
    (SVG_OUT / "appicon-ios.svg").write_text(light)
    images = [
        {"filename": "AppIcon-iOS.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "dark"}], "filename": "AppIcon-iOS-Dark.png",
         "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "tinted"}], "filename": "AppIcon-iOS-Tinted.png",
         "idiom": "universal", "platform": "ios", "size": "1024x1024"},
    ]
    job(light, appicon / "AppIcon-iOS.png", 1024, 1024, True)
    job(dark, appicon / "AppIcon-iOS-Dark.png", 1024, 1024, False)
    job(tinted, appicon / "AppIcon-iOS-Tinted.png", 1024, 1024, True)
    for pt in (16, 32, 128, 256, 512):
        for sc in (1, 2):
            fn = f"AppIcon-macOS-{pt}@{sc}x.png"
            images.append({"filename": fn, "idiom": "mac", "scale": f"{sc}x", "size": f"{pt}x{pt}"})
            job(mac, appicon / fn, pt * sc, pt * sc, False)
    write_json(appicon / "Contents.json", {"images": images, "info": INFO})

    # tvOS brand assets
    tvcat = ASSETS / "AppIcon-tvOS.xcassets"
    shutil.rmtree(tvcat, ignore_errors=True)
    write_json(tvcat / "Contents.json", {"info": INFO})
    brand = tvcat / "App Icon & Top Shelf Image.brandassets"
    write_json(brand / "Contents.json", {"assets": [
        {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
        {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
        {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
        {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
    ], "info": INFO})
    order = [{"filename": f"{n}.imagestacklayer"} for n in ("Front", "Middle", "Back")]
    for stack, (w, h), scales in [("App Icon.imagestack", (400, 240), (1, 2)),
                                  ("App Icon - App Store.imagestack", (1280, 768), (1,))]:
        write_json(brand / stack / "Contents.json", {"info": INFO, "layers": order})
        for sc in scales:
            for lname, markup in tv_layers(w * sc, h * sc).items():
                fn = f"{lname}{'' if len(scales) == 1 else f'@{sc}x'}.png"
                job(markup, brand / stack / f"{lname}.imagestacklayer" / "Content.imageset" / fn, w * sc, h * sc, lname == "Back")
        for lname in ("Front", "Middle", "Back"):
            layer = brand / stack / f"{lname}.imagestacklayer"
            write_json(layer / "Contents.json", {"info": INFO})
            imgs = ([{"filename": f"{lname}.png", "idiom": "tv"}] if len(scales) == 1 else
                    [{"filename": f"{lname}@{s}x.png", "idiom": "tv", "scale": f"{s}x"} for s in scales])
            write_json(layer / "Content.imageset" / "Contents.json", {"images": imgs, "info": INFO})
    for setname, (w, h) in [("Top Shelf Image.imageset", (1920, 720)), ("Top Shelf Image Wide.imageset", (2320, 720))]:
        imgs = []
        for sc in (1, 2):
            fn = f"TopShelf{'Wide' if 'Wide' in setname else ''}@{sc}x.png"
            imgs.append({"filename": fn, "idiom": "tv", "scale": f"{sc}x"})
            job(top_shelf(w * sc, h * sc), brand / setname / fn, w * sc, h * sc, True)
        write_json(brand / setname / "Contents.json", {"images": imgs, "info": INFO})

    # In-app mark
    mark_set = ASSETS / "Shared.xcassets" / "BrandMark.imageset"
    shutil.rmtree(mark_set, ignore_errors=True)
    bm = brand_mark()
    (SVG_OUT / "xt-mark.svg").write_text(bm)
    imgs = []
    for sc in (1, 2, 3):
        fn = f"BrandMark@{sc}x.png"
        imgs.append({"filename": fn, "idiom": "universal", "scale": f"{sc}x"})
        job(bm, mark_set / fn, 160 * sc, 160 * sc, False)
    write_json(mark_set / "Contents.json", {"images": imgs, "info": INFO})

    # DMG window background (660 x 400 pt, @1x and @2x)
    for sc, name in ((1, "dmg-background.png"), (2, "dmg-background@2x.png")):
        job(dmg_background(660 * sc, 400 * sc, sc), BRANDING / name, 660 * sc, 400 * sc, True)

    render(jobs)
    print(f"rendered {len(jobs)} images")


if __name__ == "__main__":
    main()
