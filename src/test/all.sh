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

A="$(date +%s.%N)"
/bin/time -v java -jar target/mp4JavaTrack.jar list "$T" \
	> "$F/java.txt" \
	2> "$F/java_time.txt"
B="$(date +%s.%N)"
echo "$B-$A" | bc > "$F/java_date.txt"

A="$(date +%s.%N)"
/bin/time -v target/mp4JavaTrack list "$T" \
	> "$F/javanative.txt" \
	2> "$F/javanative_time.txt"
B="$(date +%s.%N)"
echo "$B-$A" | bc > "$F/javanative_date.txt"

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

A="$(date +%s.%N)"
/bin/time -v bash src/main/bash/Mp4DefaultTrack.sh list "$T" \
	> "$F/bash.txt" \
	2> "$F/bash_time.txt"
B="$(date +%s.%N)"
echo "$B-$A" | bc > "$F/bash_date.txt"

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
