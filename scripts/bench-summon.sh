#!/bin/bash
# Waits until nobody is using the Mac and only the spoof display is on, then times Summon
# against Spotlight (scripts/bench-summon.swift) in empty Workspace 3 and puts things back.
#   scripts/bench-summon.sh <results.json> [max hours to wait]
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="$1"; HOURS="${2:-12}"
cmd() { osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('com.sentientdonut.lunchbox.command', '$1', \$(), true)" >/dev/null; }
idle() { echo $(( $(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print $NF; exit}') / 1000000000 )); }
only_spoof() { bash ~/.claude/skills/mac-mini/scripts/spoof.sh info 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if len(d['displays'])==1 and d['displays'][0]['spoof'] else 1)"; }
swiftc -O -o build/bench-summon scripts/bench-summon.swift || exit 1
deadline=$(( $(date +%s) + HOURS * 3600 ))
until only_spoof && [ "$(idle)" -ge 600 ]; do
  [ "$(date +%s)" -gt "$deadline" ] && { echo "gave up waiting: the Mac was never idle with the LG off"; exit 3; }
  sleep 120
done
echo "starting at $(date)"
cmd dump; sleep 0.5
ws=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/Library/Application Support/LunchboxWM/state.json')))['currentSpace'])")
cmd space-3; sleep 1
open -a Terminal; sleep 3   # one base window, in Workspace 3
build/bench-summon "${RUNS:-8}" > "$OUT"; status=$?
# Close every Terminal window (it had none before) and go back.
pid=$(pgrep -x Terminal)
[ -n "$pid" ] && swift - "$pid" <<'SW' 2>/dev/null
import ApplicationServices
let pid = pid_t(CommandLine.arguments[1])!
var v: CFTypeRef?
AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &v)
for w in (v as? [AXUIElement]) ?? [] {
    var b: CFTypeRef?
    AXUIElementCopyAttributeValue(w, kAXCloseButtonAttribute as CFString, &b)
    if let b { AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString) }
}
SW
sleep 1; cmd "space-$ws"
echo "finished at $(date) (exit $status)"; cat "$OUT"
exit $status
