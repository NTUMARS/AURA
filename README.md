# AURA — project page

Static project page for **"Adaptive Uncertainty Enables Emergent Robot Behaviors Without Scaling"** (AURA: Adaptive Uncertainty for Robotic Actions), MARS Lab, Nanyang Technological University.

Live: https://jingliangli.com/AURA/ (GitHub Pages, `main` / root, custom domain inherited from the user site; every asset URL is relative).

## Layout

```
index.html                 single page; <html data-asset-v="N" class="no-js">
styles/                    tokens · reset · layout · components  ("journal plate", pure white; Geist display · Inter body · JetBrains Mono labels)
scripts/                   reveal · lazy-video · comparison (tile control bar) · mode-select (chips)
                           hero-mosaic (four rotating real-robot cells, `data-pool` JSON per cell) · uncertainty-live (curve drawn in sync with the Push-T clip; `data-lead` seconds of lead)
                           panel-toggle (Demonstrated / Emergent) · sync-compare (lockstep pair)
                           section-spy (nav) · scroll-progress · copy-bibtex · main (Lenis)
assets/videos/<group>/     H.264 mp4, speed-ups baked in (jigsaw 2×, cooking 2×, table 6×)
assets/posters/            one JPG per clip  (<group>_<name>.jpg)
assets/images/             paper figures rasterised from the PDFs → PNG + WebP, manifest.json for sizes
assets/data/               pusht_uncertainty.json — Fig. 7B digitized (tools/digitize_curve.py); swap in a per-step rollout log when available
tools/                     build_figs.sh · build_media.sh · report_media.sh · digitize_curve.py · fill_dims.py · validate.py · bump_version.py
_src/                      gitignored scratch (figure sources, contact sheets, previews)
```

## Rebuild

```bash
tools/build_figs.sh            # needs pdftocairo, magick, cwebp, PIL; sources in _src/figs
tools/build_media.sh           # needs ffmpeg 9; sources in ~/Downloads/website (first author's clips)
tools/report_media.sh          # size / duration table, budget gate
python3 tools/digitize_curve.py --debug _src/digitize_overlay.png   # Fig. 7B → assets/data/pusht_uncertainty.json
python3 tools/fill_dims.py     # width/height on <img> from assets/images/manifest.json
python3 tools/validate.py      # asset existence (exact case), ?v= uniformity, attribute hygiene, budget
python3 tools/bump_version.py  # bump data-asset-v and every ?v=
```

Page order: hero (title · authors · real-robot mosaic · headline stats) → How it works (live Fig. 7B) → §01–§04 → Abstract → Platforms → Cite.

Fig. 2 (`learning_faster`) is built from the paper's PNG export rather than its stale PDF (`PNG_SOURCES` in `tools/build_figs.sh`).

Dev server: `python3 -m http.server 8480 --directory .` (registered as `aura-site` in the shared launch config). Append `?static=1` for a deterministic render (everything revealed, both tab panels shown, no autoplay) when taking screenshots.

## Placeholders

`data-placeholder="paper"`, `"code"` (hero buttons + nav CTA) and `"bibtex"` are filled once the paper PDF, code repository and final citation exist. `python3 tools/validate.py --strict` fails while any remain.
