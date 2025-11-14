#!/bin/bash

SPATH="$(readlink -f "$BASH_SOURCE")"
for A in 1 2 3 ; do
	SPATH="$(dirname "$SPATH")"
done
cd "$SPATH"
. src/main/bash/err.sh
get time
get bc

F="target/test_results"
mkdir -p "$F"
T="target/test.mp4"

A="$(date +%s.%N)"
/bin/time -v java -jar target/mp4JavaTrack.jar list "$T" \
	> "$F/java.txt" \
	2> "$F/java_time.txt"
B="$(date +%s.%N)"
echo "$B-$A" | bc > "$F/java_date.txt"

A="$(date +%s.%N)"
/bin/time -v target/mp4JavaTrack list "$T" \
	> "$F/javaNative.txt" \
	2> "$F/javaNative_time.txt"
B="$(date +%s.%N)"
echo "$B-$A" | bc > "$F/javaNative_date.txt"

A="$(date +%s.%N)"
/bin/time -v target/mp4RustTrack list "$T" \
	> "$F/rust.txt" \
	2> "$F/rust_time.txt"
B="$(date +%s.%N)"
echo "$B-$A" | bc > "$F/rust_date.txt"

A="$(date +%s.%N)"
/bin/time -v target/mp4GoTrack list "$T" \
	> "$F/go.txt" \
	2> "$F/go_time.txt"
B="$(date +%s.%N)"
echo "$B-$A" | bc > "$F/go_date.txt"

A="$(date +%s.%N)"
/bin/time -v target/mp4CppTrack list "$T" \
	> "$F/cpp.txt" \
	2> "$F/cpp_time.txt"
B="$(date +%s.%N)"
echo "$B-$A" | bc > "$F/cpp_date.txt"

A="$(date +%s.%N)"
/bin/time -v python3 src/main/python/Mp4DefaultTrack.py list "$T" \
	> "$F/python.txt" \
	2> "$F/python_time.txt"
B="$(date +%s.%N)"
echo "$B-$A" | bc > "$F/python_date.txt"

A="$(date +%s.%N)"
/bin/time -v node src/main/javascript/Mp4DefaultTrack.js list "$T" \
	> "$F/javascript.txt" \
	2> "$F/javascript_time.txt"
B="$(date +%s.%N)"
echo "$B-$A" | bc > "$F/javascript_date.txt"

A="$(date +%s.%N)"
/bin/time -v perl src/main/perl/Mp4DefaultTrack.pl list "$T" \
	> "$F/perl.txt" \
	2> "$F/perl_time.txt"
B="$(date +%s.%N)"
echo "$B-$A" | bc > "$F/perl_date.txt"

{
echo "Memory Usage:"
grep "Maximum resident" "$F"/* \
	| perl -pe 's/.*\/(.*)_time.* ([0-9]+)\n/$2\t$1\n/g' \
	| sort -n
echo
echo "Time Usage:"
grep . "$F"/*_date.txt \
	| perl -pe 's/.*\/(.*)_date.txt:([0-9.]+)\n/$2\t$1\n/g' \
	| sort -n
} > "$F/all.txt"

