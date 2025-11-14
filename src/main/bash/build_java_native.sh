#!/bin/bash

SPATH="$(readlink -f "$BASH_SOURCE")"
for A in 1 2 3 4 ; do
	SPATH="$(dirname "$SPATH")"
done
cd "$SPATH"
manualInstall() {
	NP="$(ls -1 graalvm*/bin | tail -n 1)"
	if [ "$NP" == "" ] ; then
		ARCH="$(uname -m | perl -pe 's/x86_64/x64/g')"
		OS="$(uname | tr '[:upper:]' '[:lower:]' | perl -pe 's/darwin/macos/g')"
		URL="$(curl -s https://api.github.com/repos/graalvm/graalvm-ce-builds/releases/latest \
			| jq -r '.assets[] | select(.name | test("'"$OS"'.*tar.gz$")) | select(.name | test("'"$ARCH"'.*tar.gz$")) | .browser_download_url')"
		curl -sLO "$URL"
		TAR="$(ls -1 graalvm*.tar.gz | tail -n 1)"
		tar -xf "$TAR"
		NP="$(ls -1 graalvm*/bin | tail -n 1)"
	fi
	NP="$(ls -1 graalvm*/bin | tail -n 1)"
	NP="$(readlink -f "$NI")"
	PATH="$PATH:$NP"
	export PATH
}
. src/main/bash/err.sh
get native-image jdk25-graalvm-bin

NAME="Mp4DefaultTrack"
native-image \
	--silent \
	--no-fallback \
	-H:+UnlockExperimentalVMOptions \
	-H:+StripDebugInfo \
	-H:ClassInitialization=.:build_time \
	-cp "target/mp4JavaTrack.jar" \
	"Mp4DefaultTrack"
mv mp4defaulttrack target/mp4JavaTrack
