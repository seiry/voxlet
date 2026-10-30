#!/bin/zsh
# Repeats the recordings on an existing corpus into a fresh directory: rerun.sh <corpus dir> <new dir>
set -eu
src=${1:?corpus dir}
dst=${2:?new dir}
mkdir -p "$dst"
cp "$src"/{remote,near,mix}.wav "$src"/truth.json "$dst"/
./record_matrix.sh "$dst"
uv run python prep.py "$dst"
