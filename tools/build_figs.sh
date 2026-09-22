#!/usr/bin/env bash
# Convert the paper's Overleaf-exported figures (_src/figs/*.pdf) and the lab
# logos (_src/assets/*.png) into web-ready PNG+WebP pairs under assets/images/
# and assets/logos/. Idempotent: re-running skips any output that already
# exists unless FORCE=1 is set in the environment.
#
# Usage:
#   tools/build_figs.sh
#   FORCE=1 tools/build_figs.sh      # rebuild everything from scratch
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$SITE/_src"
IMG="$SITE/assets/images"
APX="$IMG/appendix"
LOGOS="$SITE/assets/logos"
PREVIEWS="$SITE/_src/previews"

FORCE="${FORCE:-0}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/build_figs.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$IMG" "$APX" "$LOGOS" "$PREVIEWS"

# ---------------------------------------------------------------------------
# Tool checks (fail fast with a clear message rather than a cryptic error
# mid-pipeline)
# ---------------------------------------------------------------------------
need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required tool '$1' not found on PATH" >&2
    exit 1
  }
}
need pdftocairo
need cwebp
need python3

python3 -c "import PIL" >/dev/null 2>&1 || {
  echo "ERROR: python3 does not have Pillow (PIL) installed" >&2
  exit 1
}

if command -v magick >/dev/null 2>&1; then
  MAGICK="magick"
  IDENTIFY="magick identify"
elif command -v convert >/dev/null 2>&1; then
  MAGICK="convert"
  IDENTIFY="identify"
  echo "WARN: 'magick' (ImageMagick 7) not found; falling back to legacy 'convert'/'identify'." >&2
else
  echo "ERROR: neither 'magick' nor 'convert' found on PATH" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Crop geometries (WxH+X+Y, ImageMagick -crop syntax), measured by hand
# against the *finished* framework.png (2417x2866) and overview.png
# (2407x2125) — i.e. after pdftocairo -scale-to-x 2400 + trim + 24px border.
# See PR/report notes for how these were located (white-gap scanning +
# visual confirmation via Read tool on cropped previews).
# ---------------------------------------------------------------------------
#
# Panel letters ("A", "B", "C" …) are cropped away on purpose: the site
# numbers its figures in page order, so a stray paper letter would only
# confuse. Row/column bounds were read off dark-pixel profiles of the
# finished PNGs (framework.png 2417x2866, overview.png 2111x1866,
# appendix/appen_wei_BP.png 2353x1455).
# ---------------------------------------------------------------------------
FRAMEWORK_A_GEOM="2417x1812+0+96"     # panel A box only: header "A Policy structure" occupies rows 24-91, the rounded box rows 101-1898
FRAMEWORK_B_GEOM="2417x860+0+2006"    # panel B chart only: header "B Adaptive w on Push-T" occupies rows 1937-2004, chart rows 2009-2842
OVERVIEW_FAST_GEOM="960x372+1130+98"  # panel "AURA acts faster and smoother" (trajectories + colorbar), rows 109-461 / cols 1140-2083; header row 41-76 and its "C" letter excluded
BP_CURVE_GEOM="2230x718+20+728"       # appen_wei_BP panel C chart (rows 742-1421) without its "C Evolution of inferred uncertainty" header (rows 652-703)

WEBP_MAX_BYTES=$((900 * 1024))

# ---------------------------------------------------------------------------
# Manifest bookkeeping (plain arrays -- macOS ships bash 3.2, no assoc arrays)
# ---------------------------------------------------------------------------
MANIFEST_KEYS=()
MANIFEST_W=()
MANIFEST_H=()
MANIFEST_PNGSZ=()
MANIFEST_WEBPSZ=()
FALLBACKS=()

need_build() {
  # need_build PNG WEBP -- true if either output is missing or FORCE=1
  [[ "$FORCE" == "1" || ! -f "$1" || ! -f "$2" ]]
}

record() {
  # record KEY PNG WEBP -- append to the manifest/report and drop a small
  # preview JPG under _src/previews/<key>_preview.jpg for visual QA.
  local key="$1" png="$2" webp="$3"
  local w h pngsz webpsz
  w="$($IDENTIFY -format '%w' "$png")"
  h="$($IDENTIFY -format '%h' "$png")"
  pngsz="$(stat -f%z "$png")"
  webpsz="$(stat -f%z "$webp")"

  MANIFEST_KEYS+=("$key")
  MANIFEST_W+=("$w")
  MANIFEST_H+=("$h")
  MANIFEST_PNGSZ+=("$pngsz")
  MANIFEST_WEBPSZ+=("$webpsz")

  local prev_path="$PREVIEWS/${key}_preview.jpg"
  mkdir -p "$(dirname "$prev_path")"
  "$MAGICK" "$png" -resize 600x -quality 85 "$prev_path"
}

# finish_png RAW PNG WEBP LABEL
# Trims RAW to content, flattens any stray alpha onto white, adds a 24px
# white border, strips metadata, writes PNG then WebP. Falls back to a lower
# WebP quality, then a ~2400->2000px downscale, if the WebP exceeds 900KB.
finish_png() {
  local raw="$1" png="$2" webp="$3" label="$4"
  mkdir -p "$(dirname "$png")"

  if need_build "$png" "$webp"; then
    echo "build: $label"
    "$MAGICK" "$raw" -background white -alpha remove -alpha off \
      -trim +repage -bordercolor white -border 24 \
      -strip -define png:compression-level=9 "$png"

    local q=85
    cwebp -quiet -q "$q" -m 6 -sharp_yuv "$png" -o "$webp"
    local sz
    sz="$(stat -f%z "$webp")"

    if (( sz > WEBP_MAX_BYTES )); then
      q=80
      cwebp -quiet -q "$q" -m 6 -sharp_yuv "$png" -o "$webp"
      sz="$(stat -f%z "$webp")"
      FALLBACKS+=("$label: webp quality 85 -> 80 (${sz} bytes)")
    fi

    if (( sz > WEBP_MAX_BYTES )); then
      # last resort: re-scale ~83% (equivalent to rasterising at -scale-to-x
      # 2000 instead of 2400) and re-encode at q=80
      local shrunk="$TMP/$(basename "$png" .png)_shrunk.png"
      "$MAGICK" "$png" -resize 83.3% -strip -define png:compression-level=9 "$shrunk"
      mv "$shrunk" "$png"
      cwebp -quiet -q "$q" -m 6 -sharp_yuv "$png" -o "$webp"
      sz="$(stat -f%z "$webp")"
      FALLBACKS+=("$label: + rescaled ~2400px->2000px (${sz} bytes)")
    fi

    if (( sz > WEBP_MAX_BYTES )); then
      echo "WARNING: $label webp is still ${sz} bytes (> 900KB) after all fallbacks" >&2
    fi
  else
    echo "skip (exists): $label"
  fi

  record "$label" "$png" "$webp"
}

# ---------------------------------------------------------------------------
# Main + appendix figures: PDF stem -> output name (relative to assets/images)
# ---------------------------------------------------------------------------
FIGURES=(
  "first_fig|overview"
  "framework|framework"
  "learning_faster|fig_learning"
  "multimodal_swap|fig_multimodal_swap"
  "multimodal_sim|fig_multimodal_sim"
  "inference_eff|fig_inference"
  "behavior_generation|fig_emergence"
  "cooking_fig|fig_cooking"
  "sup_infer|appendix/sup_infer"
  "appen_wei_BP|appendix/appen_wei_BP"
  "appen_behavior_generation|appendix/appen_behavior_generation"
  "ablation_study|appendix/ablation_study"
  "2d_navi_compared|appendix/2d_navi_compared"
  "appen_2d_navi_long|appendix/appen_2d_navi_long"
  "appen_spread|appendix/appen_spread"
)

# Figures the paper embeds as PNG rather than PDF (\includegraphics{Figs/<stem>.png});
# their PDFs in _src/figs are stale, so the PNG is the source of truth for these.
PNG_SOURCES=("learning_faster" "first_fig")

for entry in "${FIGURES[@]}"; do
  stem="${entry%%|*}"
  out="${entry##*|}"
  pdf="$SRC/figs/${stem}.pdf"
  src_png="$SRC/figs/${stem}.png"
  use_png=0
  for ps in "${PNG_SOURCES[@]}"; do [[ "$ps" == "$stem" && -f "$src_png" ]] && use_png=1; done
  if (( ! use_png )); then
    [[ -f "$pdf" ]] || { echo "ERROR: missing source PDF: $pdf" >&2; exit 1; }
  fi

  final_png="$IMG/${out}.png"
  final_webp="$IMG/${out}.webp"
  raw_prefix="$TMP/${stem}"
  raw="$TMP/${stem}.png"

  if need_build "$final_png" "$final_webp"; then
    if (( use_png )); then
      # the paper's own PNG export (may carry soft alpha): flatten onto white
      python3 "$SCRIPT_DIR/flatten_on_white.py" "$src_png" "$raw"
    else
      # rasterise the PDF (not the PNG -- the PNGs carry soft alpha); no
      # -transp, so pdftocairo flattens onto white by default
      pdftocairo -png -singlefile -scale-to-x 2400 -scale-to-y -1 "$pdf" "$raw_prefix"
    fi
  fi
  finish_png "$raw" "$final_png" "$final_webp" "images/${out}"
done

# ---------------------------------------------------------------------------
# fig_jigsaw_modes: pintu_real.png has no PDF counterpart and carries real
# alpha, so flatten it onto white with PIL first.
# ---------------------------------------------------------------------------
JIGSAW_PNG="$IMG/fig_jigsaw_modes.png"
JIGSAW_WEBP="$IMG/fig_jigsaw_modes.webp"
jigsaw_flat="$TMP/pintu_real_flat.png"
if need_build "$JIGSAW_PNG" "$JIGSAW_WEBP"; then
  python3 "$SCRIPT_DIR/flatten_on_white.py" "$SRC/figs/pintu_real.png" "$jigsaw_flat"
fi
finish_png "$jigsaw_flat" "$JIGSAW_PNG" "$JIGSAW_WEBP" "images/fig_jigsaw_modes"

# ---------------------------------------------------------------------------
# Crops out of the finished framework.png / overview.png
# ---------------------------------------------------------------------------
FRAMEWORK_PNG="$IMG/framework.png"
[[ -f "$FRAMEWORK_PNG" ]] || { echo "ERROR: framework.png missing, cannot crop panels from it" >&2; exit 1; }

fa_raw="$TMP/framework_a_raw.png"
if need_build "$IMG/framework_a.png" "$IMG/framework_a.webp"; then
  "$MAGICK" "$FRAMEWORK_PNG" -crop "$FRAMEWORK_A_GEOM" +repage "$fa_raw"
fi
finish_png "$fa_raw" "$IMG/framework_a.png" "$IMG/framework_a.webp" "images/framework_a"

fb_raw="$TMP/framework_b_raw.png"
if need_build "$IMG/fig_uncertainty_curve.png" "$IMG/fig_uncertainty_curve.webp"; then
  "$MAGICK" "$FRAMEWORK_PNG" -crop "$FRAMEWORK_B_GEOM" +repage "$fb_raw"
fi
finish_png "$fb_raw" "$IMG/fig_uncertainty_curve.png" "$IMG/fig_uncertainty_curve.webp" "images/fig_uncertainty_curve"

OVERVIEW_PNG="$IMG/overview.png"
[[ -f "$OVERVIEW_PNG" ]] || { echo "ERROR: overview.png missing, cannot crop panels from it" >&2; exit 1; }

of_raw="$TMP/overview_fast_raw.png"
if need_build "$IMG/overview_fast.png" "$IMG/overview_fast.webp"; then
  "$MAGICK" "$OVERVIEW_PNG" -crop "$OVERVIEW_FAST_GEOM" +repage "$of_raw"
fi
finish_png "$of_raw" "$IMG/overview_fast.png" "$IMG/overview_fast.webp" "images/overview_fast"

BP_PNG="$APX/appen_wei_BP.png"
[[ -f "$BP_PNG" ]] || { echo "ERROR: appendix/appen_wei_BP.png missing, cannot crop panels from it" >&2; exit 1; }

bpc_raw="$TMP/bp_curve_raw.png"
if need_build "$IMG/fig_blockpush_curve.png" "$IMG/fig_blockpush_curve.webp"; then
  "$MAGICK" "$BP_PNG" -crop "$BP_CURVE_GEOM" +repage "$bpc_raw"
fi
finish_png "$bpc_raw" "$IMG/fig_blockpush_curve.png" "$IMG/fig_blockpush_curve.webp" "images/fig_blockpush_curve"

# ---------------------------------------------------------------------------
# Lab logos: resize + webp, alpha preserved (no white flatten/border --
# these are used as transparent logos, not figure panels)
# ---------------------------------------------------------------------------
build_logo() {
  local src="$1" out_png="$2" out_webp="$3" label="$4"
  if need_build "$out_png" "$out_webp"; then
    echo "build: $label"
    "$MAGICK" "$src" -resize 480x -strip "$out_png"
    cwebp -quiet -q 90 -exact -alpha_q 100 "$out_png" -o "$out_webp"
  else
    echo "skip (exists): $label"
  fi
  record "$label" "$out_png" "$out_webp"
}

build_logo "$SRC/assets/mars_lablogo.png" \
  "$LOGOS/mars_lab.png" "$LOGOS/mars_lab.webp" "logos/mars_lab"
build_logo "$SRC/assets/mars_lablogowhite.png" \
  "$LOGOS/mars_lab_white.png" "$LOGOS/mars_lab_white.webp" "logos/mars_lab_white"

# ---------------------------------------------------------------------------
# Size report + manifest.json
# ---------------------------------------------------------------------------
echo
echo "=== Size report ==="
n=${#MANIFEST_KEYS[@]}
for ((i = 0; i < n; i++)); do
  printf "%-28s %5dx%-5d png=%-9d webp=%-9d\n" \
    "${MANIFEST_KEYS[$i]}" "${MANIFEST_W[$i]}" "${MANIFEST_H[$i]}" \
    "${MANIFEST_PNGSZ[$i]}" "${MANIFEST_WEBPSZ[$i]}"
done

if [[ ${#FALLBACKS[@]} -gt 0 ]]; then
  echo
  echo "=== Quality/scale fallbacks applied (webp was over 900KB) ==="
  printf '%s\n' "${FALLBACKS[@]}"
fi

manifest_json="$IMG/manifest.json"
{
  echo "{"
  for ((i = 0; i < n; i++)); do
    sep=","
    [[ $i -eq $((n - 1)) ]] && sep=""
    printf '  "%s": {"w": %d, "h": %d, "png": %d, "webp": %d}%s\n' \
      "${MANIFEST_KEYS[$i]}" "${MANIFEST_W[$i]}" "${MANIFEST_H[$i]}" \
      "${MANIFEST_PNGSZ[$i]}" "${MANIFEST_WEBPSZ[$i]}" "$sep"
  done
  echo "}"
} > "$manifest_json"

python3 -c "import json; json.load(open('$manifest_json'))" || {
  echo "ERROR: generated manifest.json is not valid JSON" >&2
  exit 1
}

echo
echo "manifest: ${manifest_json#$SITE/}"
echo "assets/images total: $(du -sh "$IMG" | cut -f1)"
echo "assets/logos total:  $(du -sh "$LOGOS" | cut -f1)"
