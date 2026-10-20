#!/bin/zsh
# Creates a self-signed "Voxlet Local Signing" code-signing identity in a dedicated keychain, once.
# A stable identity keeps the app's designated requirement fixed, so macOS privacy grants survive rebuilds.
# For personal use only; nothing is distributed with it.
set -euo pipefail

name="Voxlet Local Signing"
dir="$HOME/.config/voxlet-signing"
keychain="$HOME/Library/Keychains/voxlet-signing.keychain-db"

if security find-identity -p codesigning "$keychain" 2>/dev/null | grep -q "$name"; then
  echo "Identity \"$name\" already exists in $keychain"
  exit 0
fi

mkdir -p "$dir"
chmod 700 "$dir"
password_file="$dir/keychain-password"
[[ -f $password_file ]] || { openssl rand -hex 24 >| "$password_file"; chmod 600 "$password_file"; }
password=$(<"$password_file")

work=$(mktemp -d)
trap '/bin/rm -rf "$work"' EXIT
cat >| "$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" \
  -keyout "$work/key.pem" -out "$work/cert.pem"
# macOS cannot read the PBKDF2/AES PKCS#12 that OpenSSL 3+ writes by default.
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
  -passout "pass:$password" -out "$work/identity.p12"

[[ -f $keychain ]] || security create-keychain -p "$password" "$keychain"
security set-keychain-settings "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$work/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null

# Append to the user search list without dropping what is already there.
current=("${(@f)$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')}")
if [[ ${current[(Ie)$keychain]} -eq 0 ]]; then
  security list-keychains -d user -s "${current[@]}" "$keychain"
fi

cp "$work/cert.pem" "$dir/voxlet-local-signing.pem"
echo "Created \"$name\" in $keychain"
