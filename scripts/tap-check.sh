#!/bin/zsh
# Taps a test player (by pid) or an app (by bundle id) through the packaged app, so the System Audio Recording
# grant is Voxlet's own. tap-check.sh pid <audio file> | tap-check.sh bundle <bundle id> [seconds]
set -euo pipefail
root=${0:A:h:h}
out="$root/dist/tap-check"
mkdir -p "$out"
mode=${1:?pid or bundle}
report="$out/report-$mode.json"
/bin/rm -f "$report"
if [[ $mode == pid ]]; then
  afplay "${2:?audio file}" &
  player=$!
  sleep 0.5
  open -n -W "$root/dist/Voxlet.app" --args --tap-selftest --pid "$player" --seconds 6 --out "$report"
  kill $player 2>/dev/null || true
else
  open -n -W "$root/dist/Voxlet.app" --args --tap-selftest --bundle "${2:?bundle id}" --seconds "${3:-8}" --out "$report" ${TAP_EXTRA:-}
fi
cat "$report"
