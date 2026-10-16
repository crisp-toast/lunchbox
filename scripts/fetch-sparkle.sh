#!/bin/bash
# Fetches Sparkle (Tessel's auto-updater) into Vendor/: the framework, wrapped as an
# xcframework for SwiftPM, and Sparkle's tools (generate_keys, sign_update, generate_appcast).
# SwiftPM's own download of Sparkle's package stalls here, so this uses the official
# release archive, checked against a pinned SHA-256. Run once per checkout.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=2.9.6
SHA256=52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192
[[ -d Vendor/Sparkle.xcframework && -x Vendor/sparkle-bin/sign_update ]] && { echo "Sparkle $VERSION already in Vendor/"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ARCHIVE="/Volumes/Master Storage/Library/tools/sparkle-$VERSION/Sparkle-$VERSION.tar.xz"
if [[ -f "$ARCHIVE" ]]; then cp "$ARCHIVE" "$WORK/sparkle.tar.xz"
else curl -fsSL -o "$WORK/sparkle.tar.xz" "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"; fi
echo "$SHA256  $WORK/sparkle.tar.xz" | shasum -a 256 -c - >/dev/null || { echo "Sparkle archive checksum mismatch"; exit 1; }
mkdir -p "$WORK/x" Vendor
tar -xJf "$WORK/sparkle.tar.xz" -C "$WORK/x"
rm -rf Vendor/Sparkle.xcframework Vendor/sparkle-bin
xcodebuild -create-xcframework -framework "$WORK/x/Sparkle.framework" -output Vendor/Sparkle.xcframework >/dev/null
ditto "$WORK/x/bin" Vendor/sparkle-bin
echo "Sparkle $VERSION in Vendor/"
