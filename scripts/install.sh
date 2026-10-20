#!/bin/zsh
# Builds Voxlet and installs it to /Applications, replacing a running copy.
set -euo pipefail

root=${0:A:h:h}
"$root/scripts/build.sh"

target=/Applications/Voxlet.app
staging=/Applications/.Voxlet.app.installing
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Quit by process name: asking LaunchServices by bundle id can resolve to a copy that is mid-rebuild,
# which is what produces "Voxlet.app can't be opened anymore".
if pgrep -x Voxlet >/dev/null; then
  pkill -x Voxlet || true
  for _ in {1..25}; do pgrep -x Voxlet >/dev/null || break; sleep 0.2; done
fi

# Copy next to the target first so the swap leaves only a moment without an app at that path.
/bin/rm -rf "$staging"
ditto "$root/dist/Voxlet.app" "$staging"
/bin/rm -rf "$target"
mv "$staging" "$target"
codesign --verify --verbose=1 "$target"

# Keep LaunchServices pointed at the installed copy only.
"$lsregister" -u "$root/dist/Voxlet.app" >/dev/null 2>&1 || true
"$lsregister" -f "$target"
echo "Installed $target"
