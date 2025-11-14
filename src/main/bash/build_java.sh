#!/bin/bash

SPATH="$(readlink -f "$BASH_SOURCE")"
for A in 1 2 3 4 ; do
	SPATH="$(dirname "$SPATH")"
done
cd "$SPATH"
. src/main/bash/err.sh
get javac default-jdk

javac -d "target/classes" "src/main/java/Mp4DefaultTrack.java"
(
	cd "target/classes"
	mkdir -p "META-INF"
	{
		echo "Manifest-Version: 1.0"
		echo "Main-Class: Mp4DefaultTrack"
	} > "META-INF/MANIFEST.MF"
	jar -c -m META-INF/MANIFEST.MF -f "../mp4JavaTrack.jar" .
)
