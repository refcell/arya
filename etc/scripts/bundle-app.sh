#!/usr/bin/env bash
# Build AryaApp in release mode and assemble an ad-hoc signed .build/Arya.app.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

swift build -c release --product AryaApp
bin=$(swift build -c release --show-bin-path)

app=.build/Arya.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/AryaApp" "$app/Contents/MacOS/AryaApp"
cp etc/app/Info.plist "$app/Contents/Info.plist"
# Copy SwiftPM resource bundles, if any target declares resources.
find "$bin" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$app/Contents/Resources/" \;

# The placeholder icon is drawn at build time so no binary asset is tracked. It is cached in
# .build and redrawn when the drawing script changes.
icon=.build/AppIcon.icns
if [ ! -f "$icon" ] || [ etc/app/make-icon.swift -nt "$icon" ]; then
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  swift etc/app/make-icon.swift "$work/icon.png"
  set=$work/AppIcon.iconset
  mkdir -p "$set"
  for px in 16 32 128 256 512; do
    sips -z $px $px "$work/icon.png" --out "$set/icon_${px}x${px}.png" >/dev/null
    sips -z $((px * 2)) $((px * 2)) "$work/icon.png" --out "$set/icon_${px}x${px}@2x.png" \
      >/dev/null
  done
  iconutil -c icns "$set" -o "$icon"
fi
cp "$icon" "$app/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$app"
echo "bundle-app: built $app"
