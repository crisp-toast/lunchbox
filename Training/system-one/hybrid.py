"""Do System One answers help once a small head sees LunchboxWM's labels? Leave-one-app-out.

Usage: python -I hybrid.py <windows.jsonl> <features.json> laya-A.json julia-A.json julia-B.json
"""
import json
import sys

import numpy as np

sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))

from bench import CLASSES, by_rules, shipped

windows = {json.loads(l)["id"]: json.loads(l) for l in open(sys.argv[1])}
feats = {r["id"]: r for r in json.load(open(sys.argv[2]))}
runs = {name: {r["id"]: r for r in json.load(open(path))["rows"]}
        for name, path in zip(["laya", "juliaA", "juliaB"], sys.argv[3:6])}
ids = sorted(windows)
y = np.array([CLASSES.index(windows[i]["label"]) for i in ids])
apps = np.array([windows[i]["traits"]["app"] for i in ids])


def logp(run):
    return np.array([[np.log(max(1e-6, run[i]["probs"][c])) for c in CLASSES] for i in ids])


S = np.array([feats[i]["structure"] for i in ids])
T = np.array([feats[i]["title"] for i in ids])
sets = {
    "LunchboxWM's features (structure + title)": [S, T],
    "structure + Laya": [S, logp(runs["laya"])],
    "structure + Julia (A)": [S, logp(runs["juliaA"])],
    "LunchboxWM's features + Laya": [S, T, logp(runs["laya"])],
    "LunchboxWM's features + Julia (A)": [S, T, logp(runs["juliaA"])],
    "LunchboxWM's features + Julia (B)": [S, T, logp(runs["juliaB"])],
    "Laya's answer alone, recalibrated": [logp(runs["laya"])],
    "Julia's answer alone, recalibrated (A)": [logp(runs["juliaA"])],
}


def train(X, y, l2=0.02, steps=600, rate=0.05):
    n, d = X.shape
    k = len(CLASSES)
    counts = np.bincount(y, minlength=k).astype(float)
    cw = np.where(counts > 0, np.minimum(4, n / (k * np.maximum(counts, 1))), 0)
    Xb = np.hstack([X, np.ones((n, 1))])
    W = np.zeros((k, d + 1))
    m = np.zeros_like(W); v = np.zeros_like(W)
    Y = np.eye(k)[y]
    for t in range(1, steps + 1):
        z = Xb @ W.T
        z -= z.max(1, keepdims=True)
        p = np.exp(z); p /= p.sum(1, keepdims=True)
        g = ((p - Y) * cw[y][:, None]).T @ Xb / n
        g[:, :-1] += l2 * W[:, :-1]
        m = 0.9 * m + 0.1 * g; v = 0.999 * v + 0.001 * g * g
        W -= rate * (m / (1 - 0.9 ** t)) / (np.sqrt(v / (1 - 0.999 ** t)) + 1e-8)
    return W


def loao(blocks):
    X = np.hstack(blocks)
    pred = np.zeros(len(ids), dtype=int); conf = np.zeros(len(ids))
    for app in sorted(set(apps)):
        tr, te = apps != app, apps == app
        mu = X[tr].mean(0); sd = X[tr].std(0); sd[sd < 1e-6] = 1
        W = train((X[tr] - mu) / sd, y[tr])
        Xt = np.hstack([(X[te] - mu) / sd, np.ones((te.sum(), 1))])
        z = Xt @ W.T; z -= z.max(1, keepdims=True)
        p = np.exp(z); p /= p.sum(1, keepdims=True)
        pred[te] = p.argmax(1); conf[te] = p.max(1)
    return pred, conf


def report(name, pred, conf):
    n = len(ids)
    behavior = (pred == y).sum()
    tile = ((pred == 0) == (y == 0)).sum()
    ship = [shipped(windows[i]["traits"], by_rules(windows[i]["traits"]), CLASSES[pred[j]], conf[j], 0.5) for j, i in enumerate(ids)]
    sb = sum(s == windows[i]["label"] for s, i in zip(ship, ids))
    st = sum((s == "document") == (windows[i]["label"] == "document") for s, i in zip(ship, ids))
    print(f"  {name:42} model {100*behavior/n:3.0f}% / {100*tile/n:3.0f}%   shipped@0.5 {100*sb/n:3.0f}% / {100*st/n:3.0f}%")


rules = np.array([CLASSES.index(by_rules(windows[i]["traits"])) for i in ids])
print(f"Leave-one-app-out, {len(ids)} windows; behavior / tile-or-not")
print(f"  {'old rules':42} {100*(rules == y).mean():3.0f}% / {100*((rules == 0) == (y == 0)).mean():3.0f}%")
for name in ["laya", "juliaA", "juliaB"]:
    p = np.array([CLASSES.index(runs[name][i]["model"]) for i in ids])
    print(f"  {name + ' zero-shot':42} {100*(p == y).mean():3.0f}% / {100*((p == 0) == (y == 0)).mean():3.0f}%")
for name, blocks in sets.items():
    report(name, *loao(blocks))
