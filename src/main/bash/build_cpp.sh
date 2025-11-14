#!/bin/bash

SPATH="$(readlink -f "$BASH_SOURCE")"
for A in 1 2 3 4 ; do
	SPATH="$(dirname "$SPATH")"
done
cd "$SPATH"
. src/main/bash/err.sh
get g++

g++ -std=c++17 -O2 -o target/mp4CppTrack src/main/cpp/Mp4DefaultTrack.cpp
