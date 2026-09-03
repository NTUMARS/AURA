#!/usr/bin/env python3
"""Fill width/height on every <img src="assets/images/...png"> from assets/images/manifest.json."""
import json, re, sys
from pathlib import Path
SITE = Path(__file__).resolve().parent.parent
man = json.loads((SITE / 'assets/images/manifest.json').read_text())
html = (SITE / 'index.html').read_text()
n = 0
def repl(m):
    global n
    tag = m.group(0)
    src = re.search(r'src="assets/images/([^"?]+)\.png', tag)
    if not src: return tag
    key = src.group(1)
    entry = man.get(key) or man.get('images/' + key)
    if not entry: print('no manifest entry for', key, file=sys.stderr); return tag
    tag = re.sub(r'\s+width="\d+"', '', tag); tag = re.sub(r'\s+height="\d+"', '', tag)
    tag = tag.replace('<img ', f'<img width="{entry["w"]}" height="{entry["h"]}" ', 1)
    n += 1
    return tag
html2 = re.sub(r'<img [^>]*src="assets/images/[^"]+"[^>]*>', repl, html)
(SITE / 'index.html').write_text(html2)
print(f'filled {n} images')
