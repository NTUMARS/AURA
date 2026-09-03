#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""digitize_curve.py -- digitize the Push-T "Adaptive w-bar" uncertainty
curve (paper Fig. 7B) out of its rasterized source PNG and write the result
as assets/data/pusht_uncertainty.json.

The figure shows two modes ("Upper" / "Lower"), each a mean line with a
shaded +/-s.d. band, over normalized task progress (x) vs. inferred
uncertainty degree (y). All calibration below (pixel<->data mapping, line
and band tint colors, exclude boxes) was measured by hand against the
source PNG; treat it as fixed constants, not something to re-detect.

Usage:
    python3 tools/digitize_curve.py [--src PATH] [--out PATH] [--n 200] [--debug PATH]

Idempotent: with a fixed source image and args, re-running reproduces the
same JSON byte-for-byte (no randomness, no auto-detection; the only
input-dependent field is the provenance timestamp, which is today's date).
"""
import argparse
import datetime
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

# =============================================================================
# Calibration constants (measured against the source PNG's gridlines/ticks).
#   col 276.33  -> x 0.0   col 2257.16 -> x 1.0
#   row 667.5   -> y 0.0   row 305.4   -> y 0.4
# =============================================================================
COL0, COL_SCALE = 276.33, 1980.83   # x = (col - COL0) / COL_SCALE
ROW0, ROW_SCALE = 667.5, 905.25     # y = (ROW0 - row) / ROW_SCALE


def col_to_x(col):
    return (col - COL0) / COL_SCALE


def row_to_y(row):
    return (ROW0 - row) / ROW_SCALE


def x_to_col(x):
    return x * COL_SCALE + COL0


def y_to_row(y):
    return ROW0 - y * ROW_SCALE


# Curves never rise above row 328, and start getting noisy near the title
# above row ~300 -- restrict the whole scan to this row band.
ROW_MIN, ROW_MAX = 300, 711
COL_MIN = int(round(x_to_col(0.0)))   # 276
COL_MAX = int(round(x_to_col(1.0)))   # 2257

LINE_TOL = 30   # Euclidean RGB tolerance for the two mean-line colors
                # (chosen so the upper/lower line masks are disjoint at r<=30)
BAND_TOL = 18   # Euclidean RGB tolerance for the shaded-band tint colors

# Residual anti-aliasing slack: both mean lines are explicitly unioned into
# the band mask before run-finding (a stroke -- own or the other mode's --
# would otherwise split one contiguous band run in two), so this only needs
# to bridge the couple of blend px around each stroke's edge, not the stroke
# itself.
BAND_MERGE_GAP = 10

# Max row jump accepted between adjacent columns' mean-line pick, to avoid
# jumping onto the other mode's line where the two coincide or cross.
CONTINUITY_TOL = 40

SMOOTH_MEDIAN_WIN = 5
SMOOTH_MEAN_WIN = 9

MODES = {
    "upper": {
        "label": "Upper",
        "line_color": (0x73, 0xBE, 0xB9),   # #73BEB9 teal
        "band_white": (0xE2, 0xF1, 0xF0),   # band tint over white background
        "band_grey": (0xCC, 0xD8, 0xE3),    # band tint over the grey phase bands
        "band_overlap": (0xCD, 0xE1, 0xEA), # where the two bands overlap (shared)
        "n_rollouts": 10,
        "clip": "assets/videos/pusht/mode1.mp4",
        "align": [[0, 0], [0.43, 0.27], [0.86, 0.78], [1, 1]],
    },
    "lower": {
        "label": "Lower",
        "line_color": (0x57, 0x91, 0xC1),   # #5791C1 blue
        "band_white": (0xDC, 0xE8, 0xF2),
        "band_grey": (0xBE, 0xD2, 0xDC),
        "band_overlap": (0xCD, 0xE1, 0xEA),
        "n_rollouts": 10,
        "clip": "assets/videos/pusht/mode2.mp4",
        "align": [[0, 0], [0.45, 0.27], [0.83, 0.78], [1, 1]],
    },
}

# Grey phase-band rectangles (pixel columns). NOTE: the band-over-white tints
# (band_white, above) turn out to sit within BAND_TOL of the *bare* grey
# background (#EBEDEF) -- e.g. dist(#E2F1F0, #EBEDEF) ~= 9.9 < 18 -- so
# band_white must only be matched *outside* these column ranges, and
# band_grey only *inside* them, or bare grey gets misread as band everywhere.
GREY_BAND_COLS = [(670, 1070), (1667, 2064)]

# EXCLUDE boxes (col0, col1, row0, row1): robot insets + legend swatch. Each
# contains teal/blue-ish artwork (dashed arrows, legend key lines) that would
# otherwise be misread as curve/band pixels.
EXCLUDE_BOXES = [
    (276, 645, 300, 520),     # left robot inset
    (1985, 2415, 180, 470),   # right robot inset
    (1140, 1560, 250, 430),   # "Upper" / "Lower" legend
]

N_DEFAULT = 200
SRC_DEFAULT = "assets/images/fig_uncertainty_curve.png"
OUT_DEFAULT = "assets/data/pusht_uncertainty.json"

PHASES = [
    {"id": "branch", "label": "Branch point", "range": [0.2, 0.4]},
    {"id": "push", "label": "Push point", "range": [0.7, 0.9]},
]


# =============================================================================
# Pixel-mask helpers
# =============================================================================
def build_exclude_mask(shape):
    mask = np.zeros(shape, dtype=bool)
    for c0, c1, r0, r1 in EXCLUDE_BOXES:
        mask[r0:r1 + 1, c0:c1 + 1] = True
    return mask


def build_grey_col_mask(width):
    mask = np.zeros(width, dtype=bool)
    for c0, c1 in GREY_BAND_COLS:
        mask[c0:c1 + 1] = True
    return mask


def color_mask(arr, color, tol):
    diff = arr.astype(np.int32) - np.array(color, dtype=np.int32)
    dist = np.sqrt((diff ** 2).sum(axis=-1))
    return dist <= tol


def find_runs(bool_1d):
    """Contiguous True runs of a 1-D bool array, as inclusive (start, end) index pairs."""
    idx = np.flatnonzero(bool_1d)
    if idx.size == 0:
        return []
    runs = []
    start = prev = idx[0]
    for i in idx[1:]:
        if i == prev + 1:
            prev = i
        else:
            runs.append((start, prev))
            start = prev = i
    runs.append((start, prev))
    return runs


def merge_close_runs(runs, max_gap):
    if not runs:
        return runs
    merged = [runs[0]]
    for s, e in runs[1:]:
        ps, pe = merged[-1]
        if s - pe - 1 <= max_gap:
            merged[-1] = (ps, e)
        else:
            merged.append((s, e))
    return merged


# =============================================================================
# Mean-line extraction
# =============================================================================
def extract_mean_rows(line_mask, col_min, col_max, row_min, row_max):
    """Walk columns left->right, picking in each the run of `line_mask` pixels
    nearest the previously accepted row (continuity). Columns with no
    accepted run are left NaN and linearly interpolated over afterwards."""
    n = col_max - col_min + 1
    rows = np.full(n, np.nan)
    prev_row = None
    anchor_row = y_to_row(0.0)   # curve is expected to start near y=0

    for i, col in enumerate(range(col_min, col_max + 1)):
        column = line_mask[row_min:row_max + 1, col]
        runs = find_runs(column)
        if not runs:
            continue
        medians = [row_min + (s + e) / 2.0 for (s, e) in runs]
        if prev_row is None:
            j = int(np.argmin([abs(m - anchor_row) for m in medians]))
            rows[i] = medians[j]
            prev_row = medians[j]
        else:
            dists = [abs(m - prev_row) for m in medians]
            j = int(np.argmin(dists))
            if dists[j] <= CONTINUITY_TOL:
                rows[i] = medians[j]
                prev_row = medians[j]
            # else: leave as NaN for this column; prev_row (the continuity
            # anchor) is left unchanged so a later column can still match it.

    idx = np.arange(n)
    good = ~np.isnan(rows)
    if not good.any():
        raise RuntimeError("no mean-line pixels found at all for this mode")
    return np.interp(idx, idx[good], rows[good])


# =============================================================================
# Band (+/-s.d.) extraction
# =============================================================================
def extract_band_rows(band_mask, mean_rows, col_min, col_max, row_min, row_max):
    """For each column, take the band run that contains (or is nearest) the
    mean row; its top/bottom become hi_row/lo_row (row-space; smaller row =
    larger y = hi). Columns with no run are left NaN for the caller to fill."""
    n = col_max - col_min + 1
    hi_row = np.full(n, np.nan)
    lo_row = np.full(n, np.nan)

    for i, col in enumerate(range(col_min, col_max + 1)):
        column = band_mask[row_min:row_max + 1, col]
        runs = merge_close_runs(find_runs(column), BAND_MERGE_GAP)
        if not runs:
            continue
        mean_off = mean_rows[i] - row_min
        containing = [(s, e) for (s, e) in runs if s <= mean_off <= e]
        if containing:
            s, e = containing[0]
        else:
            def dist_to_run(se):
                s, e = se
                if mean_off < s:
                    return s - mean_off
                if mean_off > e:
                    return mean_off - e
                return 0.0
            s, e = min(runs, key=dist_to_run)
        hi_row[i] = row_min + s
        lo_row[i] = row_min + e

    return hi_row, lo_row


def local_median_fill(values, window=41):
    """Fill NaNs in `values` with the median of nearby non-NaN entries,
    expanding the window if the immediate neighborhood is also empty."""
    n = len(values)
    out = values.copy()
    for i in np.flatnonzero(np.isnan(values)):
        w = window
        while True:
            lo_i, hi_i = max(0, i - w // 2), min(n, i + w // 2 + 1)
            seg = values[lo_i:hi_i]
            seg = seg[~np.isnan(seg)]
            if seg.size:
                out[i] = np.median(seg)
                break
            w *= 2
            if w > 4 * n:
                out[i] = np.nanmedian(values)
                break
    return out


# =============================================================================
# Smoothing / resampling
# =============================================================================
def moving_median(a, window):
    n, half = len(a), window // 2
    return np.array([np.median(a[max(0, i - half):min(n, i + half + 1)]) for i in range(n)])


def moving_mean(a, window):
    n, half = len(a), window // 2
    return np.array([np.mean(a[max(0, i - half):min(n, i + half + 1)]) for i in range(n)])


def smooth(a):
    return moving_mean(moving_median(a, SMOOTH_MEDIAN_WIN), SMOOTH_MEAN_WIN)


# =============================================================================
# Compact-array JSON writer: dicts stay multi-line/indented, but a list whose
# elements are all plain numbers (or all [num, num] pairs) is written on one
# line -- keeps the 200-point curve arrays from ballooning into one value per
# line while everything else stays readable.
# =============================================================================
def _is_flat_numeric(v):
    return isinstance(v, list) and all(isinstance(e, (int, float)) for e in v)


def _is_pair_list(v):
    return isinstance(v, list) and all(
        isinstance(e, list) and all(isinstance(x, (int, float)) for x in e) for e in v
    )


def to_compact_json(value, indent=0, step=2):
    pad, pad_in = " " * indent, " " * (indent + step)
    if isinstance(value, dict):
        if not value:
            return "{}"
        items = [
            f'{pad_in}{json.dumps(k, ensure_ascii=False)}: {to_compact_json(v, indent + step, step)}'
            for k, v in value.items()
        ]
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    if isinstance(value, list):
        if not value:
            return "[]"
        if _is_flat_numeric(value) or _is_pair_list(value):
            return json.dumps(value, ensure_ascii=False)
        items = [f"{pad_in}{to_compact_json(v, indent + step, step)}" for v in value]
        return "[\n" + ",\n".join(items) + "\n" + pad + "]"
    return json.dumps(value, ensure_ascii=False)


# =============================================================================
# Debug overlay
# =============================================================================
def make_debug_overlay(img, progress, per_mode, path):
    im = img.copy().convert("RGB")
    draw = ImageDraw.Draw(im)
    for name, d in per_mode.items():
        pts_hi = [(x_to_col(x), y_to_row(y)) for x, y in zip(progress, d["hi"])]
        pts_lo = [(x_to_col(x), y_to_row(y)) for x, y in zip(progress, d["lo"])]
        pts_mean = [(x_to_col(x), y_to_row(y)) for x, y in zip(progress, d["mean"])]
        draw.line(pts_hi, fill=(255, 140, 0), width=2)
        draw.line(pts_lo, fill=(255, 140, 0), width=2)
        draw.line(pts_mean, fill=(255, 0, 0), width=3)
    path.parent.mkdir(parents=True, exist_ok=True)
    im.save(path)


# =============================================================================
# Main
# =============================================================================
def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--src", default=SRC_DEFAULT)
    ap.add_argument("--out", default=OUT_DEFAULT)
    ap.add_argument("--n", type=int, default=N_DEFAULT)
    ap.add_argument("--debug", default=None)
    args = ap.parse_args()

    root = Path(__file__).resolve().parent.parent

    def resolve(p):
        p = Path(p)
        return p if p.is_absolute() else root / p

    src_path, out_path = resolve(args.src), resolve(args.out)

    img = Image.open(src_path).convert("RGB")
    arr = np.array(img)
    exclude_mask = build_exclude_mask(arr.shape[:2])
    grey_col = build_grey_col_mask(arr.shape[1])

    x_grid = np.linspace(0.0, 1.0, args.n)
    x_cols = col_to_x(np.arange(COL_MIN, COL_MAX + 1))

    # Mean-line masks for both modes, computed up front: a mode's *own* line
    # sits inside its *own* band (splitting the band mask in two around the
    # stroke), and past the branch/push peaks the two bands overlap so much
    # that the *other* mode's opaque line also cuts through this mode's band.
    # Both are unioned into the band mask below so a several-px-wide stroke
    # doesn't fragment one continuous +/-s.d. envelope into separate runs.
    line_masks = {
        name: color_mask(arr, spec["line_color"], LINE_TOL) & ~exclude_mask
        for name, spec in MODES.items()
    }
    any_line_mask = line_masks["upper"] | line_masks["lower"]

    per_mode = {}
    for name, spec in MODES.items():
        line_mask = line_masks[name]
        mean_row = extract_mean_rows(line_mask, COL_MIN, COL_MAX, ROW_MIN, ROW_MAX)

        white_mask = color_mask(arr, spec["band_white"], BAND_TOL)
        grey_mask = color_mask(arr, spec["band_grey"], BAND_TOL)
        overlap_mask = color_mask(arr, spec["band_overlap"], BAND_TOL)
        # band_white only applies outside the grey rectangles (else it also
        # catches bare grey background); band_grey only inside them.
        band_mask = overlap_mask | (grey_mask & grey_col) | (white_mask & ~grey_col)
        band_mask = (band_mask | any_line_mask) & ~exclude_mask

        hi_row, lo_row = extract_band_rows(band_mask, mean_row, COL_MIN, COL_MAX, ROW_MIN, ROW_MAX)

        # Fallback: where the band run is absent, use mean +/- the local
        # median half-width (computed from columns where it *was* found).
        half_top = local_median_fill(mean_row - hi_row)
        half_bot = local_median_fill(lo_row - mean_row)
        hi_row = np.where(np.isnan(hi_row), mean_row - half_top, hi_row)
        lo_row = np.where(np.isnan(lo_row), mean_row + half_bot, lo_row)

        # clamp lo <= mean <= hi (row-space: hi_row <= mean_row <= lo_row)
        hi_row = np.minimum(hi_row, mean_row)
        lo_row = np.maximum(lo_row, mean_row)

        mean_s = smooth(mean_row)
        hi_s = np.minimum(smooth(hi_row), mean_s)
        lo_s = np.maximum(smooth(lo_row), mean_s)

        mean_y = np.interp(x_grid, x_cols, row_to_y(mean_s))
        hi_y = np.interp(x_grid, x_cols, row_to_y(hi_s))
        lo_y = np.interp(x_grid, x_cols, row_to_y(lo_s))

        mean_y = np.clip(mean_y, 0.0, None)
        lo_y = np.clip(np.minimum(lo_y, mean_y), 0.0, None)
        hi_y = np.maximum(hi_y, mean_y)

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

    today = datetime.date.today().isoformat()
    provenance = (
        f"Digitized from Fig. 7B (assets/images/fig_uncertainty_curve.png) by "
        f"tools/digitize_curve.py on {today}; N={args.n}; calibration "
        f"x=(col-{COL0})/{COL_SCALE}, y=({ROW0}-row)/{ROW_SCALE}; band = shaded "
        f"±s.d. envelope; align = piecewise-linear map from clip-time "
        f"fraction to curve progress pinning the branch and push peaks to the "
        f"clip's visible events. Replace with per-step rollout logs when available."
    )

    data = {
        "schema": "aura.uncertainty-curve/1",
        "task": "pusht",
        "title": "Adaptive w̄ on Push-T",
        "x": {
            "label": "Normalized task progress",
            "range": [0, 1],
            "ticks": [0, 0.2, 0.4, 0.6, 0.8, 1],
        },
        "y": {
            "label": "Uncertainty degree w̄",
            "range": [0, 0.4],
            "ticks": [0, 0.2, 0.4],
        },
        "band": {"kind": "sd", "label": "±s.d."},
        "progress": np.round(x_grid, 4).tolist(),
        "modes": per_mode,
        "phases": PHASES,
        "source": "figure-digitized",
        "provenance": provenance,
    }

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(to_compact_json(data) + "\n", encoding="utf-8")
    print(f"wrote {out_path} ({out_path.stat().st_size} bytes)")

    progress_list = data["progress"]
    for name in ("upper", "lower"):
        m = np.array(per_mode[name]["mean"])
        x = np.array(progress_list)
        first_half = x < 0.5
        second_half = ~first_half
        i1 = np.argmax(m[first_half])
        i2 = np.argmax(m[second_half]) + np.argmax(second_half)
        tail = m[x >= 0.95]
        print(
            f"  {name}: peak1 x={x[i1]:.3f} y={m[i1]:.3f} | "
            f"peak2 x={x[i2]:.3f} y={m[i2]:.3f} | "
            f"tail(x>=0.95) mean={tail.mean():.4f}"
        )

    if args.debug:
        debug_path = resolve(args.debug)
        make_debug_overlay(img, progress_list, per_mode, debug_path)
        print(f"wrote debug overlay {debug_path}")


if __name__ == "__main__":
    main()
