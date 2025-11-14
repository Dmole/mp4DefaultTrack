#!/bin/bash

SPATH="$(readlink -f "$BASH_SOURCE")"
for A in 1 2 3 4 ; do
	SPATH="$(dirname "$SPATH")"
done
cd "$SPATH"
. src/main/bash/err.sh
get go

go build -ldflags "-s -w" -o target/mp4GoTrack src/main/go/Mp4DefaultTrack.go
