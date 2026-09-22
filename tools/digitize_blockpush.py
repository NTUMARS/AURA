#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""digitize_blockpush.py -- digitize the Block Push "Evolution of inferred
uncertainty" curve (paper fig. S2C, appen_wei_BP) out of the rasterized
appendix figure and write assets/data/blockpush_uncertainty.json in the same
`aura.uncertainty-curve/1` schema that scripts/uncertainty-live.js consumes.

Two modes ("Orange" / "Purple" = which block gets pushed), each a mean line
with a faint +/-s.d. band, over normalized task progress (x) vs. inferred
uncertainty degree (y). Calibration constants below were measured by hand
against assets/images/appendix/appen_wei_BP.png (2353x1455); treat them as
fixed.

Usage:
    python3 tools/digitize_blockpush.py [--src PATH] [--out PATH] [--n 200] [--debug PATH]
"""
import argparse
import datetime
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
from digitize_curve import (  # noqa: E402
    color_mask,
    extract_band_rows,
    find_runs,
    local_median_fill,
    moving_mean,
    moving_median,
    to_compact_json,
)

# =============================================================================
# Calibration (appen_wei_BP.png, panel C)
#   x tick-label centres: 0.0 -> col 202, 1.0 -> col 2216
#   y tick marks:         0.0 -> row 1216.5, 0.4 -> row 766.5
# =============================================================================
COL0, COL_SCALE = 202.0, 2014.0
ROW0, ROW_SCALE = 1216.5, 1125.0


def col_to_x(col):
    return (col - COL0) / COL_SCALE


def row_to_y(row):
    return (ROW0 - row) / ROW_SCALE


def x_to_col(x):
    return x * COL_SCALE + COL0


def y_to_row(y):
    return ROW0 - y * ROW_SCALE


ROW_MIN, ROW_MAX = 745, 1265          # chart interior (0.4 tick .. just above the axis)
COL_MIN, COL_MAX = 204, 2214

LINE_TOL = 26
CONTINUITY_TOL = 36
BAND_MERGE_GAP = 10
SMOOTH_MEDIAN_WIN = 7
SMOOTH_MEAN_WIN = 11

MODES = {
    "orange": {
        "label": "Orange",
        "line_color": (0xFC, 0xD8, 0x92),   # pale gold stroke
        "n_rollouts": 11,
        "clip": "assets/videos/blockpush/up.mp4",
        # clip-time fraction -> curve progress; the arm reaches the two blocks
        # (branch) at ~4.0 s of 9.3 s and the paper's branch peak sits at 0.36
        "align": [[0, 0], [0.43, 0.36], [1, 1]],
    },
    "purple": {
        "label": "Purple",
        "line_color": (0x58, 0xB0, 0xA8),   # teal stroke
        "n_rollouts": 9,
        "clip": "assets/videos/blockpush/down.mp4",
        "align": [[0, 0], [0.45, 0.36], [1, 1]],
    },
}

# Robot insets (stroke-coloured frames + dashed arrows), legend key lines.
# (col0, col1, row0, row1) inclusive.
EXCLUDE_BOXES = [
    (350, 785, 745, 1012),      # grey-framed inset (branch moment)
    (1438, 1788, 745, 1044),    # orange-framed inset (outcome, orange)
    (1826, 2184, 745, 1048),    # teal-framed inset (outcome, purple)
    (540, 1100, 1176, 1212),    # "Orange —— Purple" legend
]

# Grey "branch" rectangle spans these columns; the background is grey there.
GREY_COLS = (766, 1310)

PHASES = [
    {"id": "branch", "label": "Branch point", "range": [0.28, 0.55]},
]

N_DEFAULT = 200
SRC_DEFAULT = "assets/images/appendix/appen_wei_BP.png"
OUT_DEFAULT = "assets/data/blockpush_uncertainty.json"


def build_exclude_mask(shape):
    mask = np.zeros(shape, dtype=bool)
    for c0, c1, r0, r1 in EXCLUDE_BOXES:
        mask[r0:r1 + 1, c0:c1 + 1] = True
    return mask


def extract_mean_rows(line_mask, anchor_row, fallback=None):
    """Walk columns left->right picking the stroke run nearest the previous
    pick. Gaps are filled from `fallback` (the other mode's rows) where the
    linear interpolation across the gap stays within a stroke width of it,
    i.e. where the two curves coincide and only one stroke is visible; other
    gaps are interpolated linearly."""
    n = COL_MAX - COL_MIN + 1
    rows = np.full(n, np.nan)
    prev = None
    for i, col in enumerate(range(COL_MIN, COL_MAX + 1)):
        runs = find_runs(line_mask[ROW_MIN:ROW_MAX + 1, col])
        if not runs:
            continue
        meds = [ROW_MIN + (s + e) / 2.0 for s, e in runs]
        ref = anchor_row if prev is None else prev
        j = int(np.argmin([abs(m - ref) for m in meds]))
        if prev is None or abs(meds[j] - prev) <= CONTINUITY_TOL:
            rows[i] = meds[j]
            prev = meds[j]
    idx = np.arange(n)
    good = ~np.isnan(rows)
    if good.sum() < n * 0.4:
        raise RuntimeError(f"mean line found in only {good.sum()} / {n} columns")
    filled = np.interp(idx, idx[good], rows[good])
    if fallback is not None:
        use_fb = ~good & (np.abs(filled - fallback) <= 14)
        filled = np.where(use_fb, fallback, filled)
    return filled, good


def tint_mask(arr, line_color, exclude, alpha_lo=0.04, alpha_hi=0.75):
    """Pixels that read as `line_color` blended over the local background at
    alpha in [alpha_lo, alpha_hi]. The background is white outside the grey
    branch rectangle and light grey inside it; the tint is judged on the two
    channels where the stroke departs most from the background."""
    h, w, _ = arr.shape
    bg = np.full((h, w, 3), 255.0)
    bg[:, GREY_COLS[0]:GREY_COLS[1] + 1, :] = np.array([237.0, 238.0, 240.0])
    line = np.array(line_color, dtype=float)
    num = bg - arr.astype(float)             # how far the pixel moved from the bg
    den = bg - line                          # how far the pure stroke is from the bg
    strong = np.argsort(-np.abs(den), axis=-1)[..., :2]   # 2 most informative channels
    a = np.take_along_axis(num, strong, -1) / np.take_along_axis(den, strong, -1)
    ok = (a.min(-1) >= alpha_lo) & (a.max(-1) <= alpha_hi) & (np.abs(a[..., 0] - a[..., 1]) <= 0.12)
    # the third channel must not move against the tint direction by much
    weak = np.argsort(-np.abs(den), axis=-1)[..., 2:3]
    w_num = np.take_along_axis(num, weak, -1)[..., 0]
    ok &= np.abs(w_num) <= 14
    return ok & ~exclude


def smooth(a):
    return moving_mean(moving_median(a, SMOOTH_MEDIAN_WIN), SMOOTH_MEAN_WIN)


def make_debug_overlay(img, progress, per_mode, path):
    im = img.copy().convert("RGB")
    d = ImageDraw.Draw(im)
    for c0, c1, r0, r1 in EXCLUDE_BOXES:
        d.rectangle([c0, r0, c1, r1], outline=(255, 0, 255), width=2)
    for name, m in per_mode.items():
        for key, colr, wdt in (("hi", (255, 140, 0), 2), ("lo", (255, 140, 0), 2), ("mean", (255, 0, 0), 3)):
            pts = [(x_to_col(x), y_to_row(y)) for x, y in zip(progress, m[key])]
            d.line(pts, fill=colr, width=wdt)
    path.parent.mkdir(parents=True, exist_ok=True)
    im.save(path)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--src", default=SRC_DEFAULT)
    ap.add_argument("--out", default=OUT_DEFAULT)
    ap.add_argument("--n", type=int, default=N_DEFAULT)
    ap.add_argument("--debug", default=None)
    args = ap.parse_args()

    root = Path(__file__).resolve().parent.parent
    resolve = lambda p: Path(p) if Path(p).is_absolute() else root / p  # noqa: E731
    src_path, out_path = resolve(args.src), resolve(args.out)

    img = Image.open(src_path).convert("RGB")
    arr = np.array(img)
    exclude = build_exclude_mask(arr.shape[:2])

    x_grid = np.linspace(0.0, 1.0, args.n)
    x_cols = col_to_x(np.arange(COL_MIN, COL_MAX + 1))

    # The orange stroke is drawn semi-transparent: (252,216,146) over white,
    # (230,204,146) over the grey rectangle, other blends over the teal band.
    # Match it by hue/saturation instead of a single RGB point.
    # Where it crosses the teal band it survives only as a "yellowness" of
    # ~20-35 ((R+G)/2 - B), so match on that rather than a single RGB point.
    r, g, b = (arr[..., i].astype(int) for i in range(3))
    yellowness = (r + g) // 2 - b
    orange_mask = (yellowness >= 16) & (r >= 195) & (g >= 190) & (r >= g - 6) & (b <= 200)
    line_masks = {
        "orange": orange_mask & ~exclude,
        "purple": color_mask(arr, MODES["purple"]["line_color"], LINE_TOL) & ~exclude,
    }
    any_line = np.logical_or.reduce(list(line_masks.values()))

    # Purple first: where the orange stroke is hidden under the (on-top) teal
    # stroke the two curves coincide, so purple's row is the fallback there.
    per_mode = {}
    purple_rows = None
    for name in ("purple", "orange"):
        spec = MODES[name]
        mean_row, found = extract_mean_rows(line_masks[name], anchor_row=y_to_row(0.11), fallback=purple_rows)
        if name == "purple":
            purple_rows = mean_row

        band = tint_mask(arr, spec["line_color"], exclude) | any_line
        band &= ~exclude
        hi_row, lo_row = extract_band_rows(band, mean_row, COL_MIN, COL_MAX, ROW_MIN, ROW_MAX)

        # a run touching an exclude box edge is truncated, not a true bound
        for i, col in enumerate(range(COL_MIN, COL_MAX + 1)):
            colex = exclude[ROW_MIN:ROW_MAX + 1, col]
            if colex.any() and not np.isnan(hi_row[i]):
                vis = np.flatnonzero(~colex)
                if hi_row[i] <= ROW_MIN + vis[0] + 1:
                    hi_row[i] = np.nan
                if lo_row[i] >= ROW_MIN + vis[-1] - 1:
                    lo_row[i] = np.nan
        # bands wider than plausible (bled into the neighbouring band) -> drop
        half_top = mean_row - hi_row
        half_bot = lo_row - mean_row
        half_top = np.where(half_top > 0.16 * ROW_SCALE, np.nan, half_top)
        half_bot = np.where(half_bot > 0.16 * ROW_SCALE, np.nan, half_bot)
        # the faint tints are read noisily (dashed arrows, band overlaps), so
        # the envelope half-widths get a heavier smoothing than the stroke
        half_top = moving_mean(moving_median(local_median_fill(half_top), 21), 31)
        half_bot = moving_mean(moving_median(local_median_fill(half_bot), 21), 31)
        hi_row = mean_row - half_top
        lo_row = mean_row + half_bot

        mean_s = smooth(mean_row)
        hi_s = np.minimum(smooth(hi_row), mean_s)
        lo_s = np.maximum(smooth(lo_row), mean_s)

        mean_y = np.clip(np.interp(x_grid, x_cols, row_to_y(mean_s)), 0.0, None)
        hi_y = np.maximum(np.interp(x_grid, x_cols, row_to_y(hi_s)), mean_y)
        lo_y = np.clip(np.minimum(np.interp(x_grid, x_cols, row_to_y(lo_s)), mean_y), 0.0, None)

        per_mode[name] = {
            "label": spec["label"],
            "color": "#{:02X}{:02X}{:02X}".format(*spec["line_color"]),
            "n_rollouts": spec["n_rollouts"],
            "clip": spec["clip"],
            "mean": np.round(mean_y, 4).tolist(),
            "lo": np.round(lo_y, 4).tolist(),
            "hi": np.round(hi_y, 4).tolist(),
            "align": spec["align"],
        }
        print(f"  {name}: line found in {found.sum()}/{found.size} columns; "
              f"peak x={x_grid[np.argmax(mean_y)]:.3f} y={mean_y.max():.3f}; "
              f"start={mean_y[0]:.3f} end={mean_y[-1]:.3f}")

    today = datetime.date.today().isoformat()
    data = {
        "schema": "aura.uncertainty-curve/1",
        "task": "blockpush",
        "title": "Adaptive w̄ on Block Push",
        "x": {"label": "Normalized task progress", "range": [0, 1], "ticks": [0, 0.2, 0.4, 0.6, 0.8, 1]},
        "y": {"label": "Uncertainty degree w̄", "range": [0, 0.4], "ticks": [0, 0.2, 0.4]},
        "band": {"kind": "sd", "label": "±s.d."},
        "progress": np.round(x_grid, 4).tolist(),
        "modes": per_mode,
        "phases": PHASES,
        "source": "figure-digitized",
        "note": "Profile: paper mean over 20 rollouts, aligned to this rollout’s branch moment",
        "provenance": (
            f"Digitized from fig. S2C (assets/images/appendix/appen_wei_BP.png) by "
            f"tools/digitize_blockpush.py on {today}; N={args.n}; calibration "
            f"x=(col-{COL0})/{COL_SCALE}, y=({ROW0}-row)/{ROW_SCALE}; band = shaded "
            f"±s.d. envelope; align = piecewise-linear map from clip-time fraction to "
            f"curve progress pinning the branch peak to the clip's visible block "
            f"selection. Replace with per-step rollout logs when available."
        ),
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(to_compact_json(data) + "\n", encoding="utf-8")
    print(f"wrote {out_path} ({out_path.stat().st_size} bytes)")

    if args.debug:
        p = resolve(args.debug)
        make_debug_overlay(img, data["progress"], per_mode, p)
        print(f"wrote debug overlay {p}")


if __name__ == "__main__":
    main()
