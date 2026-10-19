#!/bin/bash
# Builds Picasso.app with swiftc (no Xcode needed).
#   build.sh [release|debug]  -> build/Picasso.app (universal: arm64 + x86_64)
#   build.sh selftest         -> build/test/Picasso.app (native arch, debug, -D SELFTEST)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-release}"
SDK="$(xcrun --show-sdk-path)"
FLAGS=(-swift-version 5 -wmo -sdk "$SDK")

case "$MODE" in
  release)  OUT="$ROOT/build";      ARCHS=(arm64 x86_64); FLAGS+=(-O) ;;
  debug)    OUT="$ROOT/build";      ARCHS=(arm64 x86_64); FLAGS+=(-Onone -g) ;;
  selftest) OUT="$ROOT/build/test"; ARCHS=("$(uname -m)"); FLAGS+=(-Onone -g -D SELFTEST) ;;
  *) echo "usage: $0 [release|debug|selftest]" >&2; exit 2 ;;
esac

APP="$OUT/Picasso.app"
OBJ="$OUT/obj-$MODE"
rm -rf "$APP" "$OBJ"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OBJ"

BINS=()
for arch in "${ARCHS[@]}"; do
  swiftc "${FLAGS[@]}" -target "$arch-apple-macos14.0" -module-name Picasso \
    -o "$OBJ/Picasso-$arch" "$ROOT"/Picasso/*.swift
  BINS+=("$OBJ/Picasso-$arch")
done
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/Picasso"

cp "$ROOT/Picasso/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Picasso/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
if [ "$MODE" = selftest ]; then
  # Keep the test build out of the owner's prefs and Finder's "Open With" list.
  plutil -replace CFBundleIdentifier -string com.penguinpecker.Picasso.selftest "$APP/Contents/Info.plist"
  plutil -remove CFBundleDocumentTypes "$APP/Contents/Info.plist"
fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --sign - "$APP" 2>/dev/null

echo "$APP"
