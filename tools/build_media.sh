#!/usr/bin/env bash
# Build all AURA site video clips + posters from the raw source recordings
# in $SRC. Idempotent: re-running skips any output that already exists
# unless FORCE=1. Restrict to one group with ONLY=<group>, e.g.:
#   ONLY=table ./tools/build_media.sh
#
# Groups: fast pickcup pickveg pusht blockpush bypass jigsaw table cooking strip
set -euo pipefail

SRC="/Users/lijingliang/Downloads/website"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DST="$ROOT/assets/videos"
POST="$ROOT/assets/posters"
SCRATCH="$ROOT/_src/media"

FORCE="${FORCE:-0}"
ONLY="${ONLY:-}"

mkdir -p "$DST" "$POST" "$SCRATCH"

# ---------------------------------------------------------------------------
# Recorded contact-sheet / frame-analysis constants (see _src/media/*.jpg,
# *.png for the sheets and crops these were read off of).
# ---------------------------------------------------------------------------

# "fast and smother/{our,FM,FM2}.mp4" side-by-side sync: 1fps contact sheets
# (contact_our.jpg / contact_FM.jpg / contact_FM2.jpg, refined with
# zoom_*_*.jpg) showed the arm leaving its static resting pose and starting
# to reach down at these seconds. SS = motion start - 0.5s lead-in.
FAST_AURA_MOTION_START=23   # our.mp4 (AURA)
FAST_FM_MOTION_START=7      # FM.mp4
FAST_FM2_MOTION_START=6     # FM2.mp4
FAST_AURA_SS=22.5
FAST_FM_SS=6.5
FAST_FM2_SS=5.5
FAST_FM_T=20       # cut before a person enters the frame to reset the scene (~20.5 s out)

# "pick vegetable/pick red.mp4": arm starts reaching at ~4s (zoom_pickred_1to8.jpg).
# Only used for the strip/01_learning.mp4 loop -- the full pickveg/carrot.mp4
# output is kept untrimmed.
PICKRED_MOTION_START=4
PICKRED_MOTION_SS=3.5

# "FM shake on lower epochs" raw clips: manually chosen <=15s windows of the
# most visible hover/jitter, picked from 1fps contact sheets
# (contact_shakeA.jpg, contact_shakeB.jpg, zoom_shakeB_16to38.jpg).
#   121548...raw.mp4 (19.0s total): arm reaches the veg at ~5s and hovers/
#     jitters continuously through to the end -> take from just before that.
SHAKE_A_SS=4
SHAKE_A_T=15
#   8004070...raw.mp4 (38.7s total): arm oscillates toward/away from the veg
#     repeatedly between ~16s-30s (the clearest "shake"), then leaves the
#     frame entirely 31-35s before a final approach at the very end -> the
#     16-30s window is the most visible shaking and fits under 15s.
SHAKE_B_SS=15
SHAKE_B_T=15

# (Revision 4) The original "emergent feature/cooking/*" renders carried a
# Chinese text banner (rows 14-116 and 948-1002 of a 1024x1024 frame, see
# tools/find_banner_rows.py). The clips now used are banner-free re-renders,
# so no crop is applied; the constants are kept for reference only.
COOK_TOP=117
COOK_BOT=76

# ---------------------------------------------------------------------------
# Encoder commons
# ---------------------------------------------------------------------------

VENC_COMMON=(-c:v libx264 -preset slow -profile:v high -pix_fmt yuv420p -movflags +faststart -an)

# HLG -> SDR correction chain.
#
# NOTE: the plan called for zscale's proper linear-light tonemap
# (zscale=t=linear,format=gbrpf32le,zscale=p=bt709,tonemap=...). This
# Homebrew ffmpeg 9.0.1 build turned out NOT to have libzimg (`ffmpeg
# -version` configuration has no --enable-libzimg, and `brew info zimg`
# shows it isn't installed as a dependency of the plain `ffmpeg` formula --
# only `ffmpeg-full` bundles it), so the `zscale` filter is unavailable.
# Tried the fallback of feeding `tonemap` directly (no linearization): that
# is WORSE than doing nothing -- applying the hable curve to still-gamma-
# encoded values makes the image darker and muddier
# (_src/media/tonemap_A_direct.png vs the untouched _src/media/
# tonemap_B_raw.png). `colorspace` can't help either: its trc option list
# has no arib-std-b67 (HLG) entry, so it cannot linearize HLG at all.
#
# What actually causes the "grey/dull" look here is desaturation: sampled
# green-screen pixels came back around (114,176,137) where true-saturated
# green (sampled off the non-HLG fast/aura.mp4 footage) is around
# (0,169,98) -- i.e. R and B are lifted relative to G. `colorlevels` pulls
# the red/blue black points down to compensate, and `eq` adds back
# saturation/contrast/gamma. Tuned empirically and verified visually across
# 3 different scenes (pick cup, pick vegetable, table) -- see
# _src/media/tonemap_check_*.png / tonemap_E.png: green screen reads
# saturated, table cloth reads white, carrot/daikon/corn/mango/peach colors
# stay true (no hue shift), nothing blown out.
TONEMAP_TAIL="format=yuv420p,colorlevels=rimin=0.09:bimin=0.06:gimin=0.0,eq=saturation=1.9:contrast=1.12:gamma=1.08"

# Green-screen taming (revision 5): the chroma backdrop behind the R1 Lite
# read as a glaring, luminous green on the page. We now darken it as a pure
# *brightness* change -- no hue or saturation shift -- and normalise every
# green-screen clip to the same backdrop level so SDR and HLG-tonemapped
# sources look identical on the page.
#
# Mechanism: Y/Cb/Cr are scaled about their neutral points by the same
# factor F wherever a chroma-hue mask fires (equivalent to multiplying
# RGB by F -> luminance x F, hue and saturation unchanged). The mask is
# brightness-independent: Cr strongly negative, Cb at/below neutral, chroma
# large relative to luma. White cloth, produce, teal cup, robot and shadows
# never enter it. F is measured per clip by tools/green_level.py so the
# backdrop's mean relative luminance lands on one target (0.22) for all
# clips. Two-pass: pass 1 writes the un-darkened chain to $SCRATCH/pre at a
# near-lossless CRF, pass 2 probes it and applies green_vf.
# The mask is built from per-plane LUTs and blend modes (all SIMD C, ~5x
# cheaper than an equivalent `geq` expression; verified pixel-equivalent,
# mean |diff| 0.04/255 on a test frame):
#   ku = (Cb <= -2)  and  (Cb >= -37)         soft ramps of 5 and 8 levels
#   kv = (Cr <= -6)                            soft ramp of 8 levels
#   kc = (-Cr - 0.13*(Y-16)) >= 6              soft ramp of 6 levels
#   mask = ku * kv * kc ;  out = maskedmerge(orig, orig*F, mask)
green_vf() {  # $1 = luminance factor F in (0,1]
  local F="$1"
  echo "format=yuv444p,split=3[o][d][m];[d]lutyuv=y='16+(val-16)*${F}':u='128+(val-128)*${F}':v='128+(val-128)*${F}'[dark];[m]extractplanes=y+u+v[my][mu][mv];[mu]lut=c0='clip((131-val)*51,0,255)*clip((val-83)*32,0,255)/255'[ku];[mv]split[mv1][mv2];[mv1]lut=c0='clip((122-val)*32,0,255)'[kv];[mv2]lut=c0='clip(128-val,0,255)'[negv];[my]lut=c0='clip(0.13*(val-16),0,255)'[ys];[negv][ys]blend=all_mode=subtract[dd];[dd]lut=c0='clip(val*42,0,255)'[kc];[ku][kv]blend=all_mode=multiply[k1];[k1][kc]blend=all_mode=multiply,split=3[k2a][k2b][k2c];[k2a][k2b][k2c]mergeplanes=0x001020:yuv444p[mask];[o][dark][mask]maskedmerge,format=yuv420p"
}

tonemap_vf() {  # $1 = scale filter args, e.g. "-2:720"
  echo "scale=${1},${TONEMAP_TAIL}"
}

table_vf() {  # $1 = "hlg" or "sdr"
  if [[ "$1" == "hlg" ]]; then
    echo "setpts=PTS/6,fps=30,scale=-2:540,${TONEMAP_TAIL}"
  else
    echo "setpts=PTS/6,fps=30,scale=-2:540,format=yuv420p"
  fi
}

group_enabled() {
  [[ -z "$ONLY" || "$ONLY" == "$1" ]]
}

# run <input> <output> <vf-or-empty> [extra ffmpeg args...]
# Honours SS / T env vars for trims: SS is applied as a fast input seek
# (-ss before -i), T as an output-duration cap (-t after -i, before the
# output file) so it works correctly even after a setpts speed change.
# GREEN=1 enables the two-pass green-screen darkening described above.
run() {
  local in="$1" out="$2" vf="$3"; shift 3
  if [[ -f "$out" && "$FORCE" != "1" ]]; then
    echo "skip (exists): $out"
    return 0
  fi
  mkdir -p "$(dirname "$out")"
  local args=(-y -hide_banner -loglevel error -threads 0)
  if [[ -n "${SS:-}" ]]; then
    args+=(-ss "$SS")
  fi
  args+=(-i "$in")
  if [[ -n "${T:-}" ]]; then
    args+=(-t "$T")
  fi
  if [[ -n "$vf" ]]; then
    args+=(-vf "$vf")
  fi
  if [[ "${GREEN:-0}" == "1" ]]; then
    local pre="$SCRATCH/pre/$(basename "$(dirname "$out")")_$(basename "$out")"
    mkdir -p "$(dirname "$pre")"
    echo "pass 1 -> $pre"
    ffmpeg "${args[@]}" "${VENC_COMMON[@]}" -preset veryfast -crf 14 -g 30 "$pre"   # intermediate: speed over size
    local f
    f="$(python3 "$ROOT/tools/green_level.py" "$pre")"
    echo "pass 2 (green x$f) -> $out"
    ffmpeg -y -hide_banner -loglevel error -threads 0 -i "$pre" -filter_complex "$(green_vf "$f")" "${VENC_COMMON[@]}" "$@" "$out"
    return 0
  fi
  args+=("${VENC_COMMON[@]}" "$@" "$out")
  echo "encode -> $out"
  ffmpeg "${args[@]}"
}

# poster <video> <jpg-out> [ss=1]
poster() {
  local video="$1" out="$2" ss="${3:-1}"
  if [[ -f "$out" && "$FORCE" != "1" ]]; then
    echo "skip (exists): $out"
    return 0
  fi
  mkdir -p "$(dirname "$out")"
  ffmpeg -y -hide_banner -loglevel error -ss "$ss" -i "$video" \
    -frames:v 1 -q:v 4 -vf "scale='min(1280,iw)':-2" "$out"
}

# =============================================================================
# fast: side-by-side sync comparison (AURA vs two flow-matching baselines)
# =============================================================================
if group_enabled fast; then
  echo "== fast =="
  GREEN=1 SS=$FAST_AURA_SS run "$SRC/fast and smother/our.mp4" "$DST/fast/aura.mp4" "scale=-2:720,format=yuv420p" -crf 22 -g 30
  GREEN=1 SS=$FAST_FM_SS T=$FAST_FM_T run "$SRC/fast and smother/FM.mp4"  "$DST/fast/fm.mp4"   "scale=-2:720,format=yuv420p" -crf 22 -g 30
  poster "$DST/fast/aura.mp4" "$POST/fast_aura.jpg" 0
  poster "$DST/fast/fm.mp4"   "$POST/fast_fm.jpg"   0
fi

# =============================================================================
# pickcup: HLG multimodal grasp demos (rim vs handle)
# =============================================================================
if group_enabled pickcup; then
  echo "== pickcup =="
  GREEN=1 run "$SRC/multimodal feature/pick cup/rim1.mp4"    "$DST/pickcup/rim1.mp4"    "$(tonemap_vf -2:720)" -crf 23 -g 60
  GREEN=1 run "$SRC/multimodal feature/pick cup/rim2.mp4"    "$DST/pickcup/rim2.mp4"    "$(tonemap_vf -2:720)" -crf 23 -g 60
  GREEN=1 run "$SRC/multimodal feature/pick cup/handle2.mp4" "$DST/pickcup/handle2.mp4" "$(tonemap_vf -2:720)" -crf 23 -g 60
  GREEN=1 run "$SRC/multimodal feature/pick cup/handle3.mp4" "$DST/pickcup/handle3.mp4" "$(tonemap_vf -2:720)" -crf 23 -g 60
  poster "$DST/pickcup/rim1.mp4"    "$POST/pickcup_rim1.jpg"
  poster "$DST/pickcup/rim2.mp4"    "$POST/pickcup_rim2.jpg"
  poster "$DST/pickcup/handle2.mp4" "$POST/pickcup_handle2.jpg"
  poster "$DST/pickcup/handle3.mp4" "$POST/pickcup_handle3.jpg"
fi

# =============================================================================
# pickveg: HLG carrot/daikon grasp + under-trained FM "shake" failure demos
# Verified (see _src/media/tonemap_check_pickred_grasp.png and
# tonemap_check_pickwhite_grasp.png): "pick red.mp4" grasps
# the orange carrot, "pick white.mp4" grasps the white daikon -- as expected,
# no swap needed.
# =============================================================================
if group_enabled pickveg; then
  echo "== pickveg =="
  GREEN=1 run "$SRC/multimodal feature/pick vegetable/pick red.mp4"   "$DST/pickveg/carrot.mp4" "$(tonemap_vf -2:720)" -crf 23 -g 60
  GREEN=1 run "$SRC/multimodal feature/pick vegetable/pick white.mp4" "$DST/pickveg/daikon.mp4" "$(tonemap_vf -2:720)" -crf 23 -g 60
  GREEN=1 SS=$SHAKE_A_SS T=$SHAKE_A_T run \
    "$SRC/multimodal feature/pick vegetable/FM shake on lower epochs/121548c4803f057af64b8dc0eace1728_raw.mp4" \
    "$DST/pickveg/fm_shake_a.mp4" "$(tonemap_vf -2:720)" -crf 23 -g 60
  GREEN=1 SS=$SHAKE_B_SS T=$SHAKE_B_T run \
    "$SRC/multimodal feature/pick vegetable/FM shake on lower epochs/8004070cbd2fddb6ae62855e90f9ce86_raw.mp4" \
    "$DST/pickveg/fm_shake_b.mp4" "$(tonemap_vf -2:720)" -crf 23 -g 60
  poster "$DST/pickveg/carrot.mp4"     "$POST/pickveg_carrot.jpg"
  poster "$DST/pickveg/daikon.mp4"     "$POST/pickveg_daikon.jpg"
  poster "$DST/pickveg/fm_shake_a.mp4" "$POST/pickveg_fm_shake_a.jpg"
  poster "$DST/pickveg/fm_shake_b.mp4" "$POST/pickveg_fm_shake_b.jpg"
fi

# =============================================================================
# pusht: Franka Push-T, two modes, native 640x480 @ 10fps
# =============================================================================
if group_enabled pusht; then
  echo "== pusht =="
  # SS=0.2: frame 0 of both source clips shows a human hand resetting the
  # scene; seek 0.2s in to start on the actual rollout.
  SS=0.2 run "$SRC/multimodal feature/push T/wrist_cam.mp4"     "$DST/pusht/mode1.mp4" "" -crf 21 -g 30
  SS=0.2 run "$SRC/multimodal feature/push T/wrist_cam (1).mp4" "$DST/pusht/mode2.mp4" "" -crf 21 -g 30
  poster "$DST/pusht/mode1.mp4" "$POST/pusht_mode1.jpg"
  poster "$DST/pusht/mode2.mp4" "$POST/pusht_mode2.jpg"
fi

# =============================================================================
# blockpush: bt709 (not HLG) block-push, two colours.
# Verified from early vs. late/final frames (_src/media/blockpush_*_{early,
# final}.png): PushCube_up.mp4 pushes the ORANGE cube (purple untouched);
# PushCube_down2.mp4 pushes the PURPLE cube (orange untouched).
# =============================================================================
if group_enabled blockpush; then
  echo "== blockpush =="
  run "$SRC/multimodal feature/block push/PushCube_up.mp4"    "$DST/blockpush/up.mp4"   "scale=-2:720" -crf 23 -g 60
  run "$SRC/multimodal feature/block push/PushCube_down2.mp4" "$DST/blockpush/down.mp4" "scale=-2:720" -crf 23 -g 60
  poster "$DST/blockpush/up.mp4"   "$POST/blockpush_up.jpg"
  poster "$DST/blockpush/down.mp4" "$POST/blockpush_down.jpg"
fi

# =============================================================================
# bypass: native 640x480 @ 10fps
# =============================================================================
if group_enabled bypass; then
  echo "== bypass =="
  run "$SRC/multimodal feature/bypass/recording_cam.mp4"     "$DST/bypass/path1.mp4" "" -crf 21 -g 30
  run "$SRC/multimodal feature/bypass/recording_cam (1).mp4" "$DST/bypass/path2.mp4" "" -crf 21 -g 30
  poster "$DST/bypass/path1.mp4" "$POST/bypass_path1.jpg"
  poster "$DST/bypass/path2.mp4" "$POST/bypass_path2.jpg"
fi

# =============================================================================
# jigsaw: Franka PINGTU puzzle, 2x speed (10fps source -> 20fps output)
#
# NOTE: setpts=PTS/2 alone is not enough. Verified (_src/media/
# test_jigsaw_r20.mp4 vs. the no -r version): with no explicit -r/fps, this
# ffmpeg still tags the output 10fps and DROPS every other frame to hit
# that grid (nb_frames halved, r_frame_rate stayed 10/1) -- same net speed,
# but choppier (half the temporal resolution) instead of a smooth 20fps
# timelapse. `-r 20` is an output/encoder option, not a `-vf` filter, so it
# does not conflict with "do not insert fps= [filter]"; with it, all
# ~607 source frames are kept and the stream is correctly tagged 20fps.
# =============================================================================
if group_enabled jigsaw; then
  echo "== jigsaw =="
  run "$SRC/emergent feature/PINGTU/trained/wrist_cam.mp4"      "$DST/jigsaw/seen_1.mp4"     "setpts=PTS/2" -r 20 -crf 22 -g 40
  run "$SRC/emergent feature/PINGTU/trained/wrist_cam (1).mp4"  "$DST/jigsaw/seen_2.mp4"     "setpts=PTS/2" -r 20 -crf 22 -g 40
  run "$SRC/emergent feature/PINGTU/emergent/wrist_cam.mp4"     "$DST/jigsaw/emergent_1.mp4" "setpts=PTS/2" -r 20 -crf 22 -g 40
  run "$SRC/emergent feature/PINGTU/emergent/wrist_cam (3).mp4" "$DST/jigsaw/emergent_2.mp4" "setpts=PTS/2" -r 20 -crf 22 -g 40
  poster "$DST/jigsaw/seen_1.mp4"     "$POST/jigsaw_seen_1.jpg"
  poster "$DST/jigsaw/seen_2.mp4"     "$POST/jigsaw_seen_2.jpg"
  poster "$DST/jigsaw/emergent_1.mp4" "$POST/jigsaw_emergent_1.jpg"
  poster "$DST/jigsaw/emergent_2.mp4" "$POST/jigsaw_emergent_2.jpg"
fi

# =============================================================================
# table: R1-Lite table tidying, 6x speed (long rollouts -> short clips).
# 1234.mp4 is bt709 8-bit (no tonemap); the other four are HLG. Encoding
# these is slow (93-197 MB HEVC sources) -- be patient / run in background.
# =============================================================================
if group_enabled table; then
  echo "== table =="
  GREEN=1 run "$SRC/emergent feature/table/trained/1234.mp4"   "$DST/table/seen_1234.mp4"       "$(table_vf sdr)" -crf 24 -g 60
  GREEN=1 run "$SRC/emergent feature/table/trained/2143.mp4"   "$DST/table/seen_2143.mp4"       "$(table_vf hlg)" -crf 24 -g 60
  GREEN=1 run "$SRC/emergent feature/table/emergent/1243.mp4"  "$DST/table/emergent_1243.mp4"   "$(table_vf hlg)" -crf 24 -g 60
  GREEN=1 run "$SRC/emergent feature/table/emergent/2134.mp4"  "$DST/table/emergent_2134.mp4"   "$(table_vf hlg)" -crf 24 -g 60
  GREEN=1 run "$SRC/emergent feature/table/emergent/3214.mp4"  "$DST/table/emergent_3214.mp4"   "$(table_vf hlg)" -crf 24 -g 60
  poster "$DST/table/seen_1234.mp4"     "$POST/table_seen_1234.jpg"
  poster "$DST/table/seen_2143.mp4"     "$POST/table_seen_2143.jpg"
  poster "$DST/table/emergent_1243.mp4" "$POST/table_emergent_1243.jpg"
  poster "$DST/table/emergent_2134.mp4" "$POST/table_emergent_2134.jpg"
  poster "$DST/table/emergent_3214.mp4" "$POST/table_emergent_3214.jpg"
fi

# =============================================================================
# cooking: simulation, 1024x1024 @ 5fps, 2x speed. Revision 4 swapped in
# clean re-renders (no text banner, so COOK_TOP / COOK_BOT above no longer
# apply) delivered as five WeChat clips; they are identified by order, not
# by the old Demo_xx / unseen_xx names. Frame-by-frame reading of each clip
# against paper fig. S6 (A–E, "Cooking" in the Supplementary):
#   203900_169 (16.0 s)  -> order B  pepper · broccoli · pot · stove   (demonstrated)
#   203924_353 (21.6 s)  -> order A  pot · stove · pepper · broccoli   (demonstrated)
#   203930_286 (22.8 s)  -> order C  stove · pot · pepper · broccoli   (demonstrated)
#   203937_535 (55.0 s)  -> order D  pot · pepper · broccoli · stove   (emergent)
#   203943_287 (60.8 s)  -> order E  stove · pot · broccoli · pepper   (emergent)
# Same -r fix as jigsaw: setpts=PTS/2 alone gets frame-dropped back down to
# the source's 5fps by default, so force -r 10 to keep all frames.
# =============================================================================
COOK_SRC="/Users/lijingliang/Downloads/网页视频-仿真"
if group_enabled cooking; then
  echo "== cooking =="
  COOK_VF="setpts=PTS/2,scale=720:720"

  shopt -s nullglob
  cookA=("$COOK_SRC/"*_203924_*.mp4)
  cookB=("$COOK_SRC/"*_203900_*.mp4)
  cookC=("$COOK_SRC/"*_203930_*.mp4)
  cookD=("$COOK_SRC/"*_203937_*.mp4)
  cookE=("$COOK_SRC/"*_203943_*.mp4)
  shopt -u nullglob

  run "${cookA[0]}" "$DST/cooking/order_a.mp4" "$COOK_VF" -r 10 -crf 23 -g 20
  run "${cookB[0]}" "$DST/cooking/order_b.mp4" "$COOK_VF" -r 10 -crf 23 -g 20
  run "${cookC[0]}" "$DST/cooking/order_c.mp4" "$COOK_VF" -r 10 -crf 23 -g 20
  run "${cookD[0]}" "$DST/cooking/order_d.mp4" "$COOK_VF" -r 10 -crf 23 -g 20
  run "${cookE[0]}" "$DST/cooking/order_e.mp4" "$COOK_VF" -r 10 -crf 23 -g 20
  for o in a b c d e; do
    poster "$DST/cooking/order_$o.mp4" "$POST/cooking_order_$o.jpg"
  done
fi

echo "done."
