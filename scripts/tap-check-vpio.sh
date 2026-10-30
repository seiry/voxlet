#!/bin/zsh
# Taps QuickTime Player by bundle id while a voice-processing unit runs, as during a meeting on speakers.
# tap-check-vpio.sh <audio file> [aecprobe binary]
set -euo pipefail
root=${0:A:h:h}
file=${1:?audio file}
probe=${2:-$root/probe/meeting-aec/build/aecprobe}
sox -q -n -r 48000 -c 1 -b 32 -e floating-point /tmp/voxlet-silence20.wav trim 0 20
"$probe" --vpio 1 --far /tmp/voxlet-silence20.wav --tail 0 --out /tmp/voxlet-vpio-scratch.wav 2>/dev/null &
vpio=$!
sleep 1.5
"$root/scripts/tap-check-quicktime.sh" "$file"
wait $vpio
