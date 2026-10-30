#!/bin/zsh
# Interleaved repeats of the ducking check on the iPhone mic, since that mic has its own gain control.
set -u
work=${1:?work dir}
phone=${PHONE_MIC:-“boardPhone16e”的麦克风}
startmeter() { sox -q -t coreaudio "$phone" -c 1 -r 48000 "$work/$1.wav" trim 0 6 & meterpid=$!; sleep 1; }
with_probe() {
  local name=$1; shift
  caffeinate -i ./build/aecprobe --vpio 1 --far "$work/q_sil.wav" --out "$work/${name}_probe.wav" --tail 0 "$@" 2>/dev/null &
  local probe=$!
  sleep 1.2
  startmeter "$name"; afplay "$work/q_other.wav"; wait $meterpid; wait $probe
}
for r in 1 2 3; do
  startmeter "R${r}_alone"; afplay "$work/q_other.wav"; wait $meterpid
  with_probe "R${r}_vpio"
  with_probe "R${r}_vpioafter" --duck-after-init 1
  startmeter "R${r}_hijack"; ./build/aecprobe --vpio 1 --far "$work/q_other.wav" --out "$work/R${r}_hj.wav" --tail 0 2>/dev/null; wait $meterpid
  startmeter "R${r}_engine"; ./build/aecprobe --vpio 0 --far "$work/q_other.wav" --out "$work/R${r}_en.wav" --tail 0 2>/dev/null; wait $meterpid
done
uv run python loud.py "$work"/R{1,2,3}_{alone,vpio,vpioafter,hijack,engine}.wav
