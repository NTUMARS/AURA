#!/usr/bin/env python3
"""Measure the green-screen backdrop of a clip and print the luminance factor
that brings it to the site-wide target.

    python3 tools/green_level.py clip.mp4            -> prints e.g. 0.58
    python3 tools/green_level.py --report clip.mp4   -> factor + measured stats

The backdrop is isolated with the same chroma-hue mask the ffmpeg `geq`
darkener in build_media.sh uses (see green_vf there): strongly negative Cr,
Cb at or below neutral, and chroma large relative to luma -- i.e. "green,
at any brightness". White cloth, produce, the teal cup, robot and shadows are
outside the mask by construction, so only the backdrop is measured and only
the backdrop is darkened.

Uniformity: every green-screen clip on the site is scaled so its backdrop's
mean relative luminance lands on TARGET, regardless of whether the source
was SDR or HLG-tonemapped. Hue and saturation are untouched (the factor is a
pure RGB multiply). Factor is clamped to [FMIN, 1] so a clip is never
brightened and never crushed.
"""
import subprocess, sys, tempfile, os
import numpy as np
from PIL import Image

TARGET = 0.22   # mean relative luminance of the backdrop after darkening
FMIN = 0.30
N_FRAMES = 6


def mask(rgb):
    r, g, b = [rgb[..., i].astype(float) for i in range(3)]
    y = 0.299 * r + 0.587 * g + 0.114 * b               # full-range luma (BT.601)
    cb = -0.168736 * r - 0.331264 * g + 0.5 * b         # centred on 0
    cr = 0.5 * r - 0.418688 * g - 0.081312 * b
    v, u = cr, cb
    m = np.clip((-v - 6) / 8, 0, 1) * np.clip((3 - u) / 5, 0, 1) \
        * np.clip((u + 45) / 8, 0, 1) * np.clip((-v - 0.13 * y) / 6, 0, 1)
    return m


def measure(path):
    dur = float(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_entries", "format=duration",
        "-of", "default=nw=1:nk=1", path]).decode().strip() or 0)
    ts = [dur * (i + 0.5) / N_FRAMES for i in range(N_FRAMES)] if dur > 0 else [0.5]
    lums, weights = [], []
    with tempfile.TemporaryDirectory() as td:
        for i, t in enumerate(ts):
            out = os.path.join(td, f"f{i}.png")
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{t:.3f}", "-i", path,
                            "-frames:v", "1", "-update", "1", out], check=True)
            rgb = np.asarray(Image.open(out).convert("RGB"))
            m = mask(rgb)
            if m.sum() < 200:
                continue
            lum = (0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2]) / 255.0
            lums.append((lum * m).sum() / m.sum())
            weights.append(m.sum())
    if not lums:
        return None
    return float(np.average(lums, weights=weights))


def factor(mean_lum):
    if mean_lum is None or mean_lum <= 0:
        return 1.0
    return float(min(1.0, max(FMIN, TARGET / mean_lum)))


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    report = "--report" in sys.argv
    for p in args:
        m = measure(p)
        f = factor(m)
        if report:
            print(f"{os.path.basename(p):26s} backdrop_lum={m if m is None else round(m, 3)}  factor={f:.3f}")
        else:
            print(f"{f:.3f}")
