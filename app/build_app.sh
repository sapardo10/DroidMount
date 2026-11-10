#!/usr/bin/env bash
# Compile the DroidMount menu-bar app and assemble DroidMount.app, embedding the
# adbfs daemon (built by ../build.sh) as a bundle resource.
set -euo pipefail

APPDIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$APPDIR/.." && pwd)"
DAEMON="$ROOT/bin/adbfs"
BUILD="$ROOT/build"
APP="$BUILD/DroidMount.app"

[ -x "$DAEMON" ] || { echo "Daemon missing. Run ./build.sh first." >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$APPDIR/Info.plist" "$APP/Contents/Info.plist"
# Stamp the version from the VERSION file so the bundle matches the release tag.
VERSION="$(cat "$ROOT/VERSION")"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
cp "$DAEMON" "$APP/Contents/Resources/adbfs"

echo "Compiling Swift sources…"
swiftc -O \
  -framework AppKit \
  -o "$APP/Contents/MacOS/DroidMount" \
  "$APPDIR/Sources/"*.swift

# Ad-hoc sign so the bundle launches without "damaged" warnings on first run.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Built: $APP"
echo "Run with:  open \"$APP\"   (or for logs:  \"$APP/Contents/MacOS/DroidMount\")"
