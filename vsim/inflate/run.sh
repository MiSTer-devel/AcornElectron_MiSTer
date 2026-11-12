#!/bin/bash
# Test rtl/inflate.sv against Python's zlib.
#   ./run.sh [zip-dir]     zip-dir: zips holding gzipped .uef files
#                          (default ../../software/mister11/tapes, local only)
# Vectors are written to vectors/ (not committed: they include the tapes).
set -u
cd "$(dirname "$0")"
make -s || exit 1
SRC=${1:-../../software/mister11/tapes}
rm -rf vectors; mkdir -p vectors
python3 -I mkvec.py vectors "$SRC"
ls vectors/*.gz | xargs -P 8 -I{} sh -c 'f={}; ./obj_dir/Vinflate "$f" "${f%.gz}.out" 7' > vectors/results.txt 2>&1
pass=$(grep -c '^PASS' vectors/results.txt); total=$(ls vectors/*.gz | wc -l | tr -d ' ')
grep -v '^PASS' vectors/results.txt | head -20
echo "$pass / $total passed"
[ "$pass" = "$total" ]
