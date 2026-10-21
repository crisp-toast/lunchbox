#!/bin/bash
# Builds the LunchboxWM download buyers get: Apple silicon only, signed with Developer ID and the
# hardened runtime, notarized and stapled (the app and the DMG), copied to site/download/.
#   scripts/release.sh 1.0            the real thing (needs the Developer ID certificate and
#                                     a notarytool profile, see docs/store.md)
#   scripts/release.sh 1.0 --dry-run  signs with the development certificate, skips Apple
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: release.sh <version> [--dry-run]}"
DRY="${2:-}"
PROFILE="${NOTARY_PROFILE:-lunchbox-notary}"
OUT="build/release"
APP="$OUT/LunchboxWM.app"
DMG="$OUT/LunchboxWM-$VERSION.dmg"

if [[ "$DRY" == "--dry-run" ]]; then
  # The development certificate build.sh uses, so a test Mac's Accessibility grant carries over.
  IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ && /ZV7V23WVKL/ {print $2; exit}')
  [[ -n "$IDENTITY" ]] || IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
else
  # The Developer ID key lives in its own keychain, unlocked here so codesign never asks (see docs/store.md).
  SIGNING_KC="$HOME/Library/Keychains/lunchbox-signing.keychain-db"
  SIGNING_PW="$HOME/.config/sentient-donut/signing-keychain-password"
  [[ -f "$SIGNING_KC" && -f "$SIGNING_PW" ]] && security unlock-keychain -p "$(cat "$SIGNING_PW")" "$SIGNING_KC"
  IDENTITY=$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')
  [[ -n "$IDENTITY" ]] || { echo "No Developer ID Application certificate in the keychain (see docs/store.md)."; exit 1; }
fi

# Never LUNCHBOX_DEV: a release takes only the script commands an agent needs on a customer's Mac
# (pause, resume, retile, balance), since any process can post one. Its own build folder, so
# nothing compiled for scripts/build.sh's development builds can end up in it.
SCRATCH=".build/dist"
swift build -c release --arch arm64 --scratch-path "$SCRATCH" --product LunchboxWM
BIN="$(swift build -c release --arch arm64 --scratch-path "$SCRATCH" --show-bin-path)/LunchboxWM"
if LC_ALL=C grep -aq "takes every script command" "$BIN"; then
  echo "$BIN is a development build (it takes every script command). Not shipping it."; exit 1
fi
rm -rf "$OUT"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LunchboxWM"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp Resources/com.sentientdonut.lunchbox.agent.plist "$APP/Contents/Library/LaunchAgents/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD)" "$APP/Contents/Info.plist"

# Sparkle (auto-updates): its helpers are signed one by one, inside out, as Sparkle documents.
[[ -d Vendor/Sparkle.xcframework ]] || bash scripts/fetch-sparkle.sh
SPARKLE="$(find Vendor/Sparkle.xcframework -maxdepth 2 -type d -name Sparkle.framework | head -1)"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
plain() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }
plain "$SP/XPCServices/Installer.xpc"
plain --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
plain "$SP/Autoupdate"
plain "$SP/Updater.app"
plain "$APP/Contents/Frameworks/Sparkle.framework"

sign() { codesign --force --options runtime --timestamp --entitlements Resources/LunchboxWM.entitlements --sign "$IDENTITY" "$1"; }
sign "$APP"
codesign --verify --strict --deep "$APP"
lipo -archs "$APP/Contents/MacOS/LunchboxWM"

notarize() { # <file>
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$1"
}
if [[ "$DRY" != "--dry-run" ]]; then
  ditto -c -k --keepParent "$APP" "$OUT/LunchboxWM.zip"
  xcrun notarytool submit "$OUT/LunchboxWM.zip" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$OUT/LunchboxWM.zip"
fi

STAGE="$OUT/dmg"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/LunchboxWM.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "LunchboxWM" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
if [[ "$DRY" != "--dry-run" ]]; then
  notarize "$DMG"
  spctl --assess --type open --context context:primary-signature -vv "$DMG"
  spctl --assess --type execute -vv "$APP"
fi

mkdir -p site/download
cp "$DMG" site/download/LunchboxWM.dmg
if [[ "$DRY" != "--dry-run" ]]; then
  # The update feed: every release lives in the releases folder; generate_appcast signs each
  # with the update key in this Mac's Keychain and writes site/appcast.xml.
  RELEASES="${RELEASES_DIR:-/Volumes/Master Storage/Projects/lunchbox/releases}"
  SPARKLE_BIN="${SPARKLE_BIN:-Vendor/sparkle-bin}"
  mkdir -p "$RELEASES"
  cp "$DMG" "$RELEASES/"
  # What's new, shown in the update prompt: RELEASE_NOTES is an HTML file (scripts/ship.sh writes it).
  [[ -n "${RELEASE_NOTES:-}" && -f "$RELEASE_NOTES" ]] && cp "$RELEASE_NOTES" "$RELEASES/LunchboxWM-$VERSION.html"
  # CRITICAL=1: copies can't skip this one.
  extra=()
  [[ -n "${CRITICAL:-}" ]] && extra=(--critical-update-version "")
  "$SPARKLE_BIN/generate_appcast" --download-url-prefix "https://lunchboxwm.com/download/" --embed-release-notes \
    ${extra[@]+"${extra[@]}"} -o site/appcast.xml "$RELEASES"
  cp "$DMG" "site/download/LunchboxWM-$VERSION.dmg"
  # generate_appcast also makes small delta updates from earlier versions, which the feed links
  # to: they're served from the same folder.
  cp "$RELEASES"/*.delta site/download/ 2>/dev/null || true
fi
echo "Built $DMG ($(du -h "$DMG" | cut -f1)) and copied it to site/download/LunchboxWM.dmg${DRY:+ (dry run: not notarized, do not publish)}"
