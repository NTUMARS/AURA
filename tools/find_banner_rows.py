#!/usr/bin/env python3
"""Measure the height of the near-black text banners baked into the
`emergent feature/cooking/*` render frames (a caption plate top and
bottom, ~1024x1024 source).

Method: a caption plate is a solid near-black rectangle with white/
yellow text drawn on it. Black bg pixels dominate most rows inside the
plate, but on some frames a single dense row of Chinese glyphs can
cover close to (or just over) 50% of the row width, so the per-row
MEDIAN is not reliably near 0 on every plate row (verified: one test
frame flipped the median at the row crossing the thickest part of a
subtitle line, splitting the detected band in two). A low percentile
(default 30th) is robust to that: even the densest text row measured
still had >=50% black pixels, so its 30th percentile stays pinned at
~0, while every scene row's 30th percentile sits well above threshold.
This cleanly separates plate rows from scene rows (per-row std-dev
does NOT work here either: text edges make plate rows just as
high-variance as the busy scene).

We scan for the first maximal contiguous run of "median < threshold"
rows anchored near the top of the frame (the top plate) and near the
bottom (the bottom plate). Any thin sliver of scene between the frame
edge and the plate (some renders leave one) is folded into the crop
since ffmpeg's `crop` can only remove a contiguous edge band anyway.

Usage:
    python3 find_banner_rows.py <image.png> [--threshold 5.0] [--margin 0]

Prints TOP=<n> BOT=<n> -- the number of rows to crop off the top and
bottom respectively (`crop=iw:ih-TOP-BOT:0:TOP`) -- plus the raw row
bands found, for a sanity check before trusting the numbers.
"""
import argparse
import sys

from PIL import Image
import numpy as np


def low_percentile_per_row(arr: np.ndarray, pct: float) -> np.ndarray:
    gray = arr.astype(np.float64).mean(axis=2)  # (H, W)
    return np.percentile(gray, pct, axis=1)


def contiguous_run_from_start(mask: np.ndarray) -> int:
    """Length of the leading contiguous True run (0 if mask[0] is False)."""
    idx = np.argmin(mask) if not mask.all() else len(mask)
    return int(idx) if mask[0] else 0


def find_top_band(mask: np.ndarray, scan_window: int) -> tuple[int, int] | None:
    """First contiguous True run whose start lies within scan_window rows
    of the top edge. Returns (start, end) inclusive, or None."""
    window = mask[:scan_window]
    on = np.where(window)[0]
    if len(on) == 0:
        return None
    start = int(on[0])
    end = start
    while end + 1 < len(mask) and mask[end + 1]:
        end += 1
    return start, end


def find_bottom_band(mask: np.ndarray, scan_window: int) -> tuple[int, int] | None:
    h = len(mask)
    window = mask[h - scan_window:]
    on = np.where(window)[0]
    if len(on) == 0:
        return None
    end = h - scan_window + int(on[-1])
    start = end
    while start - 1 >= 0 and mask[start - 1]:
        start -= 1
    return start, end


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--threshold", type=float, default=5.0,
                     help="max per-row percentile brightness to count as banner (default 5.0)")
    ap.add_argument("--percentile", type=float, default=30.0,
                     help="which low percentile of row brightness to test (default 30.0)")
    ap.add_argument("--margin", type=int, default=0,
                     help="extra rows to add to each crop beyond the measured band (default 0)")
    ap.add_argument("--scan-window", type=int, default=300,
                     help="how many rows from each edge to search for the banner band (default 300)")
    args = ap.parse_args()

    im = Image.open(args.image).convert("RGB")
    arr = np.asarray(im)
    h, w, _ = arr.shape

    med = low_percentile_per_row(arr, args.percentile)
    mask = med < args.threshold

    top_band = find_top_band(mask, args.scan_window)
    bot_band = find_bottom_band(mask, args.scan_window)

    top = min(h // 2, (top_band[1] + 1 + args.margin)) if top_band else 0
    bot = min(h // 2, (h - bot_band[0] + args.margin)) if bot_band else 0

    print(f"image: {args.image}  size={w}x{h}")
    print(f"threshold={args.threshold}  margin={args.margin}")
    print(f"top_band(rows)={top_band}  bottom_band(rows)={bot_band}")
    print(f"TOP={top}  BOT={bot}")

    def dump(lo, hi):
        for i in range(max(0, lo), min(h, hi)):
            print(f"  row {i:4d}: p{args.percentile:g}={med[i]:7.2f}")

    print("-- around top band boundary --")
    if top_band:
        dump(top_band[0] - 4, top_band[1] + 5)
    print("-- around bottom band boundary --")
    if bot_band:
        dump(bot_band[0] - 4, bot_band[1] + 5)

    return 0


if __name__ == "__main__":
    sys.exit(main())
