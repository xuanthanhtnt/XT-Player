#!/usr/bin/env python3
"""XT-Player brand generator.

The mark is the designer's artwork (Assets/Branding/xt-mark-source.png), cut out of its background
by prepare_mark.py into xt-mark.png and placed on each icon's ground.
Every app icon the Apple targets need is rendered from this one description with headless
Chromium (Playwright):

  Assets/AppIcon.xcassets/AppIcon.appiconset        iOS/iPadOS (default, dark, tinted) + macOS
  Assets/AppIcon-tvOS.xcassets/...brandassets       tvOS 3-layer parallax icons + Top Shelf
  Assets/Shared.xcassets/BrandMark.imageset         transparent mark used inside the app
  Assets/Branding/dmg-background*.png               macOS installer (DMG) window background
  Assets/Branding/svg/                              vector masters (mark + iOS icon)

Usage:  python3 Assets/Branding/generate_icons.py
Requires: numpy, pillow, playwright (+ `playwright install chromium`); run prepare_mark.py first.
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
# The mark: the designer's artwork (Assets/Branding/xt-mark.png, cut out by prepare_mark.py),
# embedded as an image so every icon is rendered from the original pixels.
# ----------------------------------------------------------------------------

MARK_PNG = BRANDING / "xt-mark.png"
MARK_WIDTH = 720  # width in the 1024-unit design box at scale 1


def _mark_data():
    import base64

    from PIL import Image

    with Image.open(MARK_PNG) as im:
        w, h = im.size
    return "data:image/png;base64," + base64.b64encode(MARK_PNG.read_bytes()).decode(), w / h


_MARK_URI, _MARK_ASPECT = None, 1.0

FILTERS = """
<filter id="soft" x="-10%" y="-10%" width="120%" height="120%"><feGaussianBlur stdDeviation="3"/></filter>
<filter id="sheen" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="14"/></filter>
<filter id="drop" x="-30%" y="-30%" width="160%" height="160%">
  <feGaussianBlur in="SourceAlpha" stdDeviation="18"/><feOffset dy="22" result="b"/>
  <feFlood flood-color="#0A4A26" flood-opacity="0.24"/><feComposite in2="b" operator="in" result="s"/>
  <feMerge><feMergeNode in="s"/><feMergeNode in="SourceGraphic"/></feMerge>
</filter>
<filter id="mono" color-interpolation-filters="sRGB">
  <feColorMatrix type="matrix" values="0.30 0.59 0.11 0 0  0.30 0.59 0.11 0 0  0.30 0.59 0.11 0 0  0 0 0 1 0"/>
  <feComponentTransfer><feFuncR type="gamma" amplitude="1.25" exponent="0.55"/><feFuncG type="gamma" amplitude="1.25" exponent="0.55"/>
  <feFuncB type="gamma" amplitude="1.25" exponent="0.55"/></feComponentTransfer>
</filter>
"""


def _mark_image(x: float, y: float, w: float, h: float, mono: bool) -> str:
    global _MARK_URI, _MARK_ASPECT
    if _MARK_URI is None:
        _MARK_URI, _MARK_ASPECT = _mark_data()
    filt = ' filter="url(#mono)"' if mono else ""
    return f'<image href="{_MARK_URI}" x="{x:.2f}" y="{y:.2f}" width="{w:.2f}" height="{h:.2f}" preserveAspectRatio="xMidYMid meet"{filt}/>'


def mark_box(scale: float, cx: float, cy: float) -> tuple[float, float, float, float]:
    global _MARK_URI, _MARK_ASPECT
    if _MARK_URI is None:
        _MARK_URI, _MARK_ASPECT = _mark_data()
    w = MARK_WIDTH * scale
    h = w / _MARK_ASPECT
    return cx - w / 2, cy - h / 2, w, h


def placed_mark(scale, cx, cy, mono=None, gloss=True, shadow=True):
    x, y, w, h = mark_box(scale, cx, cy)
    filt = ' filter="url(#drop)"' if shadow else ""
    return FILTERS, f'<g{filt}>{_mark_image(x, y, w, h, bool(mono))}</g>'


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
    """Back = light ground, Middle = the mark, Front = a soft light sweep (moves separately in parallax)."""
    bd, bb = background(w, h)
    scale = h / 1024 * 1.10
    d, m = placed_mark(scale, w / 2, h / 2 + h * 0.01)
    x, y, mw, mh = mark_box(scale, w / 2, h / 2 + h * 0.01)
    front = (f'<ellipse cx="{x + mw * 0.42:.1f}" cy="{y + mh * 0.40:.1f}" rx="{mw * 0.30:.1f}" ry="{mh * 0.07:.1f}" '
             f'transform="rotate(-24 {x + mw * 0.42:.1f} {y + mh * 0.40:.1f})" fill="#FFFFFF" fill-opacity="0.32" filter="url(#sheen)"/>')
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
    d, m = placed_mark(0.10 * s, 48 * s, 46 * s, shadow=False)
    arrow = (f'<path d="M{262 * s},{190 * s} C{300 * s},{172 * s} {360 * s},{172 * s} {398 * s},{190 * s}" fill="none" '
             f'stroke="#34C759" stroke-width="{5 * s}" stroke-linecap="round"/>'
             f'<path d="M{388 * s},{176 * s} L{404 * s},{193 * s} L{382 * s},{200 * s}" fill="none" stroke="#34C759" '
             f'stroke-width="{5 * s}" stroke-linecap="round" stroke-linejoin="round"/>')
    text = (f'<text x="{94 * s}" y="{54 * s}" font-family="{WORD_FONT}" font-weight="800" font-size="{26 * s}" fill="#0F2A18">XT-Player</text>'
            f'<text x="{w / 2}" y="{352 * s}" text-anchor="middle" font-family="Inter, sans-serif" font-weight="500" '
            f'font-size="{15 * s}" fill="#4B5B50">Kéo XT-Player vào Applications để cài đặt</text>')
    return svg(w, h, bd + d, bb + m + arrow + text)


def brand_mark() -> str:
    d, m = placed_mark(1.38, 512, 512, shadow=False)
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
