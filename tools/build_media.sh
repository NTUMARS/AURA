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

# Galaxea R1 Lite clips (fast, pickcup, pickveg, table) are shown as
# recorded: no grade, no exposure or green-screen change. The HLG phone
# recordings get only the standard HLG -> BT.709 conversion, done by
# VideoToolbox (scale_vt) since this ffmpeg build has no zscale; SDR
# recordings are only scaled.
is_hlg() {
  [[ "$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer -of default=nw=1:nk=1 "$1")" == "arib-std-b67" ]]
}

group_enabled() {
  [[ -z "$ONLY" || "$ONLY" == "$1" ]]
}

# run <input> <output> <vf-or-empty> [extra ffmpeg args...]
# Honours SS / T env vars for trims: SS is applied as a fast input seek
# (-ss before -i), T as an output-duration cap (-t after -i, before the
# output file) so it works correctly even after a setpts speed change.
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
  args+=("${VENC_COMMON[@]}" "$@" "$out")
  echo "encode -> $out"
  ffmpeg "${args[@]}"
}

# r1 <input> <output> <WxH> <extra-vf-or-empty> [extra ffmpeg args...]
# R1 Lite clips: colour conversion and scaling only (see is_hlg). Honours
# SS / T like run().
r1() {
  local in="$1" out="$2" w="${3%x*}" h="${3#*x}" post="$4"; shift 4
  if [[ -f "$out" && "$FORCE" != "1" ]]; then
    echo "skip (exists): $out"
    return 0
  fi
  mkdir -p "$(dirname "$out")"
  local args=(-y -hide_banner -loglevel error -threads 0) vf
  if is_hlg "$in"; then
    args+=(-hwaccel videotoolbox -hwaccel_output_format videotoolbox_vld)
    vf="scale_vt=w=${w}:h=${h}:color_matrix=bt709:color_primaries=bt709:color_transfer=bt709,hwdownload,format=p010le,format=yuv420p"
  else
    vf="scale=${w}:${h},format=yuv420p"
  fi
  if [[ -n "$post" ]]; then
    vf="${vf},${post}"
  fi
  if [[ -n "${SS:-}" ]]; then
    args+=(-ss "$SS")
  fi
  args+=(-i "$in")
  if [[ -n "${T:-}" ]]; then
    args+=(-t "$T")
  fi
  echo "encode -> $out"
  ffmpeg "${args[@]}" -vf "$vf" "${VENC_COMMON[@]}" \
    -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv "$@" "$out"
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
  SS=$FAST_AURA_SS r1 "$SRC/fast and smother/our.mp4" "$DST/fast/aura.mp4" 1280x720 "" -crf 22 -g 30
  SS=$FAST_FM_SS T=$FAST_FM_T r1 "$SRC/fast and smother/FM.mp4"  "$DST/fast/fm.mp4"   1280x720 "" -crf 22 -g 30
  poster "$DST/fast/aura.mp4" "$POST/fast_aura.jpg" 0
  poster "$DST/fast/fm.mp4"   "$POST/fast_fm.jpg"   0
fi

# =============================================================================
# pickcup: HLG multimodal grasp demos (rim vs handle)
# =============================================================================
if group_enabled pickcup; then
  echo "== pickcup =="
  r1 "$SRC/multimodal feature/pick cup/rim1.mp4"    "$DST/pickcup/rim1.mp4"    1280x720 "" -crf 23 -g 60
  r1 "$SRC/multimodal feature/pick cup/rim2.mp4"    "$DST/pickcup/rim2.mp4"    1280x720 "" -crf 23 -g 60
  r1 "$SRC/multimodal feature/pick cup/handle2.mp4" "$DST/pickcup/handle2.mp4" 1280x720 "" -crf 23 -g 60
  r1 "$SRC/multimodal feature/pick cup/handle3.mp4" "$DST/pickcup/handle3.mp4" 1280x720 "" -crf 23 -g 60
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
  r1 "$SRC/multimodal feature/pick vegetable/pick red.mp4"   "$DST/pickveg/carrot.mp4" 1280x720 "" -crf 23 -g 60
  r1 "$SRC/multimodal feature/pick vegetable/pick white.mp4" "$DST/pickveg/daikon.mp4" 1280x720 "" -crf 23 -g 60
  SS=$SHAKE_A_SS T=$SHAKE_A_T r1 \
    "$SRC/multimodal feature/pick vegetable/FM shake on lower epochs/121548c4803f057af64b8dc0eace1728_raw.mp4" \
    "$DST/pickveg/fm_shake_a.mp4" 1280x720 "" -crf 23 -g 60
  SS=$SHAKE_B_SS T=$SHAKE_B_T r1 \
    "$SRC/multimodal feature/pick vegetable/FM shake on lower epochs/8004070cbd2fddb6ae62855e90f9ce86_raw.mp4" \
    "$DST/pickveg/fm_shake_b.mp4" 1280x720 "" -crf 23 -g 60
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
  TABLE_VF="setpts=PTS/6,fps=30"
  r1 "$SRC/emergent feature/table/trained/1234.mp4"   "$DST/table/seen_1234.mp4"       960x540 "$TABLE_VF" -crf 24 -g 60
  r1 "$SRC/emergent feature/table/trained/2143.mp4"   "$DST/table/seen_2143.mp4"       960x540 "$TABLE_VF" -crf 24 -g 60
  r1 "$SRC/emergent feature/table/emergent/1243.mp4"  "$DST/table/emergent_1243.mp4"   960x540 "$TABLE_VF" -crf 24 -g 60
  r1 "$SRC/emergent feature/table/emergent/2134.mp4"  "$DST/table/emergent_2134.mp4"   960x540 "$TABLE_VF" -crf 24 -g 60
  r1 "$SRC/emergent feature/table/emergent/3214.mp4"  "$DST/table/emergent_3214.mp4"   960x540 "$TABLE_VF" -crf 24 -g 60
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
