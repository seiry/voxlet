#!/bin/zsh
# Builds Voxlet and installs it to /Applications, replacing a running copy.
set -euo pipefail

root=${0:A:h:h}
"$root/scripts/build.sh"

target=/Applications/Voxlet.app
if pgrep -x Voxlet >/dev/null; then
  osascript -e 'tell application id "dev.seiry.voxlet" to quit' >/dev/null 2>&1 || pkill -x Voxlet || true
  for _ in {1..25}; do pgrep -x Voxlet >/dev/null || break; sleep 0.2; done
fi
/bin/rm -rf "$target"
ditto "$root/dist/Voxlet.app" "$target"
codesign --verify --verbose=1 "$target"
echo "Installed $target"
