#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bundle="$PWD/build/LedBar.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
icon_work=$(mktemp -d)
trap 'rm -rf "$icon_work"' EXIT
iconset="$icon_work/LedBar.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/LedBar.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Assets/LedBar.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$bundle/Contents/Resources/LedBar.icns"
cp Info.plist "$bundle/Contents/Info.plist"
architecture="$(uname -m)"
swiftc -O -target "$architecture-apple-macos14.0" Sources/*.swift -o "$bundle/Contents/MacOS/LedBar"
codesign --force --sign - "$bundle"
printf '%s\n' "$bundle"
