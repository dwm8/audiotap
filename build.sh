#!/bin/sh
# Builds AudioTap.app (icon from icon-1024.png; regenerate that with `swift icon.swift icon-1024.png`) into /Applications and launches it.
# A rebuild changes the ad-hoc signature, so macOS may ask for Audio Recording permission again.
set -e
cd "$(dirname "$0")"
APP=/Applications/AudioTap.app
rm -rf build && mkdir -p build/AudioTap.app/Contents/MacOS
swiftc -O -swift-version 5 -o build/AudioTap.app/Contents/MacOS/AudioTap main.swift
cp Info.plist build/AudioTap.app/Contents/Info.plist
mkdir -p build/AudioTap.app/Contents/Resources build/AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s * 2)) $((s * 2)) icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o build/AudioTap.app/Contents/Resources/AppIcon.icns
codesign --force --sign - --identifier com.dmerr.audiotap build/AudioTap.app
pkill -x AudioTap 2>/dev/null && sleep 1 || true
rm -rf "$APP" && cp -R build/AudioTap.app "$APP"
open "$APP"
echo "installed $APP"
