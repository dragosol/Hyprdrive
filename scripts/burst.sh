#!/usr/bin/env bash
# Frame-by-frame capture. Stills cannot answer "is it animated or does it snap".
#
# usage: burst.sh <tag> <frames> <lua-dispatch-expr>
#
# Capture uncompressed ppm at native size into tmpfs, convert afterwards.
# Measured cost per frame on this VM:
#   grim -t ppm  -> /dev/shm   38ms   <- this
#   grim -s 0.25 -> /dev/shm  130ms   (grim scales in software, never do this)
#   grim png     -> /mnt/host 360ms   (slower than the animation being measured)
# ponytail: 7.4MB/frame in tmpfs, so keep N modest. 24 frames ~= 900ms of motion.
export WAYLAND_DISPLAY=wayland-1
TAG=${1:?tag}; N=${2:-24}; EXPR=${3:-}
TMP=/dev/shm/frames
OUT=/mnt/host/frames
mkdir -p $TMP $OUT
rm -f $TMP/*.ppm $TMP/times.txt $OUT/${TAG}-*.png

grim -t ppm $TMP/warm.ppm   # warm the path so frame 1 is not an outlier

START=$(date +%s%N)
[ -n "$EXPR" ] && hyprctl eval "$EXPR" >/dev/null
for i in $(seq -w 1 $N); do
  grim -t ppm $TMP/f${i}.ppm
  echo "$i $(( ($(date +%s%N) - START) / 1000000 ))"
done > $TMP/times.txt
TOTAL=$(( ($(date +%s%N) - START) / 1000000 ))

cp $TMP/times.txt $OUT/${TAG}-times.txt
for f in $TMP/f*.ppm; do
  i=$(basename $f .ppm | tr -d 'f')
  magick $f -resize 25% $OUT/${TAG}-${i}.png
done
rm -f $TMP/*.ppm
echo "captured $N frames over ${TOTAL}ms ($(( TOTAL / N ))ms/frame)"
