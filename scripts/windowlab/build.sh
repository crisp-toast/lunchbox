#!/bin/bash
# Builds build/WindowLab.app, the test app that opens every kind of window Lunchbox handles.
set -euo pipefail
cd "$(dirname "$0")/../.."
APP=build/WindowLab.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
swiftc -O -target arm64-apple-macos14.0 -o "$APP/Contents/MacOS/WindowLab" scripts/windowlab/WindowLab.swift
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.tyleryouens.windowlab</string>
<key>CFBundleName</key><string>WindowLab</string>
<key>CFBundleExecutable</key><string>WindowLab</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" 2>/dev/null
echo "Built $APP"
