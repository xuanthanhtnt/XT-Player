#!/usr/bin/env python3
"""XT-Player brand generator.

The mark: a twisted green ribbon forming an "X"; each of its four arms is a fan of three paper-like
layers (light to deep green) with soft inter-layer shadows, on a clean light ground.
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
# The mark: a twisted ribbon "X" whose four arms are fanned, paper-like layers
# (1024 x 1024 design space)
# ----------------------------------------------------------------------------

MARK = dict(L=176, R=848, T=170, B=854, W=262, pinch=0.12, power=0.6, fractions=(1.0, 0.70, 0.42))

# Layer colours per arm, widest (bottom) to narrowest (top).
PALETTE = {
    "a1": ["#1C9C5A", "#3DC377", "#8DEBA9"],   # "\\" top-left (behind)
    "a2": ["#0A6838", "#14904F", "#3BBE70"],   # "\\" bottom-right (the ribbon's back face)
    "b1": ["#22A955", "#5BD47A", "#C8F59E"],   # "/" top-right (front)
    "b2": ["#085C30", "#118342", "#2FAE5E"],   # "/" bottom-left (back face)
}


def _path(points) -> str:
    return "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in points) + "Z"


def _arm(start, end, first_half: bool, fraction: float, anchor_side: int, n: int = 120):
    """Half of a twisted ribbon (terminal -> pinch), narrowed to `fraction` of its width while the
    edge `anchor_side` (-1 left, +1 right) stays put, so successive layers fan out from that edge."""
    W, pinch, power = MARK["W"], MARK["pinch"], MARK["power"]
    t = np.linspace(0, 0.5, n) if first_half else np.linspace(0.5, 1, n)
    c = np.outer(1 - t, start) + np.outer(t, end)
    w = W * (pinch + (1 - pinch) * np.abs(2 * t - 1) ** power)
    fixed = c[:, 0] + anchor_side * w / 2
    free = fixed - anchor_side * w * fraction
    return np.concatenate([np.stack([fixed, c[:, 1]], 1), np.stack([free, c[:, 1]], 1)[::-1]])


def _arms():
    L, R, T, B, W = (MARK[k] for k in ("L", "R", "T", "B", "W"))
    back = ((L + W / 2, T), (R - W / 2, B))    # "\\"
    front = ((R - W / 2, T), (L + W / 2, B))   # "/"
    # drawn back-to-front; layers hug each arm's outer edge
    return [("a1", back, True, -1), ("a2", back, False, +1), ("b2", front, False, -1), ("b1", front, True, +1)]


FILTERS = """
<filter id="soft" x="-10%" y="-10%" width="120%" height="120%"><feGaussianBlur stdDeviation="3"/></filter>
<filter id="sheen" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="11"/></filter>
<filter id="layer" x="-30%" y="-30%" width="160%" height="160%">
  <feGaussianBlur in="SourceAlpha" stdDeviation="7"/><feOffset dy="6" result="b"/>
  <feFlood flood-color="#012A14" flood-opacity="0.32"/><feComposite in2="b" operator="in" result="s"/>
  <feMerge><feMergeNode in="s"/><feMergeNode in="SourceGraphic"/></feMerge>
</filter>
<filter id="drop" x="-30%" y="-30%" width="160%" height="160%">
  <feGaussianBlur in="SourceAlpha" stdDeviation="18"/><feOffset dy="22" result="b"/>
  <feFlood flood-color="#0A4A26" flood-opacity="0.24"/><feComposite in2="b" operator="in" result="s"/>
  <feMerge><feMergeNode in="s"/><feMergeNode in="SourceGraphic"/></feMerge>
</filter>
<linearGradient id="shine" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.45"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
</linearGradient>
"""


def _shine(defs: list[str]) -> str:
    """Soft top-light on the two upper arms (also used alone as the tvOS gloss layer)."""
    L, R, T = MARK["L"], MARK["R"], MARK["T"]
    out = []
    for key, (s, e), first, side in _arms():
        if not first:
            continue
        top = _arm(s, e, first, MARK["fractions"][-1], side)
        defs.append(f'<clipPath id="clip-{key}"><path d="{_path(top)}"/></clipPath>')
        out.append(f'<g clip-path="url(#clip-{key})"><rect x="{L - 20}" y="{T - 10}" width="{R - L + 40}" height="200" fill="url(#shine)"/></g>')
    return "".join(out)


def mark_group(mono: str | None = None, gloss: bool = True) -> tuple[str, str]:
    defs: list[str] = [FILTERS]
    body = []
    for key, (s, e), first, side in _arms():
        layers = []
        for i, fraction in enumerate(MARK["fractions"]):
            poly = _arm(s, e, first, fraction, side)
            if mono:
                layers.append(f'<path d="{_path(poly)}" fill="{mono}" fill-opacity="{0.45 + 0.2 * i:.2f}"/>')
                continue
            effect = ' filter="url(#layer)"' if i > 0 else ""
            layers.append(f'<path d="{_path(poly)}" fill="{PALETTE[key][i]}"{effect}/>')
            if i > 0:  # light catching the paper edge
                edge = poly[len(poly) // 2:]
                layers.append('<path d="M' + " L".join(f"{x:.1f},{y:.1f}" for x, y in edge) +
                              '" fill="none" stroke="#F4FFEC" stroke-opacity="0.45" stroke-width="1.6"/>')
        body.append(f'<g>{"".join(layers)}</g>')
    if gloss and not mono:
        body.append(_shine(defs))
    return "".join(defs), f'<g>{"".join(body)}</g>'


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
    """Back = light ground, Middle = the ribbon X, Front = its top-light (moves separately in parallax)."""
    bd, bb = background(w, h)
    scale = h / 1024 * 1.12
    cy = h / 2 + h * 0.015
    d, m = placed_mark(scale, w / 2, cy, gloss=False)
    tx, ty = w / 2 - 512 * scale, cy - 512 * scale
    shine_defs: list[str] = [FILTERS]
    shine = _shine(shine_defs)
    front = f'<g transform="translate({tx:.2f},{ty:.2f}) scale({scale:.4f})">{shine}</g>'
    return {"Back": svg(w, h, bd, bb), "Middle": svg(w, h, d, m), "Front": svg(w, h, "".join(shine_defs), front)}


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
