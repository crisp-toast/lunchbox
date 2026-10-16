#!/bin/bash
# Builds Tessel.app into build/. With --install, replaces /Applications/Tessel.app and relaunches it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release -j "${JOBS:-4}" --product Tessel
BIN="$(swift build -c release --show-bin-path)/Tessel"

APP="build/Tessel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tessel"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp Resources/com.tyleryouens.tessel.agent.plist "$APP/Contents/Library/LaunchAgents/"

# Sign with a stable Apple Development identity so macOS keeps the Accessibility
# permission across rebuilds. Ad-hoc signing would lose it on every build.
IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ && /ZV7V23WVKL/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
    # SIGTERM makes Tessel bring windows parked in other spaces back before it quits.
    if pkill -TERM -x Tessel; then
        for _ in {1..50}; do pgrep -x Tessel >/dev/null || break; sleep 0.1; done
    fi
    rm -rf /Applications/Tessel.app
    ditto "$APP" /Applications/Tessel.app
    open /Applications/Tessel.app
    echo "Installed and launched /Applications/Tessel.app"
fi
