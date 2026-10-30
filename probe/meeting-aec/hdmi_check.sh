#!/bin/zsh
# G: no voice processing; play the clip on the HDMI device and record the built-in mic.
#    Audible means the HDMI device can stand in for a talker that is not the Mac speakers.
set -u
work=${1:?work dir}
rec -q -c 1 -r 48000 "$work/G_sox.wav" trim 0 5 &
recpid=$!
sleep 0.5
sox -q "$work/hello48.wav" -t coreaudio "TS3400-U2L" 2>&1 | head -3
wait $recpid
uv run python stats.py "$work/G_sox.wav"
