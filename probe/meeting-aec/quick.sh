#!/bin/zsh
# Short matrix: which voices survive in the mic with and without voice processing.
#   far   = hijacked far end, replayed by the probe's engine (the echo reference when vpio=1)
#   other = far end played straight by another app (afplay), never handed to the canceller
#   near  = the local talker, on the HDMI speaker, starting 3.5 s in
set -u
work=${1:?work dir}
hdmi=${HDMI_DEVICE:-TS3400-U2L}
mk() { say -v "$1" -o "$work/q_$2.aiff" "$3" && ffmpeg -loglevel error -y -i "$work/q_$2.aiff" -ar 48000 -ac 1 -c:a pcm_f32le "$work/q_$2.wav"; }
mk 'Shelley (中文（中国大陆）)' far '我是被劫持之后重新播放的对方，第一句话。'
mk 'Reed (中文（中国大陆）)' other '我是对方，直接从浏览器里播放出来。'
mk 'Tingting' nearclip '我是本地的真人，正在对着电脑说话。'
sox -q -n -r 48000 -c 1 -b 32 -e floating-point "$work/q_pad.wav" trim 0 3.5
sox -q "$work/q_pad.wav" "$work/q_nearclip.wav" "$work/q_near.wav"
sox -q -n -r 48000 -c 1 -b 32 -e floating-point "$work/q_sil.wav" trim 0 7.5
run() {
  local name=$1; shift
  caffeinate -i ./build/aecprobe "$@" --out "$work/$name.wav" --tail 1.5
}
run T1 --vpio 0 --far "$work/q_far.wav" --near "$work/q_near.wav" --near-device "$hdmi"
run T2 --vpio 1 --far "$work/q_far.wav" --near "$work/q_near.wav" --near-device "$hdmi"
run T3 --vpio 1 --far "$work/q_sil.wav" --other "$work/q_other.wav" --near "$work/q_near.wav" --near-device "$hdmi"
run T4 --vpio 0 --far "$work/q_sil.wav" --other "$work/q_other.wav" --near "$work/q_near.wav" --near-device "$hdmi"
uv run python stats.py "$work"/T{1,2,3,4}.wav
uv run python quick_transcribe.py "$work"/T{1,2,3,4}.wav
