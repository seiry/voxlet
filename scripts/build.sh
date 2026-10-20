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

# Prefer the local identity from make-signing-cert.sh: a fixed designated requirement keeps privacy grants
# across rebuilds. It is self-signed, hence untrusted, which codesign and TCC accept. Ad hoc otherwise.
keychain="$HOME/Library/Keychains/voxlet-signing.keychain-db"
sign_args=()
if [[ -z ${SIGN_IDENTITY:-} && -f $keychain ]]; then
  security unlock-keychain -p "$(<"$HOME/.config/voxlet-signing/keychain-password")" "$keychain"
  SIGN_IDENTITY=$(security find-identity -p codesigning "$keychain" | awk '/"Voxlet Local Signing"/ { print $2; exit }')
  sign_args=(--keychain "$keychain")
fi

# No hardened runtime: it would need an audio-input entitlement and buys nothing for a local build.
codesign --force --sign "${SIGN_IDENTITY:--}" "${sign_args[@]}" --identifier dev.seiry.voxlet "$app"
codesign --verify --verbose=1 "$app"
codesign -dr - "$app" 2>/dev/null | grep designated
echo "Built $app"
