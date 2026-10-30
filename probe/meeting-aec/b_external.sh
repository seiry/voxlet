#!/bin/zsh
# B with the remote player started by the shell, not as a child of the probe: does voice processing still
# remove audio from an unrelated process (as a browser would be)? b_external.sh <corpus dir> <new dir>
set -eu
src=${1:?corpus dir}
dst=${2:?new dir}
hdmi=${HDMI_DEVICE:-TS3400-U2L}
mkdir -p "$dst"
cp "$src"/{remote,near,mix}.wav "$src"/truth.json "$dst"/
dur=$(uv run python -c "import json;print(json.load(open('$dst/truth.json'))['duration'])")
sox -q -n -r 48000 -c 1 -b 32 -e floating-point "$dst/silence.wav" trim 0 "$dur"
./build/aecprobe --vpio 1 --far "$dst/silence.wav" --near "$dst/near.wav" --near-device "$hdmi" --tail 2 \
  --out "$dst/B_external.wav" &
probe=$!
# The probe starts its players after a 1 s lead-in; start the unrelated player at the same moment.
sleep 1.0
afplay "$dst/remote.wav" &
wait $probe
uv run python stats.py "$dst/B_external.wav"
