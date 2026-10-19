#!/bin/bash
# Builds LunchboxWM.app into build/. With --install, replaces /Applications/LunchboxWM.app and relaunches it.
# This is a development build: LUNCHBOX_DEV keeps every script command (press:, dump, license:…)
# for the test VMs and WindowLab. scripts/release.sh builds what customers get, without them.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release -j "${JOBS:-4}" --product LunchboxWM -Xswiftc -DLUNCHBOX_DEV
BIN="$(swift build -c release --show-bin-path)/LunchboxWM"

APP="build/LunchboxWM.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LunchboxWM"
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
    # SIGTERM makes LunchboxWM bring windows parked in other spaces back before it quits.
    if pkill -TERM -x LunchboxWM; then
        for _ in {1..50}; do pgrep -x LunchboxWM >/dev/null || break; sleep 0.1; done
    fi
    # The same app was Lunchbox.app for a day: replace it too, or two copies would share one ID.
    if [[ -d /Applications/Lunchbox.app ]]; then
        if pkill -TERM -x Lunchbox; then
            for _ in {1..50}; do pgrep -x Lunchbox >/dev/null || break; sleep 0.1; done
        fi
        rm -rf /Applications/Lunchbox.app
    fi
    rm -rf /Applications/LunchboxWM.app
    ditto "$APP" /Applications/LunchboxWM.app
    open /Applications/LunchboxWM.app
    echo "Installed and launched /Applications/LunchboxWM.app"
    # LunchboxWM was called Tessel. LunchboxWM stops Tessel whenever it starts (Sources/LunchboxWM/OldAppID.swift),
    # but macOS keeps starting Tessel at login until Tessel.app is deleted: in the Trash it still runs.
    if [[ -d /Applications/Tessel.app ]]; then
        echo "The old /Applications/Tessel.app is still there. Delete it (and empty it from the Trash): until then macOS starts it at every login."
    fi
fi
