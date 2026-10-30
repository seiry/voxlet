#!/bin/zsh
# Records the three acoustic pipelines for the meeting corpus. The local talker is played on a speaker
# that is not the Mac's (HDMI_DEVICE), standing in for a person; remote speech comes out of the Mac speakers.
#   A_raw    : no processing, remote played by another app (afplay)  -> the "mic only" plan
#   B_vpio   : Apple voice processing, remote played by another app   -> no hijack
#   C_hijack : Apple voice processing, remote replayed by the unit    -> hijack and replay
set -u
work=${1:?work dir}
hdmi=${HDMI_DEVICE:-TS3400-U2L}
dur=$(uv run python -c "import json;print(json.load(open('$work/truth.json'))['duration'])")
sox -q -n -r 48000 -c 1 -b 32 -e floating-point "$work/silence.wav" trim 0 "$dur"
common=(--near "$work/near.wav" --near-device "$hdmi" --tail 2)
caffeinate -i ./build/aecprobe --vpio 0 --far "$work/silence.wav" --other "$work/remote.wav" "${common[@]}" --out "$work/A_raw.wav"
sleep 2
caffeinate -i ./build/aecprobe --vpio 1 --far "$work/silence.wav" --other "$work/remote.wav" "${common[@]}" --out "$work/B_vpio.wav"
sleep 2
caffeinate -i ./build/aecprobe --vpio 1 --far "$work/remote.wav" "${common[@]}" --out "$work/C_hijack.wav"
uv run python stats.py "$work"/{A_raw,B_vpio,C_hijack}.wav
