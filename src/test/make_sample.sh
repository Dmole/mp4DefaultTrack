#!/bin/bash

SPATH="$(readlink -f "$BASH_SOURCE")"
for A in 1 2 3 ; do
	SPATH="$(dirname "$SPATH")"
done
cd "$SPATH"
. src/main/bash/err.sh
get ffmpeg

OUT="target/test.mp4"
rm -f "$OUT" vid.mp4 s1.srt s2.srt a1.m4a a2.m4a
ffmpeg -v error -f lavfi -i "mandelbrot=s=160x120:rate=1" \
	-frames:v 10 -pix_fmt yuv420p -c:v libx264 vid.mp4 -y
ffmpeg -v error -f lavfi -i "sine=frequency=440:duration=0.001" -c:a aac a1.m4a -y
ffmpeg -v error -f lavfi -i "sine=frequency=660:duration=0.001" -c:a aac a2.m4a -y
cat > s1.srt <<EOF
1
00:00:00,000 --> 00:00:00,001
a
EOF
cat > s2.srt <<EOF
1
00:00:00,000 --> 00:00:00,001
b
EOF
ffmpeg -v error \
	-i vid.mp4 -i a1.m4a -i a2.m4a -i s1.srt -i s2.srt \
	-map 0:v:0 -map 1:a:0 -map 2:a:0 -map 3:s:0 -map 4:s:0 \
	-c:v copy -c:a copy -c:s mov_text \
	-disposition:v:0 default \
	-disposition:a:0 default \
	-disposition:a:1 0 \
	-disposition:s:0 0 \
	-disposition:s:1 0 \
	"$OUT" -y
rm -f vid.mp4 s1.srt s2.srt a1.m4a a2.m4a
