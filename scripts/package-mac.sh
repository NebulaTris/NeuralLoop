#!/usr/bin/env bash
# Package NeuralLoop for other Macs: a Release build with the self-contained runtime inside
# (NeuralLoop.app/Contents/Resources/runtime), signed ad hoc, in a drag-to-Applications DMG.
# People open it once with System Settings → Privacy & Security → "Open Anyway" (docs/specs/07-every-device.md).
# The hardened runtime is off and nothing is notarized; docs/DEVELOPMENT.md → "Signing" says what changing that needs.
#
# The runtime is rebuilt whenever its stamp doesn't match the current sources (scripts/build-runtime.sh --stamp).
# After the DMG is made, it is checked like a download: mounted, copied out, quarantined, marked approved the
# way "Open Anyway" does, and the bundled runtime's dry run must pass from that copy.
#
# dmgbuild (which lays out the disk image window) is installed into a throwaway virtual environment from
# scripts/dmg-requirements.txt with --require-hashes. To change its version, edit scripts/dmg-requirements.in and run
# from the repo root:
#   uv pip compile scripts/dmg-requirements.in --generate-hashes --python-version 3.12 \
#     --python-platform aarch64-apple-darwin --only-binary :all: -o scripts/dmg-requirements.txt
#
# Usage: scripts/package-mac.sh            (writes dist/NeuralLoop-<version>.dmg)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$ROOT/build/runtime"
DERIVED="$ROOT/apple/build/release"
DIST="$ROOT/dist"

SMOKE="" CHECK="" MOUNT="" DMGENV=""
cleanup() {
  if [[ -n "$MOUNT" ]]; then hdiutil detach "$MOUNT" -quiet -force >/dev/null 2>&1 || true; fi
  rm -rf "$SMOKE" "$CHECK" "$DMGENV"
  if [[ -n "$MOUNT" ]]; then rmdir "$MOUNT" 2>/dev/null || true; fi
}
trap cleanup EXIT

WANT="$("$ROOT/scripts/build-runtime.sh" --stamp)"
HAVE="$(cat "$RUNTIME/.stamp" 2>/dev/null || true)"
if [[ ! -x "$RUNTIME/bin/neuralloop" || "$WANT" != "$HAVE" ]]; then
  echo "• Building the runtime first (missing or out of date)"
  "$ROOT/scripts/build-runtime.sh" "$RUNTIME"
fi

echo "• Release build"
(cd "$ROOT/apple" && xcodegen generate --quiet && xcodebuild -project NeuralLoop.xcodeproj -scheme NeuralLoop \
  -configuration Release -derivedDataPath "$DERIVED" CODE_SIGN_IDENTITY="-" build -quiet)
APP="$DERIVED/Build/Products/Release/NeuralLoop.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"

# Google sign-in for Drive sync needs the owner's OAuth client ID (apple/Config/Google.xcconfig, docs/DEVELOPMENT.md).
CLIENT_ID="$(/usr/libexec/PlistBuddy -c 'Print GoogleClientID' "$APP/Contents/Info.plist" 2>/dev/null || true)"
EXAMPLE_ID="$(sed -n 's/^GOOGLE_CLIENT_ID *= *//p' "$ROOT/apple/Config/Google.xcconfig.example")"
if [[ -n "$EXAMPLE_ID" && "$CLIENT_ID" == "$EXAMPLE_ID" ]]; then
  echo "GoogleClientID is still the example from Google.xcconfig.example; paste your own client ID into" >&2
  echo "apple/Config/Google.xcconfig (docs/DEVELOPMENT.md → Google Drive sync)." >&2
  exit 1
fi
if [[ -z "$CLIENT_ID" ]]; then
  echo "  Warning: no GoogleClientID (apple/Config/Google.xcconfig), so this build's Drive sync is off."
fi

# Licences travel with the app (apple/project.yml) and with its runtime (build-runtime.sh).
for f in LICENSE NOTICE.md licenses/GPL-2.0.txt; do
  test -f "$APP/Contents/Resources/$f" || { echo "The app is missing $f in its Resources." >&2; exit 1; }
done

echo "• Runtime into the app"
rm -rf "$APP/Contents/Resources/runtime"
rsync -a --exclude __pycache__ --exclude '*.pyc' "$RUNTIME/" "$APP/Contents/Resources/runtime/"

echo "• Signing (ad hoc, inside out)"
# Every Mach-O file in the runtime gets its own ad hoc signature, deepest first, then the app seals them all.
# Ollama keeps its Developer ID signature (build-runtime.sh verified its team).
"$RUNTIME/python/bin/python3" - "$APP/Contents/Resources/runtime" <<'PY' |
import os, sys
MAGIC = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
root = sys.argv[1]
found = []
for d, dirs, files in os.walk(root):
    if os.path.relpath(d, root).split(os.sep)[0] == "ollama":
        dirs[:] = []
        continue
    for f in files:
        p = os.path.join(d, f)
        if os.path.islink(p):
            continue
        with open(p, "rb") as fh:
            if fh.read(4) in MAGIC:
                found.append(p)
found.sort(key=lambda p: -p.count(os.sep))  # inside out
sys.stdout.write("\0".join(found))
PY
  xargs -0 -n 50 -P 8 codesign --force --sign - --timestamp=none 2>&1 | { grep -v -e ': replacing existing signature$' -e '^$' || true; }
codesign --force --sign - --timestamp=none "$APP" 2>&1 | { grep -v -e ': replacing existing signature$' -e '^$' || true; }
codesign --verify --strict "$APP"

echo "• Smoke test from inside the app"
SMOKE="$(mktemp -d)"
PYTHONPYCACHEPREFIX="$SMOKE/pycache" "$APP/Contents/Resources/runtime/bin/neuralloop" --dry-run --no-open --out "$SMOKE/book" >/dev/null
test -f "$SMOKE/book/book.json"
codesign --verify --strict "$APP" # running it left the bundle untouched

echo "• Disk image (Pip's drag-to-Applications window: design/dmg)"
mkdir -p "$DIST"
DMG="$DIST/NeuralLoop-$VERSION.dmg"
rm -f "$DMG"
DMGENV="$(mktemp -d)"
"$RUNTIME/python/bin/python3" -m venv "$DMGENV/venv"
"$DMGENV/venv/bin/python" -m pip install --quiet --no-cache-dir --disable-pip-version-check \
  --require-hashes --only-binary :all: -r "$ROOT/scripts/dmg-requirements.txt"
"$DMGENV/venv/bin/python" -m dmgbuild -s "$ROOT/design/dmg/settings.py" \
  -D app="$APP" -D here="$ROOT/design/dmg" "NeuralLoop" "$DMG" >/dev/null

echo "• Checking the disk image like a download"
CHECK="$(mktemp -d)"
MOUNT="$(mktemp -d)"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" -quiet
ditto "$MOUNT/NeuralLoop.app" "$CHECK/NeuralLoop.app"
hdiutil detach "$MOUNT" -quiet
rmdir "$MOUNT"
MOUNT=""
NOW="$(printf %x "$(date +%s)")"
xattr -w -r com.apple.quarantine "0081;$NOW;Safari;" "$CHECK/NeuralLoop.app" # as if downloaded with Safari
codesign --verify --strict "$CHECK/NeuralLoop.app"
echo "  Gatekeeper (an unsigned app is expected to be rejected until \"Open Anyway\"):"
spctl -a -vv "$CHECK/NeuralLoop.app" 2>&1 | sed 's/^/    /' || true
# Until the person approves it, macOS kills anything in the quarantined bundle (the app can't open either).
# "Open Anyway" marks the app user-approved (flag 0x40); the runtime inside must then run while every
# file in it still carries the download's quarantine.
xattr -w com.apple.quarantine "00c1;$NOW;Safari;" "$CHECK/NeuralLoop.app"
PYTHONPYCACHEPREFIX="$CHECK/pycache" "$CHECK/NeuralLoop.app/Contents/Resources/runtime/bin/neuralloop" \
  --dry-run --no-open --out "$CHECK/book" >/dev/null
test -f "$CHECK/book/book.json"
echo "  After \"Open Anyway\", the quarantined copy's runtime made a practice book."

echo "Packaged: $DMG ($(du -h "$DMG" | cut -f1))"
