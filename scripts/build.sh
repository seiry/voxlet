#!/bin/zsh
# Builds dist/Voxlet.app from the SwiftPM target and signs it ad hoc (or with $SIGN_IDENTITY).
set -euo pipefail

root=${0:A:h:h}
cd "$root"
config=${CONFIG:-release}

swift build -c "$config"
bin_dir=$(swift build -c "$config" --show-bin-path)

app="$root/dist/Voxlet.app"
/bin/rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Voxlet" "$app/Contents/MacOS/Voxlet"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp -R Resources/*.lproj "$app/Contents/Resources/"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# No hardened runtime: it would need an audio-input entitlement, and ad hoc builds gain nothing from it.
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier dev.seiry.voxlet "$app"
codesign --verify --verbose=1 "$app"
echo "Built $app"
