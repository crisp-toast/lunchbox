#!/usr/bin/env python3
"""Smoothness benchmark, for a test VM (never a Mac someone is using). While LunchboxWM rearranges
windows, `motion` (motion.swift, copied into the guest's home) records every window's frame every
2 ms; this reports per case how many separate motions each window makes, how many stops on the way
it holds (and how many whole layouts), how long until everything settles, how far edges that should
hold still shake (wobble, in points), and any overlap on the way.

   smooth.py [-n RUNS] [--json OUT] [case ...]      run cases (no case: all of them)
   smooth.py --table RESULTS.json [AFTER.json]      medians per case, before → after

The guest needs WindowLab running, ~/windowlab (scripts/windowlab/windowlab) and ~/motion
(swiftc -O -target arm64-apple-macos14.0 -o motion scripts/windowlab/motion.swift).
Environment: VMIP (the guest's address), LAB_SPACE (an empty Workspace), OTHER_SPACE (another one).
"""
import json, os, statistics, subprocess, sys

SSH = ["ssh", "-i", os.path.expanduser("~/.ssh/tart_vm_ed25519"), "-o", "StrictHostKeyChecking=no",
       "-o", "UserKnownHostsFile=/dev/null", "-o", "BatchMode=yes", "-o", "LogLevel=ERROR",
       f"admin@{os.environ.get('VMIP', '192.168.64.2')}"]
SPACE = int(os.environ.get("LAB_SPACE", "3"))
OTHER = int(os.environ.get("OTHER_SPACE", "2"))
SCREEN_W, SCREEN_H = 1920, 1080
PRE = ('post() { osascript -l JavaScript -e "ObjC.import(\\"Foundation\\"); \\$.NSDistributedNotificationCenter.defaultCenter.'
       'postNotificationNameObjectUserInfoDeliverImmediately(\\"com.sentientdonut.lunchbox.command\\", \\"$1\\", \\$(), true)" >/dev/null; }; '
       'wl() { ~/windowlab "$1"; }; ')
HOLD = 40      # ms a frame must be held to count as a stop
GAP = 60       # ms without change that separates two motions


def vm(cmd, timeout=180):
    r = subprocess.run(SSH + [PRE + cmd], capture_output=True, text=True, timeout=timeout)
    return r.stdout


def norm(cmd):
    return cmd.replace("{S}", str(SPACE)).replace("{O}", str(OTHER))


def record(setup, steps, secs=3.0, owners="WindowLab", cleanup=""):
    """Runs `setup` in the VM, then records `secs` while posting `steps` (ms:kind:body)."""
    steps = [norm(s) for s in steps]
    arg = " ".join("'" + s.replace("'", "'\\''") + "'" for s in steps)
    out = vm(f"{norm(setup)}; ~/motion {secs} {owners} {arg} > ~/flash/motion.json; {norm(cleanup)}; cat ~/flash/motion.json")
    line = out.strip().splitlines()[-1] if out.strip() else "{}"
    return json.loads(line)


# ---------- analysis ----------

def parked(r):
    return r[0] >= SCREEN_W - 30 or r[1] >= SCREEN_H - 10


def big(a, b):
    """A real change (not a pixel of rounding)."""
    return any(abs(x - y) > 2 for x, y in zip(a, b))


def inter(a, b):
    w = min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])
    h = min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1])
    return (w, h) if w > 2 and h > 2 else None


def timeline(samples):
    return [(s[0], tuple(s[1:]) if len(s) == 5 else None) for s in samples]


def state_at(tl, t):
    cur = None
    for ts, r in tl:
        if ts <= t: cur = r
        else: break
    return cur


def analyze(rec, ignore=()):
    steps = rec.get("steps", [])
    t0 = steps[0][0] if steps else 0
    t_end = max([s[0] for w in rec["windows"].values() for s in w["samples"]] + [t0])
    per = {}
    for wid, w in rec["windows"].items():
        if w["owner"] in ignore: continue
        tl = timeline(w["samples"])
        start = state_at(tl, t0)
        after = [(t, r) for t, r in tl if t > t0]
        final = tl[-1][1]
        # Motions: changes between two on-screen frames (not parking off screen), grouped by pauses.
        # A group that ends within 12 px (24 px of size) of where it began is macOS's own
        # grow-in of a new window, or rounding: not a motion.
        motions, cur, prev = [], None, start
        for t, r in after:
            if r is not None and prev is not None and big(prev, r) and not (parked(prev) and parked(r)):
                if cur is None or t - cur["last"] >= GAP:
                    cur = {"start": t, "last": t, "frames": 1, "max_gap": 0, "from": prev, "to": r, "path": [prev, r]}
                    motions.append(cur)
                else:
                    cur["max_gap"] = max(cur["max_gap"], t - cur["last"])
                    cur["last"] = t
                    cur["frames"] += 1
                    cur["to"] = r
                    cur["path"].append(r)
            if r is not None: prev = r
        def real(m):
            a, b = m["from"], m["to"]
            return (abs(a[0] + a[2] / 2 - b[0] - b[2] / 2) > 12 or abs(a[1] + a[3] / 2 - b[1] - b[3] / 2) > 12
                    or abs(a[2] - b[2]) > 24 or abs(a[3] - b[3]) > 24)
        motions = [m for m in motions if real(m)]
        # Wobble: how far an edge travels against its own overall direction during a motion
        # (an edge that should hold still, shaking as size and position land a frame apart).
        wobble = 0
        for m in motions:
            if parked(m["from"]) or parked(m["to"]): continue
            for edge in (lambda r: r[0], lambda r: r[1], lambda r: r[0] + r[2], lambda r: r[1] + r[3]):
                vals = [edge(r) for r in m["path"]]
                tv = sum(abs(b - a) for a, b in zip(vals, vals[1:]))
                wobble += max(0, tv - abs(vals[-1] - vals[0]))
        # Settled: from when it stays within 2 px of where it ends.
        settle_t = None
        for t, r in reversed(after):
            if r is not None and final is not None and not big(r, final): settle_t = t
            else: break
        # Stops: frames held HOLD ms or more on screen, other than where it started and ended.
        stops = []
        seq = [(t0, start)] + after if start is not None else after
        for i, (t, r) in enumerate(seq):
            if r is None or parked(r): continue
            nxt = seq[i + 1][0] if i + 1 < len(seq) else t_end
            if nxt - t >= HOLD and (start is None or big(r, start)) and final is not None and big(r, final):
                if not stops or big(stops[-1], r): stops.append(r)
        visible_moves = motions
        appeared = start is None and any(r is not None for _, r in after)
        first_seen = next((t for t, r in after if r is not None), None)
        # Away: time on screen at anything but its final frame (for windows that appeared).
        away = 0
        if appeared and final is not None:
            for i, (t, r) in enumerate(after):
                if r is not None and not parked(r) and big(r, final):
                    nxt = after[i + 1][0] if i + 1 < len(after) else t_end
                    away += nxt - t
        per[wid] = {
            "owner": w["owner"], "start": start, "final": final, "appeared": appeared,
            "appeared_ms": round(first_seen - t0) if appeared and first_seen is not None else None,
            "motions": len(visible_moves),
            "stops": len(stops),
            "settle_ms": round(settle_t - t0) if settle_t is not None else 0,
            "wobble": round(wobble),
            "away_ms": round(away) if appeared else None,
            "frames": [m["frames"] for m in visible_moves],
            "max_gap": max([m["max_gap"] for m in visible_moves] + [0]),
            "moves": [(round(m["start"] - t0), round(m["last"] - t0)) for m in visible_moves],
        }
    # Overlap between on-screen windows, over time; and whole layouts held on the way.
    times = sorted({s[0] for w in rec["windows"].values() for s in w["samples"] if s[0] > t0})
    # A window that closes fades out where it was: not an overlap anyone sees as one.
    tls = {wid: timeline(w["samples"]) for wid, w in rec["windows"].items() if wid in per and per[wid]["final"] is not None}
    overlap_ms, worst, layouts = 0.0, 0.0, []
    first_overlap = None
    for i, t in enumerate([t0] + times):
        nxt = times[i] if i < len(times) else t_end
        rects = [r for r in (state_at(tl, t) for tl in tls.values()) if r is not None and not parked(r)]
        hit = 0.0
        for a in range(len(rects)):
            for b in range(a + 1, len(rects)):
                o = inter(rects[a], rects[b])
                if o:
                    frac = o[0] * o[1] / min(rects[a][2] * rects[a][3], rects[b][2] * rects[b][3])
                    hit = max(hit, frac)
        if hit > 0.005:
            overlap_ms += nxt - t
            worst = max(worst, hit)
            if first_overlap is None: first_overlap = round(t - t0)
        config = tuple(sorted(rects))
        if nxt - t >= HOLD and (not layouts or layouts[-1] != config): layouts.append(config)
    final_cfg = tuple(sorted(r for r in (tls[w][-1][1] for w in tls) if r is not None and not parked(r)))
    initial_cfg = tuple(sorted(r for r in (state_at(tl, t0) for tl in tls.values()) if r is not None and not parked(r)))
    mids = [c for c in layouts if c != final_cfg and c != initial_cfg]
    settles = [p["settle_ms"] for p in per.values() if p["settle_ms"]]
    return {
        "windows": per,
        "settle_ms": max(settles) if settles else 0,
        "spread_ms": (max(settles) - min(settles)) if len(settles) > 1 else 0,
        "max_motions": max([p["motions"] for p in per.values()] + [0]),
        "total_motions": sum(p["motions"] for p in per.values()),
        "max_stops": max([p["stops"] for p in per.values()] + [0]),
        "layouts": len(mids),
        "overlap_ms": round(overlap_ms),
        "overlap_max": round(worst * 100, 1),
        "first_overlap": first_overlap,
        "final_overlap": any(inter(a, b) for i, a in enumerate(final_cfg) for b in final_cfg[i + 1:]),
        "max_gap": max([p["max_gap"] for p in per.values()] + [0]),
        "wobble": sum(p["wobble"] for p in per.values()),
    }


# ---------- cases ----------

BASE = "wl closeall; wl slow:0; wl heavy:0; post space-{S}; sleep 0.9"
def normals(n, gap=0.7): return "; ".join(["wl normal", f"sleep {gap}"] * n) if n else "true"

CASES = {}
def case(name, setup, steps, secs=3.0, owners="WindowLab", cleanup="", ignore=()):
    CASES[name] = dict(setup=setup, steps=steps, secs=secs, owners=owners, cleanup=cleanup, ignore=ignore)

for k in range(1, 5):
    case(f"arrive_{k}", f"{BASE}; {normals(k - 1)}; sleep 0.6", ["300:wl:normal"], secs=2.5)
case("burst_5", f"{BASE}; sleep 0.4", ["300:wl:burst:5:40"], secs=4.0)
case("burst_3_slow", f"{BASE}; {normals(1)}; wl slow:60; sleep 0.6", ["300:wl:burst:3:40"], secs=4.0, cleanup="wl slow:0")
TE = ("pkill -x TextEdit; sleep 1; defaults write com.apple.TextEdit NSQuitAlwaysKeepsWindows -bool true; "
      "rm -rf ~/Library/Containers/com.apple.TextEdit/Data/Library/Saved\\ Application\\ State; "
      "for i in 1 2 3 4 5; do echo restore $i > ~/flash/r$i.txt; done; "
      f"{BASE}; "
      "open -a TextEdit ~/flash/r1.txt; sleep 1.2; for i in 2 3 4 5; do open -a TextEdit ~/flash/r$i.txt; sleep 0.9; done; sleep 1; "
      "open -a TextEdit; sleep 0.6; post press:12:cmd; sleep 2; pgrep -x TextEdit && (post press:12:cmd; sleep 2); "
      "post space-{S}; sleep 0.5")
case("restore_textedit_5", TE, ["300:sh:open -a TextEdit"], secs=5.0, owners="TextEdit",
     cleanup="sleep 0.2; pkill -x TextEdit; defaults write com.apple.TextEdit NSQuitAlwaysKeepsWindows -bool false")
case("close_3to2", f"{BASE}; {normals(3)}; sleep 0.6", ["300:lunchbox:close"], secs=2.5)
case("close_4to3", f"{BASE}; {normals(4)}; sleep 0.6", ["300:lunchbox:close"], secs=2.5)
case("move_left", f"{BASE}; {normals(3)}; sleep 0.6", ["300:lunchbox:move-left"], secs=2.5)
case("swap_up", f"{BASE}; {normals(2)}; sleep 0.4; post move-left; sleep 1.0", ["300:lunchbox:move-up"], secs=2.5)
case("grow", f"{BASE}; {normals(2)}; sleep 0.6", ["300:lunchbox:grow"], secs=2.5)
case("shrink", f"{BASE}; {normals(2)}; sleep 0.6", ["300:lunchbox:shrink"], secs=2.5)
case("grow_3", f"{BASE}; {normals(3)}; sleep 0.6", ["300:lunchbox:grow"], secs=2.5)
case("tidy", f"{BASE}; {normals(3)}; post grow; sleep 0.6; post grow; sleep 0.8", ["300:lunchbox:normalize"], secs=2.5)
case("focus_on", f"{BASE}; {normals(4)}; sleep 0.6", ["300:lunchbox:spotlight"], secs=2.5)
case("focus_off", f"{BASE}; {normals(4)}; post spotlight; sleep 1.2", ["300:lunchbox:spotlight"], secs=2.5)
case("space_away_6", f"{BASE}; {normals(6, 0.6)}; sleep 0.8", ["300:lunchbox:space-{O}"], secs=2.0,
     cleanup="post space-{S}")
case("space_back_6", f"{BASE}; {normals(6, 0.6)}; sleep 0.8; post space-{{O}}; sleep 1.2", ["300:lunchbox:space-{S}"], secs=2.0)
case("fitted_aspect", f"{BASE}; {normals(1)}; sleep 0.6", ["300:wl:aspect:390:844"], secs=3.0)
case("fitted_fixed", f"{BASE}; {normals(1)}; sleep 0.6", ["300:wl:fixed:320:500"], secs=3.0)
case("fitted_min", f"{BASE}; {normals(1)}; sleep 0.6", ["300:wl:min:1100:400"], secs=3.0)
case("slow_grow", f"{BASE}; {normals(2)}; wl slow:60; sleep 0.6", ["300:lunchbox:grow"], secs=2.5, cleanup="wl slow:0")
case("slow_arrive_3", f"{BASE}; {normals(2)}; wl slow:60; sleep 0.6", ["300:wl:normal"], secs=2.5, cleanup="wl slow:0")
case("heavy_grow", f"{BASE}; {normals(2)}; wl heavy:25; sleep 0.6", ["300:lunchbox:grow"], secs=2.5, cleanup="wl heavy:0")
case("heavy_focus_on", f"{BASE}; {normals(3)}; wl heavy:25; sleep 0.6", ["300:lunchbox:spotlight"], secs=2.5, cleanup="wl heavy:0")


def fmt_case(name, a):
    ws = a["windows"]
    mot = "/".join(str(ws[w]["motions"]) for w in sorted(ws, key=int))
    stops = "/".join(str(ws[w]["stops"]) for w in sorted(ws, key=int))
    extra = ""
    arr = [w for w in ws.values() if w["appeared"]]
    if arr: extra = " away " + "/".join(str(w["away_ms"]) for w in arr) + " ms"
    return (f"{name:<20} settle {a['settle_ms']:>5} ms  spread {a['spread_ms']:>4}  motions {mot:<14} stops {stops:<12} "
            f"layouts {a['layouts']}  wobble {a['wobble']:>3}  overlap {a['overlap_ms']} ms ({a['overlap_max']}%)  gap {a['max_gap']:.0f}{extra}"
            + ("  FINAL-OVERLAP" if a["final_overlap"] else ""))


# ---------- tables ----------

KEYS = [("settle_ms", "settle"), ("spread_ms", "spread"), ("max_motions", "motions"), ("total_motions", "total"),
        ("max_stops", "stops"), ("layouts", "layouts"), ("wobble", "wobble"), ("overlap_ms", "overlap"), ("max_gap", "gap")]


def med(rs, k):
    vals = [r[k] for r in rs if r.get(k) is not None]
    return statistics.median(vals) if vals else None


def worst(rs, k):
    vals = [r[k] for r in rs if r.get(k) is not None]
    return max(vals) if vals else None


def load(p):
    return json.load(open(p))


def table(argv):
    a = load(argv[0])
    b = load(argv[1]) if len(argv) > 1 else None
    head = f"{'case':<20}" + "".join(f"{label:>16}" for _, label in KEYS)
    print(head)
    for name in a:
        ra = a[name]
        rb = b.get(name, []) if b else None
        if not ra: continue
        row = f"{name:<20}"
        for k, _ in KEYS:
            x = med(ra, k)
            if b is not None and rb:
                y = med(rb, k)
                row += f"{fmt(x):>8}→{fmt(y):<7}"
            else:
                row += f"{fmt(x):>16}"
        print(row)


def fmt(v):
    if v is None: return "-"
    return f"{v:.0f}" if abs(v - round(v)) < 1e-9 or v >= 10 else f"{v:.1f}"



def main():
    args = sys.argv[1:]
    if args[:1] == ["--table"]:
        return table(args[1:])
    runs, out = 1, None
    if "-n" in args:
        i = args.index("-n"); runs = int(args[i + 1]); del args[i:i + 2]
    if "--json" in args:
        i = args.index("--json"); out = args[i + 1]; del args[i:i + 2]
    names = args or list(CASES)
    results = {}
    for name in names:
        c = CASES[name]
        results[name] = []
        for r in range(runs):
            try:
                rec = record(c["setup"], c["steps"], c["secs"], c["owners"], c["cleanup"])
                a = analyze(rec, c["ignore"])
                a["raw"] = rec
            except Exception as e:
                print(f"{name:<20} failed: {e!r}"); continue
            results[name].append(a)
            print(fmt_case(name if runs == 1 else f"{name}#{r + 1}", a), flush=True)
    vm("wl closeall; wl slow:0; wl heavy:0")
    if out:
        json.dump(results, open(out, "w"))


if __name__ == "__main__":
    main()
