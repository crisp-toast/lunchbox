#!/bin/bash
# Builds the site hero from the rendered glass-break frames: a longer hold on the intact
# panes, with their colors boosted so the pile reads as loud clutter, easing back to the
# render's own colors just after the hit. Only colored pixels are boosted (the gray
# backdrop stays put), so nothing shifts when the boost fades.
#   hero_grade.sh <render frames dir> <out dir>
set -euo pipefail
SRC="$1"; OUT="$2"
HIT_IN=18      # the hit frame in the render
HOLD=27        # frames of intact panes in the output (0.9 s at 30 fps)
FADE=10        # frames after the hit for the boost to ease out
BOOST=1.6      # saturation at full strength
GREEN=0.4      # how much of the boost the green pane gives back (it would glare)
LAST_IN=$(ls "$SRC" | sed -n 's/^frame_\([0-9]*\)\.png$/\1/p' | sort -n | tail -1 | sed 's/^0*//')
mkdir -p "$OUT/frames"
grade() { # <in png> <out png> <saturation> <green cut>
  ffmpeg -v error -y -i "$1" -filter_complex "[0]format=yuv444p,split=3[base][b][m];[b]eq=saturation=${3},format=rgb24,huesaturation=saturation=-${4}:colors=g,format=yuv444p[boost];[m]geq=lum='clip((abs(cb(X,Y)-128)+abs(cr(X,Y)-128)-3)*16,0,255)':cb='clip((abs(cb(X,Y)-128)+abs(cr(X,Y)-128)-3)*16,0,255)':cr='clip((abs(cb(X,Y)-128)+abs(cr(X,Y)-128)-3)*16,0,255)'[mask];[base][boost][mask]maskedmerge,format=rgb24" -frames:v 1 "$2"
}
out() { printf '%s/frames/frame_%04d.png' "$OUT" "$1"; }
grade "$SRC/frame_0000.png" "$OUT/hold.png" "$BOOST" "$GREEN"
for n in $(seq 0 $((HOLD - 1))); do ln -f "$OUT/hold.png" "$(out $n)"; done
for i in $(seq 0 $((LAST_IN - HIT_IN))); do
  n=$((HOLD + i)); in="$SRC/$(printf 'frame_%04d.png' $((HIT_IN + i)))"
  if [ "$i" -le "$FADE" ]; then
    k=$(python3 -c "print(round((1 - $i / $FADE) ** 2, 4))")
    grade "$in" "$(out $n)" "$(python3 -c "print(1 + ($BOOST - 1) * $k)")" "$(python3 -c "print($GREEN * $k)")"
  else
    ln -f "$in" "$(out $n)"
  fi
done
rm "$OUT/hold.png"
echo "$(ls "$OUT/frames" | wc -l | tr -d ' ') frames; hit at frame $HOLD ($(python3 -c "print(round($HOLD/30, 2))") s)"
