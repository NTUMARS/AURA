#!/usr/bin/env bash
# Print a table of every mp4 under assets/videos/ (path, duration, WxH, fps,
# kbps, size MB) plus totals, and fail if the budget is blown:
#   - total size of all videos > 80 MB
#   - any single video > 15 MB
#   - any poster > 250 KB
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DST="$ROOT/assets/videos"
POST="$ROOT/assets/posters"

MAX_TOTAL_MB=80
MAX_FILE_MB=15
MAX_POSTER_KB=250

status=0

printf "%-45s %8s %10s %7s %8s %8s\n" "path" "dur(s)" "WxH" "fps" "kbps" "size(MB)"
printf "%-45s %8s %10s %7s %8s %8s\n" "----" "------" "---" "---" "----" "--------"

total_bytes=0
count=0

while IFS= read -r -d '' f; do
  rel="${f#"$ROOT"/}"
  probe=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height,r_frame_rate,avg_frame_rate \
    -show_entries format=duration,size,bit_rate \
    -of default=noprint_wrappers=1 "$f")

  width=$(awk -F= '/^width=/{print $2}' <<<"$probe")
  height=$(awk -F= '/^height=/{print $2}' <<<"$probe")
  avg_fr=$(awk -F= '/^avg_frame_rate=/{print $2}' <<<"$probe")
  dur=$(awk -F= '/^duration=/{print $2}' <<<"$probe")
  size=$(awk -F= '/^size=/{print $2}' <<<"$probe")
  bitrate=$(awk -F= '/^bit_rate=/{print $2}' <<<"$probe")

  fps=$(python3 -c "
n,_,d = '$avg_fr'.partition('/')
d = d or '1'
try:
    print(round(float(n)/float(d), 2))
except Exception:
    print('?')
")
  kbps="?"
  if [[ -n "${bitrate:-}" && "$bitrate" != "N/A" ]]; then
    kbps=$(python3 -c "print(round(${bitrate}/1000))")
  elif [[ -n "${size:-}" && -n "${dur:-}" ]]; then
    kbps=$(python3 -c "print(round(${size}*8/1000/${dur}))" 2>/dev/null || echo "?")
  fi
  size_mb=$(python3 -c "print(round(${size:-0}/1024/1024, 2))")
  dur_r=$(python3 -c "print(round(${dur:-0}, 1))" 2>/dev/null || echo "?")

  printf "%-45s %8s %10s %7s %8s %8s\n" "$rel" "$dur_r" "${width}x${height}" "$fps" "$kbps" "$size_mb"

  total_bytes=$(( total_bytes + ${size:-0} ))
  count=$((count + 1))

  if (( ${size:-0} > MAX_FILE_MB * 1024 * 1024 )); then
    echo "  !! exceeds per-file limit of ${MAX_FILE_MB} MB (${size_mb} MB)"
    status=1
  fi
done < <(find "$DST" -type f -name '*.mp4' -print0 | sort -z)

total_mb=$(python3 -c "print(round(${total_bytes}/1024/1024, 2))")
printf "%-45s %8s %10s %7s %8s %8s\n" "----" "------" "---" "---" "----" "--------"
printf "%-45s %8s %10s %7s %8s %8s\n" "TOTAL ($count files)" "" "" "" "" "$total_mb"

if (( total_bytes > MAX_TOTAL_MB * 1024 * 1024 )); then
  echo "!! total video size ${total_mb} MB exceeds budget of ${MAX_TOTAL_MB} MB"
  status=1
fi

echo
echo "posters:"
printf "%-45s %10s\n" "path" "size(KB)"
poster_count=0
while IFS= read -r -d '' f; do
  rel="${f#"$ROOT"/}"
  bytes=$(wc -c < "$f" | tr -d ' ')
  kb=$(python3 -c "print(round(${bytes}/1024, 1))")
  printf "%-45s %10s\n" "$rel" "$kb"
  poster_count=$((poster_count + 1))
  if (( bytes > MAX_POSTER_KB * 1024 )); then
    echo "  !! exceeds poster limit of ${MAX_POSTER_KB} KB (${kb} KB)"
    status=1
  fi
done < <(find "$POST" -type f -name '*.jpg' -print0 | sort -z)
echo "($poster_count posters)"

echo
if [[ $status -eq 0 ]]; then
  echo "OK: within budget (total ${total_mb} MB / ${MAX_TOTAL_MB} MB)."
else
  echo "FAIL: budget exceeded, see !! lines above."
fi

exit $status
