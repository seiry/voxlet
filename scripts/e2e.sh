#!/bin/zsh
# End-to-end check against the real Gemini Live API, through the packaged app binary.
# Needs VOXLET_API_KEY (and VOXLET_PROJECT for Agent Platform). Writes dist/e2e/{result.json,previews/}.
set -euo pipefail

root=${0:A:h:h}
cd "$root"
: "${VOXLET_API_KEY:?set VOXLET_API_KEY}"

./scripts/build.sh
out="$root/dist/e2e"
/bin/rm -rf "$out"
mkdir -p "$out"

# Mixed Chinese and English with a 1.8 s pause, resampled to 44.1 kHz stereo so the converter has real work:
# the pause splits it into two Live turns, which is where finish timing and usage summing go wrong.
say -v Tingting -o "$out/clip.aiff" \
  "板爷，明天下午三点我们开会讨论 Voxlet 的发布计划。[[slnc 1800]] After that, please send the pricing summary to the team before Friday."
afconvert -f WAVE -c 2 -d LEI16@44100 "$out/clip.aiff" "$out/clip.wav"

app_bin="$root/dist/Voxlet.app/Contents/MacOS/Voxlet"
"$app_bin" --selftest "$out/clip.wav" --out "$out/result.json" >/dev/null || true
"$app_bin" --render-previews "$out/previews" -interfaceLanguage zh-Hans >/dev/null

python3 -I - "$out/result.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
text = r.get("transcript", "")
checks = {
    "server returned a transcript": bool(text),
    "first turn present": "明天下午三点" in text,
    "second turn present (after the pause)": "pricing summary" in text,
    "usage reported by server": r.get("usage", {}).get("reportedByServer") is True,
    "usage covers both turns": len(r.get("rawUsageMessages", [])) >= 2,
    "audio tokens match 25/s within 5%": abs(r.get("usage", {}).get("audioInputTokens", 0) - 25 * r.get("audioSeconds", 0)) <= 0.05 * 25 * r.get("audioSeconds", 1),
    "finished within 3 s of audioStreamEnd": r.get("finishLatencyMs", 99999) <= 3000,
}
for name, ok in checks.items():
    print(("PASS " if ok else "FAIL ") + name)
print("transcript:", text)
print("cost: $%.5f  finish: %s in %s ms" % (r.get("estimatedCostUSD", 0), r.get("finishReason"), r.get("finishLatencyMs")))
sys.exit(0 if all(checks.values()) else 1)
PY
