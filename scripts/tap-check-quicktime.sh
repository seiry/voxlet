#!/bin/zsh
# Plays a file in QuickTime Player and taps it by bundle id, to prove the bundle-id tap path end to end.
set -euo pipefail
root=${0:A:h:h}
file=${1:?audio file}
osascript -e "tell application \"QuickTime Player\"" \
  -e "set d to open POSIX file \"$file\"" \
  -e "play d" -e "end tell" >/dev/null
sleep 1.5
"$root/scripts/tap-check.sh" bundle com.apple.QuickTimePlayerX 6 || true
osascript -e 'tell application "QuickTime Player" to close every document saving no' >/dev/null
