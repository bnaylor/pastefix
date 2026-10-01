#!/bin/sh
# Builds docs/media/pastefix-tour.gif from the frames the DemoReel test renders.
#
#   1. Render (under the GUI lease; demo windows appear briefly):
#        TEST_RUNNER_PFX_DEMO_OUT=/tmp/pastefix-demo scripts/test-app.sh "-only-testing:PastefixTests/DemoReel/tour()"
#   2. Assemble:
#        scripts/make-demo-gif.sh /tmp/pastefix-demo/tour docs/media/pastefix-tour.gif
#
# Each frame is the real panel window (dark, with its shadow), captured by the test host itself, so
# no Screen Recording permission is needed. Here it goes onto a dark backdrop with its scene's
# caption (captions.txt: "<first frame number>\t<caption>"), is scaled to 720 px wide, and the
# frames are joined with their hold times (frames.txt, an ffmpeg concat list) into a 256-colour GIF.
set -eu
src=${1:?usage: make-demo-gif.sh <tour dir> <out.gif>}
out=${2:?usage: make-demo-gif.sh <tour dir> <out.gif>}
font=${PFX_DEMO_FONT:-/System/Library/Fonts/SFNS.ttf}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

caption=""
for f in "$src"/[0-9][0-9][0-9]-*.png; do
  base=$(basename "$f")
  n=$(echo "$base" | sed -E 's/^0*([0-9]+)-.*/\1/')
  c=$(awk -F '\t' -v n="$n" '$1 == n { print $2 }' "$src/captions.txt")
  [ -n "$c" ] && caption=$c
  # Window (with shadow) centred on the backdrop, caption underneath, then down to 720 px.
  magick "$f" -background none -gravity center -extent 1600x1200 \
    \( -size 1600x1330 xc:'#141518' \) +swap -gravity north -geometry +0+0 -composite \
    -font "$font" -pointsize 44 -fill '#e8e8ea' -gravity south -annotate +0+46 "$caption" \
    -resize 720x "$work/$base"
done
sed "s#^file '#file '$work/#" "$src/frames.txt" > "$work/frames.txt"
# ffmpeg's concat demuxer needs the last file repeated to honour its duration.
last=$(grep "^file" "$work/frames.txt" | tail -1)
echo "$last" >> "$work/frames.txt"
ffmpeg -loglevel error -y -f concat -safe 0 -i "$work/frames.txt" \
  -vf "split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" \
  -fps_mode vfr "$out"
echo "wrote $out ($(du -h "$out" | cut -f1))"
