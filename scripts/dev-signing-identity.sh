#!/usr/bin/env bash
# One stable signing identity for development builds ("NeuralLoop Development", self-signed, in your login keychain).
# macOS remembers permissions (Documents access, Keychain, notifications) per signing identity; ad-hoc builds get a new
# identity every time, so every rebuild asked again. Signing each build with this one identity asks once. Idempotent.
set -euo pipefail
NAME="NeuralLoop Development"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "Signing identity \"$NAME\" is already in your keychain."
  exit 0
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/identity.p12" -passout pass:neuralloop 2>/dev/null \
  || openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" -out "$WORK/identity.p12" -passout pass:neuralloop
security import "$WORK/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P neuralloop -T /usr/bin/codesign >/dev/null
echo "Created signing identity \"$NAME\" (valid 10 years, only on this Mac)."
