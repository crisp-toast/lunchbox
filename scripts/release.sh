#!/bin/bash
# Builds the Tessel download buyers get: Apple silicon only, signed with Developer ID and the
# hardened runtime, notarized and stapled (the app and the DMG), copied to site/download/.
#   scripts/release.sh 1.0            the real thing (needs the Developer ID certificate and
#                                     a notarytool profile, see docs/store.md)
#   scripts/release.sh 1.0 --dry-run  signs with the development certificate, skips Apple
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: release.sh <version> [--dry-run]}"
DRY="${2:-}"
PROFILE="${NOTARY_PROFILE:-tessel-notary}"
OUT="build/release"
APP="$OUT/Tessel.app"
DMG="$OUT/Tessel-$VERSION.dmg"

if [[ "$DRY" == "--dry-run" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
else
  IDENTITY=$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')
  [[ -n "$IDENTITY" ]] || { echo "No Developer ID Application certificate in the keychain (see docs/store.md)."; exit 1; }
fi

swift build -c release --arch arm64 --product Tessel
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Tessel"
rm -rf "$OUT"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tessel"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp Resources/com.tyleryouens.tessel.agent.plist "$APP/Contents/Library/LaunchAgents/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD)" "$APP/Contents/Info.plist"

sign() { codesign --force --options runtime --timestamp --entitlements Resources/Tessel.entitlements --sign "$IDENTITY" "$1"; }
sign "$APP"
codesign --verify --strict --deep "$APP"
lipo -archs "$APP/Contents/MacOS/Tessel"

notarize() { # <file>
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$1"
}
if [[ "$DRY" != "--dry-run" ]]; then
  ditto -c -k --keepParent "$APP" "$OUT/Tessel.zip"
  xcrun notarytool submit "$OUT/Tessel.zip" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$OUT/Tessel.zip"
fi

STAGE="$OUT/dmg"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Tessel.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Tessel" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
if [[ "$DRY" != "--dry-run" ]]; then
  notarize "$DMG"
  spctl --assess --type open --context context:primary-signature -vv "$DMG"
  spctl --assess --type execute -vv "$APP"
fi

mkdir -p site/download
cp "$DMG" site/download/Tessel.dmg
echo "Built $DMG ($(du -h "$DMG" | cut -f1)) and copied it to site/download/Tessel.dmg${DRY:+ (dry run: not notarized, do not publish)}"
