#!/bin/bash

SPATH="$(readlink -f "$BASH_SOURCE")"
for A in 1 2 3 4 ; do
	SPATH="$(dirname "$SPATH")"
done
cd "$SPATH"
. src/main/bash/err.sh

bash src/main/bash/build_java.sh
bash src/main/bash/build_java_native.sh
bash src/main/bash/build_go.sh
bash src/main/bash/build_cpp.sh
bash src/main/bash/build_rust.sh
bash src/test/make_sample.sh
