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
sudo bash -c "sync; echo 3 > /proc/sys/vm/drop_caches"

doit() {
	OUT="$1"
	shift
	local A; A="$(date +%s.%N)"
	/bin/time -v "$@" list "$T" \
		> "$F/$OUT.txt" \
		2> "$F/${OUT}_time.txt"
	local B; B="$(date +%s.%N)"
	echo "$B-$A" | bc > "$F/${OUT}_date.txt"
	{
		md5sum "$T"
		"$@" set "$T" 3 default
		"$@" list "$T"
		"$@" unset "$T" 3 default
		md5sum "$T"
	} >> "$F/$OUT.txt"
}

doit java java -jar target/mp4JavaTrack.jar
doit javanative target/mp4JavaTrack
doit rust target/mp4RustTrack
doit go target/mp4GoTrack
doit cpp target/mp4CppTrack
doit python python3 src/main/python/Mp4DefaultTrack.py
doit javascript node src/main/javascript/Mp4DefaultTrack.js
doit perl perl src/main/perl/Mp4DefaultTrack.pl
doit bash bash src/main/bash/Mp4DefaultTrack.sh

{
echo "### Memory Usage:"
echo '```'
grep "Maximum resident" "$F"/* \
	| perl -pe 's/.*\/(.*)_time.* ([0-9]+)\n/$2\t$1\n/g' \
	| sort -n
echo '```'
echo
echo "### Time Usage:"
echo '```'
grep . "$F"/*_date.txt \
	| perl -pe 's/.*\/(.*)_date.txt:([0-9.]+)\n/$2\t$1\n/g' \
	| sort -n
echo '```'
} > "$F/all.txt"

MD5S="$(
cd target/test_results
ls -1 | grep -Pv "_|all.txt" | xargs md5sum | sort
)"
CS="$(echo "$MD5S" | perl -pe 's/ .*//g' | uniq -c)"
L="$(echo "$CS" | grep -c .)"
if [ "$L" -gt "1" ] ; then
	while read -r CP ; do
		C="$(echo "$CP" | perl -pe 's/^ +//g;s/ .*//g')"
		P="$(echo "$CP" | perl -pe 's/.* //g')"
		echo "$CP"
		echo "$MD5S" | grep "$P" | perl -pe 's/.* //g;s/^/\t/g'
	done  < <(echo "$CS")
fi
