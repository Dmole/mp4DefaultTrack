#!/bin/bash

T=README.md_new
grep -A 1 -B 99 "comparison:" README.md > "$T"
cat target/test_results/all.txt >> "$T"
mv "$T" README.md
