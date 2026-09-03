#!/usr/bin/env python3
"""Bump the site-wide asset version atomically: data-asset-v on <html>,
every ?v= in index.html, and every ?v= in scripts' import specifiers.
Usage: python3 tools/bump_version.py [N]   (default: current+1)"""
import re
import sys
from pathlib import Path

SITE = Path(__file__).resolve().parent.parent
index = SITE / "index.html"
html = index.read_text()
cur = int(re.search(r'data-asset-v="(\d+)"', html).group(1))
new = int(sys.argv[1]) if len(sys.argv) > 1 else cur + 1

def bump(text):
    return re.sub(r"\?v=\d+", f"?v={new}", text)

index.write_text(bump(html).replace(f'data-asset-v="{cur}"', f'data-asset-v="{new}"'))
n = 1
for js in (SITE / "scripts").rglob("*.js"):
    t = js.read_text()
    b = bump(t)
    if b != t:
        js.write_text(b)
        n += 1
print(f"v{cur} → v{new} across {n} files")
