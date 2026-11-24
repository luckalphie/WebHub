#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP="$ROOT/dist/WebHub.app"
GENERATOR="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
[ -d "$APP" ] && [ -x "$GENERATOR" ] || { echo "Build WebHub before preparing an update." >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
case "$VERSION" in *[!0-9.]*|'') echo "Invalid version." >&2; exit 1;; esac
OUTPUT="$ROOT/dist/update-$VERSION"
[ ! -e "$OUTPUT" ] || { echo "Update directory already exists: $OUTPUT" >&2; exit 1; }
mkdir -p "$OUTPUT"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT/WebHub-$VERSION.zip"
"$GENERATOR" --account cn.webhub.updates --download-url-prefix "https://github.com/luckalphie/WebHub/releases/download/v$VERSION/" "$OUTPUT"
echo "Upload WebHub-$VERSION.zip and appcast.xml from $OUTPUT to release v$VERSION."
