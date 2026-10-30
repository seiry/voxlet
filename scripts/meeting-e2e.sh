#!/bin/zsh
# End-to-end meeting run against the real Gemini Live, Vertex and notes gateway, through the packaged binary.
# A 67 s two-sided TTS meeting goes in as two files; rollover is forced at 25 s. Needs VOXLET_API_KEY,
# VOXLET_PROJECT and VOXLET_GATEWAY_KEY. Writes dist/meeting-e2e/{report.json,check.txt,meetings/}.
set -euo pipefail

root=${0:A:h:h}
cd "$root"
: "${VOXLET_API_KEY:?set VOXLET_API_KEY}"
: "${VOXLET_PROJECT:?set VOXLET_PROJECT}"
: "${VOXLET_GATEWAY_KEY:?set VOXLET_GATEWAY_KEY}"

./scripts/build.sh >/dev/null
out="$root/dist/meeting-e2e"
/bin/rm -rf "$out"
mkdir -p "$out/meetings"

uv run --project probe/meeting-aec python probe/meeting-aec/make_corpus.py "$out/corpus" --quality >/dev/null

VOXLET_MEETING_NOTES_INTERVAL=20 "$root/dist/Voxlet.app/Contents/MacOS/Voxlet" --meeting-selftest \
  --mic "$out/corpus/near.wav" --browser "$out/corpus/remote.wav" --report "$out/report.json" --rollover 25 \
  -meetingFolder "$out/meetings" -vertexProject "$VOXLET_PROJECT" || true

python3 -I "$root/scripts/meeting-e2e-check.py" "$out/report.json" "$out/corpus/truth.json" | tee "$out/check.txt"
