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

codesign --force --sign - "$app"
echo "bundle-app: built $app"
