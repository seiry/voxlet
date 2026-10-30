#!/bin/zsh
# B with a second voice-processing unit already running in another process, as Firefox has during a Meet call.
# two_vpio.sh <corpus dir> <new dir>
set -eu
src=${1:?corpus dir}
dst=${2:?new dir}
hdmi=${HDMI_DEVICE:-TS3400-U2L}
mkdir -p "$dst"
cp "$src"/{remote,near,mix}.wav "$src"/truth.json "$dst"/
dur=$(uv run python -c "import json;print(json.load(open('$dst/truth.json'))['duration'])")
sox -q -n -r 48000 -c 1 -b 32 -e floating-point "$dst/silence.wav" trim 0 "$dur"
sox -q -n -r 48000 -c 1 -b 32 -e floating-point "$dst/silence_long.wav" trim 0 "$(( ${dur%.*} + 10 ))"
# The stand-in for Firefox: a voice-processing unit that plays nothing and records nothing useful.
./build/aecprobe --vpio 1 --far "$dst/silence_long.wav" --tail 0 --out "$dst/fake_firefox.wav" 2>/dev/null &
fake=$!
sleep 2
./build/aecprobe --vpio 1 --far "$dst/silence.wav" --near "$dst/near.wav" --near-device "$hdmi" --tail 2 \
  --out "$dst/B_two.wav" &
probe=$!
sleep 1.0
afplay "$dst/remote.wav" &
wait $probe
wait $fake
uv run python stats.py "$dst/B_two.wav"
