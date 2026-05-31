#!/bin/bash

SPATH="$(readlink -f "$BASH_SOURCE")"
for A in 1 2 3 4 ; do
	SPATH="$(dirname "$SPATH")"
done
cd "$SPATH"
. src/main/bash/err.sh

python -m compileall src/main/python/Mp4DefaultTrack.py
mv src/main/python/__pycache__/Mp4DefaultTrack.cpython-*.pyc target/mp4PythonTrack.pyc

#Cython is cheating?
get pip python-pip
if [ ! -d target/python_venv ] ; then
	python -m venv target/python_venv
	target/python_venv/bin/python -m pip install --upgrade cython
fi
target/python_venv/bin/cython --embed -3 src/main/python/Mp4DefaultTrack.py -o src/main/python/Mp4DefaultTrack.c
gcc src/main/python/Mp4DefaultTrack.c $(python3-config --embed --cflags --ldflags) -o target/mp4CythonTrack
