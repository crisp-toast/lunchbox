"""Scores round 2 (bench2.py): every question design × label-free correction, against the rules.

Usage: python -I eval2.py <windows.jsonl> round2-laya.json [round2-julia.json ...]
"""
import json
import statistics
import sys

sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
from bench import CLASSES, by_rules, shipped  # noqa: E402

traits = {json.loads(l)["id"]: json.loads(l)["traits"] for l in open(sys.argv[1])}


def normalize(p):
    s = sum(p.values())
    return {k: v / s for k, v in p.items()}


def correct(p, prior):
    """Divide out a prior (batch mean or content-free answer), then renormalize."""
    return normalize({k: v / max(prior[k], 1e-6) for k, v in p.items()})


def priors(rows, name, qid):
    keys = rows[0]["answers"][name][qid].keys()
    return {k: statistics.mean(r["answers"][name][qid][k] for r in rows) for k in keys}


def decide(name, answers, fix):
    """(behavior, confidence) from one window's answers, after the correction `fix`."""
    if name.endswith("atomic"):
        p = {q: fix(q, answers[q])["true"] for q in ("asks", "media", "temporary", "main")}
        for q, behavior in (("asks", "dialog"), ("media", "media"), ("temporary", "transient")):
            if p[q] >= 0.5:
                return behavior, p[q]
        return ("document", p["main"]) if p["main"] >= 0.5 else ("panel", 1 - p["main"])
    if name.endswith("coarse"):
        tile = fix("tile", answers["tile"])
        if tile["tile"] >= 0.5:
            return "document", tile["tile"]
        kind = fix("kind", answers["kind"])
        best = max(kind, key=kind.get)
        return best, min(tile["float"], kind[best])
    p = fix("q", answers["q"])
    best = max(p, key=p.get)
    return best, p[best]


def evaluate(path):
    run = json.load(open(path))
    rows = run["windows"]
    n = len(rows)
    print(f"\n=== {run['model']} ({n} windows), behavior / tile-or-not; shipped = rules' floor + model when sure")
    rules = [by_rules(traits[r["id"]]) for r in rows]
    print(f"  {'old rules':34} {100*sum(a == r['label'] for a, r in zip(rules, rows))/n:4.0f}% / "
          f"{100*sum((a == 'document') == (r['label'] == 'document') for a, r in zip(rules, rows))/n:3.0f}%")
    best = []
    for name in run["ms"]:
        qids = list(rows[0]["answers"][name])
        for correction in ("raw", "batch", "null"):
            if correction == "raw":
                fix = lambda q, p: normalize(p)
            elif correction == "batch":
                pri = {q: priors(rows, name, q) for q in qids}
                fix = lambda q, p, pri=pri: correct(p, pri[q])
            else:
                pri = run["null"][name]
                fix = lambda q, p, pri=pri: correct(p, pri[q])
            calls = [decide(name, r["answers"][name], fix) for r in rows]
            acc = sum(c[0] == r["label"] for c, r in zip(calls, rows))
            tile = sum((c[0] == "document") == (r["label"] == "document") for c, r in zip(calls, rows))
            ship = {}
            for th in (0.5, 0.7, 0.9):
                s = [shipped(traits[r["id"]], by_rules(traits[r["id"]]), c[0], c[1], th) for c, r in zip(calls, rows)]
                ship[th] = (sum(a == r["label"] for a, r in zip(s, rows)),
                            sum((a == "document") == (r["label"] == "document") for a, r in zip(s, rows)))
            recall = " ".join(f"{c[:3]} {sum(k[0] == c and r['label'] == c for k, r in zip(calls, rows))}/"
                              f"{sum(r['label'] == c for r in rows)}" for c in CLASSES)
            label = f"{name} · {correction}"
            print(f"  {label:34} {100*acc/n:4.0f}% / {100*tile/n:3.0f}%   shipped@0.5 {100*ship[0.5][0]/n:3.0f}% / "
                  f"{100*ship[0.5][1]/n:3.0f}%  @0.9 {100*ship[0.9][0]/n:3.0f}% / {100*ship[0.9][1]/n:3.0f}%   [{recall}]")
            best.append((acc, tile, label))
    print("  latency per window (all questions of the design):",
          ", ".join(f"{k} {statistics.median(v):.1f} ms" for k, v in run["ms"].items()))
    print("  windows whose state was cut to fit:", run["truncated"])
    top = sorted(best, reverse=True)[:3]
    print("  best three by behavior:", "; ".join(f"{l} {100*a/n:.0f}%/{100*t/n:.0f}%" for a, t, l in top))


for path in sys.argv[2:]:
    evaluate(path)
