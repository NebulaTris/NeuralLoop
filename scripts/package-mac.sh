#!/usr/bin/env bash
# Package NeuralLoop for other Macs: a Release build with the self-contained runtime inside
# (NeuralLoop.app/Contents/Resources/runtime), signed ad hoc, in a drag-to-Applications DMG.
# People open it once with System Settings → Privacy & Security → "Open Anyway" (docs/specs/07-every-device.md).
#
# Usage: scripts/package-mac.sh            (writes dist/NeuralLoop-<version>.dmg)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$ROOT/build/runtime"
DERIVED="$ROOT/apple/build/release"
DIST="$ROOT/dist"

if [[ ! -x "$RUNTIME/bin/neuralloop" ]]; then
  echo "• Building the runtime first"
  "$ROOT/scripts/build-runtime.sh" "$RUNTIME"
fi

echo "• Release build"
(cd "$ROOT/apple" && xcodegen generate --quiet && xcodebuild -project NeuralLoop.xcodeproj -scheme NeuralLoop \
  -configuration Release -derivedDataPath "$DERIVED" CODE_SIGN_IDENTITY="-" build -quiet)
APP="$DERIVED/Build/Products/Release/NeuralLoop.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"

echo "• Runtime into the app"
rm -rf "$APP/Contents/Resources/runtime"
rsync -a --exclude __pycache__ --exclude '*.pyc' "$RUNTIME/" "$APP/Contents/Resources/runtime/"

echo "• Signing (ad hoc)"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "• Smoke test from inside the app"
SMOKE="$(mktemp -d)"
PYTHONPYCACHEPREFIX="$SMOKE/pycache" "$APP/Contents/Resources/runtime/bin/neuralloop" --dry-run --no-open --out "$SMOKE/book" >/dev/null
test -f "$SMOKE/book/book-data.js"
rm -rf "$SMOKE"
codesign --verify --strict "$APP"  # running it left the bundle untouched

echo "• Disk image"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$DIST"
DMG="$DIST/NeuralLoop-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "NeuralLoop" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" -quiet
rm -rf "$STAGE"

echo "Packaged: $DMG ($(du -h "$DMG" | cut -f1))"
