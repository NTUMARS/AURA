#!/usr/bin/env python3
"""Static checks for the AURA site.  python3 tools/validate.py [--strict]
Exit 1 on any failure (missing assets, case mismatch, ?v= drift, bad video/img
attributes, dangling anchors).  --strict also fails on remaining placeholders."""
import json, os, re, sys
from html.parser import HTMLParser
from pathlib import Path

SITE = Path(__file__).resolve().parent.parent
STRICT = '--strict' in sys.argv
html = (SITE / 'index.html').read_text()
asset_v = re.search(r'data-asset-v="(\d+)"', html).group(1)
errors, warns = [], []

def exists_case(rel):
    """True if rel exists with exact case on every path component."""
    p = SITE
    for part in rel.split('/'):
        if not part: continue
        try:
            names = os.listdir(p)
        except FileNotFoundError:
            return False
        if part not in names: return False
        p = p / part
    return p.exists()

class P(HTMLParser):
    def __init__(self):
        super().__init__(); self.ids=set(); self.refs=[]; self.videos=[]; self.imgs=[]; self.sources=[]; self.links=[]; self.placeholders=0; self.stack=[]
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        self.stack.append((tag, a))
        if 'id' in a: self.ids.add(a['id'])
        if a.get('data-placeholder') is not None: self.placeholders += 1
        for key in ('src', 'poster', 'srcset', 'href'):
            v = a.get(key)
            if v and not v.startswith(('http', 'mailto:', '#', 'data:')):
                self.refs.append((tag, key, v))
        if tag == 'video': self.videos.append(a)
        if tag == 'img': self.imgs.append(a)
        if tag == 'source': self.sources.append(a)
        if tag == 'a':
            self.links.append(a)
        for key in ('data-spy-for', 'aria-controls'):
            if key in a: self.refs.append(('id', key, '#' + a[key]))
        for key in ('data-src', 'data-poster'):
            if key in a: self.refs.append((tag, key, a[key]))
    def handle_endtag(self, tag):
        while self.stack and self.stack[-1][0] != tag: self.stack.pop()
        if self.stack: self.stack.pop()

p = P(); p.feed(html)

# 1. relative asset refs exist with exact case; ?v= uniform
for tag, key, v in p.refs:
    if v.startswith('#'):
        continue
    path, _, q = v.partition('?')
    if q:
        m = re.match(r'v=(\d+)$', q)
        if not m or m.group(1) != asset_v:
            errors.append(f'?v mismatch on {v} (expected v={asset_v})')
    if not exists_case(path):
        errors.append(f'missing or wrong-case: {path}  ({tag} {key})')
for m in re.finditer(r'\?v=(\d+)', html):
    if m.group(1) != asset_v: errors.append(f'?v={m.group(1)} found, expected {asset_v}')

# 2. anchors / spy / aria-controls targets exist
for tag, key, v in p.refs:
    if v.startswith('#') and v != '#' and v[1:] not in p.ids:
        errors.append(f'dangling {key}: {v}')
for a in p.links:
    h = a.get('href', '')
    if h.startswith('#') and len(h) > 1 and h[1:] not in p.ids:
        errors.append(f'dangling anchor {h}')
    if h.startswith('http') and 'noopener' not in (a.get('rel') or ''):
        errors.append(f'external link without rel=noopener: {h}')

# 3. video hygiene
for v in p.videos:
    src = v.get('src', '?')
    for need in ('muted', 'playsinline', 'poster', 'preload'):
        if need not in v: errors.append(f'<video {src}> lacks {need}')
    if 'autoplay' in v and 'strip' not in src:
        errors.append(f'<video {src}> uses autoplay outside the strip')

# 4. img hygiene: alt, width/height for figure images, webp sibling
for im in p.imgs:
    src = im.get('src', '?')
    if not im.get('alt'): errors.append(f'<img {src}> lacks alt')
    if src.startswith('assets/images/'):
        if not (im.get('width') and im.get('height')): errors.append(f'<img {src}> lacks width/height')
        webp = src.split('?')[0].replace('.png', '.webp')
        if not exists_case(webp): errors.append(f'missing webp sibling {webp}')

# 5. placeholders
if p.placeholders:
    (errors if STRICT else warns).append(f'{p.placeholders} data-placeholder slots remain')

# 6. media budget
vids = list((SITE / 'assets/videos').rglob('*.mp4'))
total = sum(f.stat().st_size for f in vids)
big = [f for f in vids if f.stat().st_size > 15e6]
if total > 80e6: errors.append(f'videos total {total/1e6:.1f} MB > 80 MB')
for f in big: errors.append(f'{f.relative_to(SITE)} is {f.stat().st_size/1e6:.1f} MB > 15 MB')
posters = list((SITE / 'assets/posters').glob('*.jpg'))
for f in posters:
    if f.stat().st_size > 250e3: errors.append(f'{f.relative_to(SITE)} poster > 250 KB')
webps = list((SITE / 'assets/images').rglob('*.webp'))
for f in webps:
    if f.stat().st_size > 900e3: errors.append(f'{f.relative_to(SITE)} webp > 900 KB')

print(f'asset-v={asset_v}  refs={len(p.refs)}  videos={len(p.videos)}  imgs={len(p.imgs)}  mp4={len(vids)} ({total/1e6:.1f} MB)  posters={len(posters)}  webp={len(webps)}')
for w in warns: print('WARN ', w)
for e in errors: print('FAIL ', e)
print('OK' if not errors else f'{len(errors)} problem(s)')
sys.exit(1 if errors else 0)
