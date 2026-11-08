#!/bin/bash
# Rebuilds Resources/AppIcon.icns from Resources/AppIcon.svg.
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
set="$work/AppIcon.iconset"
mkdir -p "$set"
swiftc -O scripts/render-icon.swift -o "$work/render"
for s in 16 32 128 256 512; do
    "$work/render" Resources/AppIcon.svg "$set/icon_${s}x${s}.png" "$s"
    "$work/render" Resources/AppIcon.svg "$set/icon_${s}x${s}@2x.png" "$((s * 2))"
done
iconutil -c icns "$set" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
