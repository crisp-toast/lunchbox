#!/bin/bash
# Builds Lunchbox.app into build/. With --install, replaces /Applications/Lunchbox.app and relaunches it.
# This is a development build: LUNCHBOX_DEV keeps every script command (press:, dump, license:…)
# for the test VMs and WindowLab. scripts/release.sh builds what customers get, without them.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release -j "${JOBS:-4}" --product Lunchbox -Xswiftc -DLUNCHBOX_DEV
BIN="$(swift build -c release --show-bin-path)/Lunchbox"

APP="build/Lunchbox.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lunchbox"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp Resources/com.sentientdonut.lunchbox.agent.plist "$APP/Contents/Library/LaunchAgents/"

# Sparkle (auto-updates) ships inside the app.
[[ -d Vendor/Sparkle.xcframework ]] || bash scripts/fetch-sparkle.sh
SPARKLE="$(find Vendor/Sparkle.xcframework -maxdepth 2 -type d -name Sparkle.framework | head -1)"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"

# Sign with a stable Apple Development identity so macOS keeps the Accessibility
# permission across rebuilds. Ad-hoc signing would lose it on every build.
IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ && /ZV7V23WVKL/ {print $2; exit}')}"
codesign --force --deep --sign "${IDENTITY:--}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
    # SIGTERM makes Lunchbox bring windows parked in other spaces back before it quits.
    if pkill -TERM -x Lunchbox; then
        for _ in {1..50}; do pgrep -x Lunchbox >/dev/null || break; sleep 0.1; done
    fi
    rm -rf /Applications/Lunchbox.app
    ditto "$APP" /Applications/Lunchbox.app
    open /Applications/Lunchbox.app
    echo "Installed and launched /Applications/Lunchbox.app"
    # Lunchbox was called Tessel. Lunchbox stops Tessel whenever it starts (Sources/Lunchbox/OldAppID.swift),
    # but macOS keeps starting Tessel at login until Tessel.app is deleted: in the Trash it still runs.
    if [[ -d /Applications/Tessel.app ]]; then
        echo "The old /Applications/Tessel.app is still there. Delete it (and empty it from the Trash): until then macOS starts it at every login."
    fi
fi
