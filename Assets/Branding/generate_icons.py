#!/usr/bin/env python3
"""XT-Player brand generator.

Builds the stylised "X" letterform as SVG (two tapered, glossy blades that flow
left -> right like a play chevron), then renders every app icon the Apple
targets need with headless Chromium (Playwright):

  Assets/AppIcon.xcassets/AppIcon.appiconset              iOS/iPadOS (default, dark, tinted) + macOS
  Assets/AppIcon-tvOS.xcassets/...brandassets             tvOS 3-layer parallax icons + Top Shelf
  Assets/Shared.xcassets/BrandMark.imageset               transparent mark used inside the app
  Assets/Branding/svg/                                   vector masters (mark + iOS icon)

Usage:  python3 Assets/Branding/generate_icons.py
Requires: numpy, playwright (+ `playwright install chromium`).
"""
from __future__ import annotations

import json
import math
import shutil
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "Assets"
SVG_OUT = ASSETS / "Branding" / "svg"

RED = "#FF3B30"
ORANGE = "#FF9500"
DEEP_RED = "#D9150B"
EMBER = "#FFB340"
BG = "#121212"

# ----------------------------------------------------------------------------
# Geometry: tapered ribbons along cubic Bezier centre lines (1024 x 1024 space)
# ----------------------------------------------------------------------------

def _bezier(p, t):
    t = t[:, None]
    return ((1 - t) ** 3) * p[0] + 3 * ((1 - t) ** 2) * t * p[1] + 3 * (1 - t) * t ** 2 * p[2] + t ** 3 * p[3]


def _bezier_d(p, t):
    t = t[:, None]
    return 3 * ((1 - t) ** 2) * (p[1] - p[0]) + 6 * (1 - t) * t * (p[2] - p[1]) + 3 * t ** 2 * (p[3] - p[2])


class Blade:
    """A swoosh: thin tail at t=0, swelling head near t~0.68, sharp tip at t=1."""

    def __init__(self, ctrl, w_max, w_tail=10.0, w_tip=14.0, peak=0.68, samples=220):
        self.p = np.array(ctrl, dtype=float)
        self.t = np.linspace(0.0, 1.0, samples)
        self.c = _bezier(self.p, self.t)
        d = _bezier_d(self.p, self.t)
        d /= np.linalg.norm(d, axis=1)[:, None]
        # left-hand normal == the blade's "upper", light-facing edge
        self.n = np.stack([d[:, 1], -d[:, 0]], axis=1)
        t = self.t
        rise = np.sin(np.clip(t / peak, 0, 1) * math.pi / 2) ** 1.35
        fall = np.cos(np.clip((t - peak) / (1 - peak), 0, 1) * math.pi / 2) ** 0.85
        prof = np.where(t <= peak, w_tail + (w_max - w_tail) * rise, w_tip + (w_max - w_tip) * fall)
        self.w = prof

    def band(self, lo: float, hi: float, grow: float = 0.0) -> str:
        """SVG path of the strip between normalised offsets lo..hi (-1 lower edge, +1 upper edge)."""
        half = self.w[:, None] / 2 + grow
        upper = self.c + self.n * half * hi
        lower = self.c + self.n * half * lo
        pts = np.concatenate([upper, lower[::-1]])
        return "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts) + "Z"

    def outline(self, grow: float = 0.0) -> str:
        return self.band(-1.0, 1.0, grow)

    def centre(self, frac: float):
        i = int(frac * (len(self.t) - 1))
        return self.c[i]


# Front blade "\" : tail top-left -> head bottom-right, bowed toward the top-right.
BLADE_A = Blade([(268, 210), (430, 330), (610, 600), (790, 830)], w_max=176, w_tail=10, w_tip=10, peak=0.40)
# Back blade "/"  : tail bottom-left -> head top-right, bowed toward the bottom-right
# (90 deg rotation of A, so the pair reads as one rotating, forward-moving form).
BLADE_B = Blade([(196, 770), (420, 840), (600, 520), (820, 190)], w_max=158, w_tail=10, w_tip=6, peak=0.58)


def _grad_along(gid: str, blade: Blade, stops):
    (x1, y1), (x2, y2) = blade.p[0], blade.p[3]
    s = "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in stops)
    return (f'<linearGradient id="{gid}" gradientUnits="userSpaceOnUse" '
            f'x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">{s}</linearGradient>')


def _blade_layers(key: str, blade: Blade, stops, gloss: bool = True) -> tuple[str, str]:
    """Return (defs, body) for one glossy blade."""
    defs = [_grad_along(f"g{key}", blade, stops)]
    defs.append(f'<clipPath id="clip{key}"><path d="{blade.outline()}"/></clipPath>')
    body = [f'<path d="{blade.outline()}" fill="url(#g{key})"/>']
    if gloss:
        # tube shading: stacked translucent bands build a smooth cross-section gradient
        shade = []
        for k in range(14):
            f = k / 14
            shade.append(f'<path d="{blade.band(-1.05, -1.0 + 0.9 * (1 - f))}" fill="#5A0600" fill-opacity="0.045"/>')
        light = []
        for k in range(16):
            f = k / 16
            light.append(f'<path d="{blade.band(0.05 + 0.9 * f, 1.05)}" fill="#FFFFFF" fill-opacity="0.05"/>')
        body.append(f'<g clip-path="url(#clip{key})" filter="url(#soft)">{"".join(shade)}{"".join(light)}</g>')
        # chrome specular line hugging the upper edge
        body.append(f'<g clip-path="url(#clip{key})"><path d="{blade.band(0.62, 0.80)}" fill="#FFFFFF" '
                    f'fill-opacity="0.75" filter="url(#spec)"/></g>')
        # thin metallic rim
        defs.append(f'<linearGradient id="rim{key}" x1="0" y1="0" x2="1" y2="1">'
                    f'<stop offset="0" stop-color="#FFE2C0" stop-opacity="0.95"/>'
                    f'<stop offset="0.5" stop-color="#FF8A3D" stop-opacity="0.35"/>'
                    f'<stop offset="1" stop-color="#5C0800" stop-opacity="0.9"/></linearGradient>')
        body.append(f'<path d="{blade.outline()}" fill="none" stroke="url(#rim{key})" stroke-width="2.4"/>')
    return "".join(defs), "".join(body)


FILTERS = """
<filter id="soft" x="-10%" y="-10%" width="120%" height="120%"><feGaussianBlur stdDeviation="2.2"/></filter>
<filter id="spec" x="-10%" y="-10%" width="120%" height="120%"><feGaussianBlur stdDeviation="3.2"/></filter>
<filter id="gap" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="7"/></filter>
<filter id="drop" x="-30%" y="-30%" width="160%" height="160%">
  <feGaussianBlur in="SourceAlpha" stdDeviation="20"/><feOffset dy="22" result="b"/>
  <feFlood flood-color="#000" flood-opacity="0.6"/><feComposite in2="b" operator="in" result="s"/>
  <feMerge><feMergeNode in="s"/><feMergeNode in="SourceGraphic"/></feMerge>
</filter>
<filter id="glow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="60"/></filter>
"""

STOPS_A = [(0, DEEP_RED), (0.42, RED), (0.82, ORANGE), (1, EMBER)]
STOPS_B = [(0, "#B30E06"), (0.45, "#F2301F"), (0.85, "#FF8A00"), (1, EMBER)]


def mark_group(gloss: bool = True, mono: str | None = None) -> tuple[str, str]:
    """The X letterform (both blades + over/under gap). Returns (defs, group)."""
    sa = [(0, mono), (1, mono)] if mono else STOPS_A
    sb = [(0, mono), (1, mono)] if mono else STOPS_B
    da, ba = _blade_layers("A", BLADE_A, sa, gloss)
    db, bb = _blade_layers("B", BLADE_B, sb, gloss)
    # Dark halo of the front blade, clipped to the back blade -> reads as the front one passing over.
    gap = (f'<clipPath id="clipBgap"><path d="{BLADE_B.outline()}"/></clipPath>'
           f'<g clip-path="url(#clipBgap)"><path d="{BLADE_A.outline(grow=14)}" fill="#000" '
           f'fill-opacity="{0.55 if not mono else 0.0}" filter="url(#gap)"/></g>')
    if mono:
        gap = (f'<clipPath id="clipBgap"><path d="{BLADE_B.outline()}"/></clipPath>'
               f'<g clip-path="url(#clipBgap)"><path d="{BLADE_A.outline(grow=12)}" fill="#000"/></g>')
    return FILTERS + da + db, f'<g>{bb}{gap}{ba}</g>'


def background(w: int, h: int, glass: bool = True, glow: bool = True) -> tuple[str, str]:
    defs = (f'<radialGradient id="bg" cx="0.32" cy="0.22" r="1.05">'
            f'<stop offset="0" stop-color="#303034"/><stop offset="0.45" stop-color="#18181A"/>'
            f'<stop offset="1" stop-color="#080809"/></radialGradient>'
            f'<radialGradient id="ember" cx="0.5" cy="0.5" r="0.5">'
            f'<stop offset="0" stop-color="#FF5A1F" stop-opacity="0.55"/>'
            f'<stop offset="1" stop-color="#FF3B30" stop-opacity="0"/></radialGradient>'
            f'<linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">'
            f'<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.10"/>'
            f'<stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0.03"/>'
            f'<stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>'
            f'<radialGradient id="vig" cx="0.5" cy="0.5" r="0.75">'
            f'<stop offset="0.6" stop-color="#000" stop-opacity="0"/>'
            f'<stop offset="1" stop-color="#000" stop-opacity="0.45"/></radialGradient>')
    body = [f'<rect width="{w}" height="{h}" fill="url(#bg)"/>']
    s = min(w, h)
    if glow:
        body.append(f'<ellipse cx="{w / 2}" cy="{h / 2 + s * 0.02}" rx="{s * 0.42}" ry="{s * 0.40}" fill="url(#ember)"/>')
    if glass:
        # frosted-glass sheen sweeping from the top-left corner, plus a soft vignette
        body.append(f'<path d="M0,0 H{w} V{h * 0.30} C{w * 0.70},{h * 0.44} {w * 0.36},{h * 0.30} 0,{h * 0.52} Z" '
                    f'fill="url(#sheen)"/>')
        body.append(f'<rect width="{w}" height="{h}" fill="url(#vig)"/>')
    return defs, "".join(body)


def svg(w: int, h: int, defs: str, body: str) -> str:
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">'
            f'<defs>{defs}</defs>{body}</svg>')


def placed_mark(scale: float, cx: float, cy: float, gloss=True, mono=None, shadow=True) -> tuple[str, str]:
    d, g = mark_group(gloss, mono)
    tx, ty = cx - 512 * scale, cy - 512 * scale
    filt = ' filter="url(#drop)"' if shadow else ""
    return d, f'<g transform="translate({tx:.2f},{ty:.2f}) scale({scale:.4f})"><g{filt}>{g}</g></g>'


# ----------------------------------------------------------------------------
# Compositions
# ----------------------------------------------------------------------------

def ios_icon(appearance: str = "light") -> str:
    W = 1024
    if appearance == "tinted":
        d, m = placed_mark(0.86, 512, 512, gloss=False, mono="#FFFFFF", shadow=False)
        return svg(W, W, d, f'<rect width="{W}" height="{W}" fill="#000"/>{m}')
    if appearance == "dark":
        d, m = placed_mark(0.86, 512, 512)
        return svg(W, W, d, m)  # transparent: iOS supplies the dark backdrop
    bd, bb = background(W, W)
    d, m = placed_mark(0.84, 512, 516)
    return svg(W, W, bd + d, bb + m)


def mac_icon() -> str:
    # macOS icons are not masked: draw the squircle body (824pt on 1024 grid) with its own shadow.
    W, S, R = 1024, 824, 185
    o = (W - S) / 2
    bd, bb = background(S, S)
    d, m = placed_mark(0.66, S / 2, S / 2 + 6)
    clip = f'<clipPath id="sq"><rect x="0" y="0" width="{S}" height="{S}" rx="{R}"/></clipPath>'
    shadow = (f'<filter id="macshadow" x="-20%" y="-20%" width="140%" height="140%">'
              f'<feGaussianBlur in="SourceAlpha" stdDeviation="14"/><feOffset dy="12"/>'
              f'<feComponentTransfer><feFuncA type="linear" slope="0.45"/></feComponentTransfer>'
              f'<feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>')
    body = (f'<g transform="translate({o},{o - 10})" filter="url(#macshadow)">'
            f'<g clip-path="url(#sq)">{bb}{m}</g>'
            f'<rect x="1" y="1" width="{S - 2}" height="{S - 2}" rx="{R}" fill="none" stroke="#FFFFFF" stroke-opacity="0.12" stroke-width="2"/></g>')
    return svg(W, W, bd + d + clip + shadow, body)


def tv_layers(w: int, h: int) -> dict[str, str]:
    """Back = dark glass, Middle = X letterform, Front = glossy overlay (all full-size)."""
    bd, bb = background(w, h, glass=True, glow=True)
    scale = h / 1024 * 1.06
    d, m = placed_mark(scale, w / 2, h / 2 + h * 0.01)
    gloss_defs = (f'<linearGradient id="fg" x1="0" y1="0" x2="1" y2="1">'
                  f'<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.0"/>'
                  f'<stop offset="0.38" stop-color="#FFFFFF" stop-opacity="0.0"/>'
                  f'<stop offset="0.47" stop-color="#FFFFFF" stop-opacity="0.15"/>'
                  f'<stop offset="0.53" stop-color="#FFFFFF" stop-opacity="0.05"/>'
                  f'<stop offset="0.60" stop-color="#FFFFFF" stop-opacity="0.0"/></linearGradient>'
                  f'<radialGradient id="fspark" cx="0.5" cy="0.5" r="0.5">'
                  f'<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.9"/>'
                  f'<stop offset="0.25" stop-color="#FFE7C2" stop-opacity="0.35"/>'
                  f'<stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient>')
    a_hi = BLADE_A.centre(0.30)
    sx, sy = w / 2 - 512 * scale + a_hi[0] * scale, h / 2 + h * 0.01 - 512 * scale + a_hi[1] * scale
    front = (f'<rect width="{w}" height="{h}" fill="url(#fg)"/>'
             f'<ellipse cx="{sx:.1f}" cy="{sy:.1f}" rx="{h * 0.16:.1f}" ry="{h * 0.05:.1f}" '
             f'transform="rotate(38 {sx:.1f} {sy:.1f})" fill="url(#fspark)"/>')
    return {
        "Back": svg(w, h, bd, bb),
        "Middle": svg(w, h, d, m),
        "Front": svg(w, h, gloss_defs, front),
    }


def top_shelf(w: int, h: int) -> str:
    bd, bb = background(w, h, glass=False, glow=False)
    s = h / 720
    d, m = placed_mark(0.48 * s, w * 0.5 - 330 * s, h / 2 + 4 * s)
    glow = (f'<radialGradient id="tsg" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="#FF5A1F" stop-opacity="0.45"/>'
            f'<stop offset="1" stop-color="#FF3B30" stop-opacity="0"/></radialGradient>'
            f'<linearGradient id="word" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#FFFFFF"/>'
            f'<stop offset="1" stop-color="#FFD9B8"/></linearGradient>')
    text = (f'<text x="{w * 0.5 - 70 * s}" y="{h / 2 + 34 * s}" font-family="Inter Display, Inter, SF Pro Display, sans-serif" '
            f'font-weight="800" font-size="{124 * s}" letter-spacing="{-2 * s}" fill="url(#word)">XT-Player</text>'
            f'<text x="{w * 0.5 - 64 * s}" y="{h / 2 + 96 * s}" font-family="Inter, sans-serif" font-weight="500" '
            f'font-size="{30 * s}" letter-spacing="{8 * s}" fill="#FFFFFF" fill-opacity="0.55">4K · HDR · DOLBY VISION · LOSSLESS</text>')
    body = bb + (f'<ellipse cx="{w * 0.5 - 330 * s}" cy="{h / 2}" rx="{300 * s}" ry="{300 * s}" fill="url(#tsg)"/>') + m + text
    return svg(w, h, bd + d + glow, body)


def brand_mark() -> str:
    d, m = placed_mark(1.0, 512, 500, shadow=False)
    return svg(1024, 1024, d, m)


# ----------------------------------------------------------------------------
# Rendering + asset catalogs
# ----------------------------------------------------------------------------

def render(jobs: list[tuple[str, Path, int, int, bool]]):
    """Rasterise each SVG at exactly w x h px. Opaque images get their alpha channel removed
    (App Store icons and tvOS back layers must not be transparent)."""
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
            page.screenshot(path=str(out), omit_background=not opaque,
                            clip={"x": 0, "y": 0, "width": w, "height": h})
            if opaque:
                Image.open(out).convert("RGB").save(out, optimize=True)
            else:
                Image.open(out).save(out, optimize=True)
        browser.close()


def write_json(path: Path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2) + "\n")


INFO = {"author": "xcode", "version": 1}


def main():
    shutil.rmtree(SVG_OUT, ignore_errors=True)
    SVG_OUT.mkdir(parents=True, exist_ok=True)
    jobs = []

    def job(markup, out, w, h, opaque):
        jobs.append((markup, out, w, h, opaque))

    # --- iOS + macOS AppIcon -------------------------------------------------
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
        for scale in (1, 2):
            px = pt * scale
            fn = f"AppIcon-macOS-{pt}@{scale}x.png"
            images.append({"filename": fn, "idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}"})
            job(mac, appicon / fn, px, px, False)
    write_json(appicon / "Contents.json", {"images": images, "info": INFO})

    # --- tvOS brand assets (3-layer parallax) -------------------------------
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
    layers_order = [{"filename": f"{n}.imagestacklayer"} for n in ("Front", "Middle", "Back")]
    for stack, (w, h), scales in [("App Icon.imagestack", (400, 240), (1, 2)),
                                  ("App Icon - App Store.imagestack", (1280, 768), (1,))]:
        write_json(brand / stack / "Contents.json", {"info": INFO, "layers": layers_order})
        for scale in scales:
            for lname, markup in tv_layers(w * scale, h * scale).items():
                fn = f"{lname}{'' if len(scales) == 1 else f'@{scale}x'}.png"
                job(markup, brand / stack / f"{lname}.imagestacklayer" / "Content.imageset" / fn,
                    w * scale, h * scale, lname == "Back")
        for lname in ("Front", "Middle", "Back"):
            layer = brand / stack / f"{lname}.imagestacklayer"
            write_json(layer / "Contents.json", {"info": INFO})
            if len(scales) == 1:
                imgs = [{"filename": f"{lname}.png", "idiom": "tv"}]
            else:
                imgs = [{"filename": f"{lname}@{s}x.png", "idiom": "tv", "scale": f"{s}x"} for s in scales]
            write_json(layer / "Content.imageset" / "Contents.json", {"images": imgs, "info": INFO})
    for setname, (w, h) in [("Top Shelf Image.imageset", (1920, 720)), ("Top Shelf Image Wide.imageset", (2320, 720))]:
        imgs = []
        for s in (1, 2):
            fn = f"TopShelf{'Wide' if 'Wide' in setname else ''}@{s}x.png"
            imgs.append({"filename": fn, "idiom": "tv", "scale": f"{s}x"})
            markup = top_shelf(w * s, h * s)
            job(markup, brand / setname / fn, w * s, h * s, True)
        write_json(brand / setname / "Contents.json", {"images": imgs, "info": INFO})

    # --- In-app brand mark ---------------------------------------------------
    shared = ASSETS / "Shared.xcassets"
    mark_set = shared / "BrandMark.imageset"
    shutil.rmtree(mark_set, ignore_errors=True)
    bm = brand_mark()
    (SVG_OUT / "xt-mark.svg").write_text(bm)
    imgs = []
    for s in (1, 2, 3):
        fn = f"BrandMark@{s}x.png"
        imgs.append({"filename": fn, "idiom": "universal", "scale": f"{s}x"})
        job(bm, mark_set / fn, 160 * s, 160 * s, False)
    write_json(mark_set / "Contents.json", {"images": imgs, "info": INFO})

    render(jobs)
    print(f"rendered {len(jobs)} images")


if __name__ == "__main__":
    main()
