#!/usr/bin/env python3
"""Flatten an image with alpha transparency onto a solid white background.

Used for source assets that only exist as PNG (no PDF), e.g. pintu_real.png,
which carries real alpha and must not go through the PDF->pdftocairo path.

Usage: flatten_on_white.py IN OUT
"""
import sys

from PIL import Image


def flatten_on_white(in_path: str, out_path: str) -> None:
    src = Image.open(in_path).convert("RGBA")
    bg = Image.new("RGBA", src.size, (255, 255, 255, 255))
    flattened = Image.alpha_composite(bg, src).convert("RGB")
    flattened.save(out_path)


def main() -> None:
    if len(sys.argv) != 3:
        print("Usage: flatten_on_white.py IN OUT", file=sys.stderr)
        sys.exit(1)
    flatten_on_white(sys.argv[1], sys.argv[2])


if __name__ == "__main__":
    main()
