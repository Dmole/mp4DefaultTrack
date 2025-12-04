#!/bin/bash

SPATH="$(readlink -f "$BASH_SOURCE")"
for A in 1 2 3 4 ; do
	SPATH="$(dirname "$SPATH")"
done
cd "$SPATH"
. src/main/bash/err.sh
get bun bun-bin
bun build src/main/javascript/Mp4DefaultTrack.js \
	--compile \
	--minify \
	--optimize \
	--outfile target/Mp4JavascriptTrack
