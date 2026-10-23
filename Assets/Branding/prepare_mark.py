#!/usr/bin/env python3
"""Cuts the XT-Player mark out of its artwork file.

Input : Assets/Branding/xt-mark-source.png   (the logo on its light background, as designed)
Output: Assets/Branding/xt-mark.png          (transparent, trimmed, edge-decontaminated)

The background is removed by flood-filling from the image borders with a small neighbour tolerance,
so light areas *inside* the X (its pale ribbon highlight) are kept. Edge pixels that still carry
background tint are re-coloured from the interior and the matte gets a 1 px anti-aliasing feather.

Usage: python3 Assets/Branding/prepare_mark.py   (needs opencv-python + numpy)
"""
from pathlib import Path

import cv2
import numpy as np

HERE = Path(__file__).resolve().parent
SOURCE = HERE / "xt-mark-source.png"
OUTPUT = HERE / "xt-mark.png"


def main(tolerance: int = 6, padding: int = 6) -> None:
    img = cv2.imread(str(SOURCE), cv2.IMREAD_COLOR)
    h, w = img.shape[:2]

    # 1. background = everything reachable from the borders through near-identical neighbours
    blur = cv2.GaussianBlur(img, (3, 3), 0)
    flood = np.zeros((h + 2, w + 2), np.uint8)
    flags = 4 | cv2.FLOODFILL_MASK_ONLY | (255 << 8)
    seeds = [(x, 0) for x in range(0, w, 8)] + [(x, h - 1) for x in range(0, w, 8)] + \
            [(0, y) for y in range(0, h, 8)] + [(w - 1, y) for y in range(0, h, 8)]
    for sx, sy in seeds:
        if flood[sy + 1, sx + 1] == 0:
            cv2.floodFill(blur, flood, (sx, sy), 0, (tolerance,) * 3, (tolerance,) * 3, flags)
    background = flood[1:-1, 1:-1] > 0

    # 2. drop the 1 px anti-aliased halo, then feather the matte back for smooth edges
    foreground = (~background).astype(np.uint8) * 255
    foreground = cv2.erode(foreground, np.ones((3, 3), np.uint8), iterations=1)
    alpha = cv2.GaussianBlur(foreground, (3, 3), 0.8)

    # 3. de-fringe: every pixel outside the solid interior (edge band + background) is re-coloured
    #    from interior colours only, so no background tint bleeds into the anti-aliased edge
    interior = cv2.erode(foreground, np.ones((3, 3), np.uint8), iterations=2)
    outside = (interior == 0).astype(np.uint8) * 255
    clean = cv2.inpaint(img, outside, 3, cv2.INPAINT_TELEA)

    rgba = cv2.cvtColor(clean, cv2.COLOR_BGR2BGRA)
    rgba[:, :, 3] = alpha

    # 4. trim to content
    ys, xs = np.nonzero(alpha > 8)
    y0, y1 = max(0, ys.min() - padding), min(h, ys.max() + padding + 1)
    x0, x1 = max(0, xs.min() - padding), min(w, xs.max() + padding + 1)
    cv2.imwrite(str(OUTPUT), rgba[y0:y1, x0:x1], [cv2.IMWRITE_PNG_COMPRESSION, 9])
    print(f"{OUTPUT.name}: {x1 - x0}x{y1 - y0}")


if __name__ == "__main__":
    main()
