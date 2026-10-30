#!/bin/zsh
# The meeting on real devices: QuickTime Player plays the other side out of the Mac speakers (the "browser"),
# a second speaker (HDMI_DEVICE) plays the local talker, and the packaged app records with the real microphone
# and tap. Needs VOXLET_API_KEY, VOXLET_PROJECT, VOXLET_GATEWAY_KEY, a quality corpus from meeting-e2e.sh,
# and the display awake (an HDMI speaker goes silent when the display sleeps).
set -euo pipefail
root=${0:A:h:h}
cd "$root"
corpus=${1:-$root/dist/meeting-e2e/corpus}
hdmi=${HDMI_DEVICE:-TS3400-U2L}
out="$root/dist/meeting-device"
/bin/rm -rf "$out"
mkdir -p "$out/meetings"
dur=$(python3 -I -c "import json,sys;print(int(json.load(open(sys.argv[1]))['duration'])+4)" "$corpus/truth.json")

osascript -e "tell application \"QuickTime Player\" to open POSIX file \"$corpus/remote.wav\"" >/dev/null
open -n -W "$root/dist/Voxlet.app" \
  --env "VOXLET_API_KEY=$VOXLET_API_KEY" --env "VOXLET_GATEWAY_KEY=$VOXLET_GATEWAY_KEY" --env VOXLET_MEETING_NOTES_INTERVAL=20 \
  --args --meeting-selftest --devices --browser-bundle com.apple.QuickTimePlayerX --seconds "$dur" \
  --report "$out/report.json" -meetingFolder "$out/meetings" -vertexProject "$VOXLET_PROJECT" &
app=$!
sleep 3
osascript -e 'tell application "QuickTime Player" to play document 1' >/dev/null
sox -q "$corpus/near.wav" -t coreaudio "$hdmi" &
wait $app
osascript -e 'tell application "QuickTime Player" to close every document saving no' >/dev/null
python3 -I "$root/scripts/meeting-e2e-check.py" "$out/report.json" "$corpus/truth.json" | tee "$out/check.txt"
