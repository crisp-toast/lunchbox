"""Zero-shot benchmark of open System One decision models on Lunchbox's 84 labeled windows.

Usage: python -I bench.py laya|julia <windows.jsonl> [--prompt A|B] [--out results.json]

Each window becomes a short text state (its app, title and Accessibility traits) and one typed
`choice` question with five options, one per behavior. Nothing is trained on these windows.
"""
import json
import os
import resource
import statistics
import sys
import time

CLASSES = ["document", "panel", "transient", "media", "dialog"]
FLOATING_APPS = {
    "com.apple.systempreferences", "com.apple.iphonesimulator", "com.1password.1password",
    "com.apple.calculator", "com.apple.QuickTimePlayerX", "com.apple.ScreenSharing",
    "com.apple.screencaptureui", "com.sentientdonut.lunchbox",
}


def is_dialog(t):
    """Lunchbox's Dialogs.isDialog."""
    if t.get("subrole") in ("AXDialog", "AXSystemDialog"):
        return True
    if t.get("identifier") in ("open-panel", "save-panel"):
        return True
    if t.get("hasDefaultButton") and t.get("hasCancelButton"):
        return True
    return bool(t.get("modal"))


def by_rules(t):
    """WindowBehavior.byRules: dialogs center, standard resizable windows tile unless their app
    always floats, everything else floats."""
    if is_dialog(t):
        return "dialog"
    if t.get("role") == "AXWindow" and t.get("subrole") == "AXStandardWindow" and t.get("resizable") \
            and t["app"] not in FLOATING_APPS:
        return "document"
    return "panel"


def shipped(t, rule, model, confidence, threshold):
    """BehaviorDecision.combine: the safety floor around the model."""
    if is_dialog(t):
        return "dialog"
    if confidence < threshold:
        return rule
    if model == "document" and (not t.get("resizable") or t["app"] in FLOATING_APPS):
        return rule
    return model


BUTTONS = [(1, "close"), (2, "minimize"), (4, "zoom"), (8, "full screen")]


def state_text(t, style):
    """One short line describing the window, as Lunchbox would hand it to the model."""
    app = t.get("appName") or t["app"].split(".")[-1]
    title = (t.get("title") or "").strip()
    subrole = (t.get("subrole") or "none").replace("AX", "")
    buttons = [name for bit, name in BUTTONS if t.get("buttons", 0) & bit]
    share = round(100 * t.get("screenShare", 0))
    size = f'{int(t["width"])}x{int(t["height"])}'
    traits = []
    if not t.get("resizable"):
        traits.append("fixed size")
    if t.get("modal"):
        traits.append("modal")
    if t.get("hasDefaultButton"):
        traits.append("default button")
    if t.get("hasCancelButton"):
        traits.append("cancel button")
    if t.get("layer", 0) != 0:
        traits.append("floats above other windows")
    if t.get("hasToolbar"):
        traits.append("toolbar")
    if t.get("isDocument"):
        traits.append("shows a file")
    named = f'"{title}"' if title else "untitled"
    if style == "A":
        # Compact: fits Laya's 96-token Neural Engine window with the question.
        return f'{app} {named}: {subrole}, {size}, {share}% screen, {" ".join(buttons) or "no buttons"}' + \
               (f', {", ".join(traits)}' if traits else "")
    # B: a bit more context, for models with room (Julia).
    return (f'A macOS window of the app {app}. Title: {named}. Accessibility subrole: {subrole}. '
            f'Size {size} points, {share}% of the screen. Title bar buttons: {", ".join(buttons) or "none"}. '
            f'{("Other traits: " + ", ".join(traits) + ".") if traits else ""} The app has {t.get("appWindows", 1)} windows open.')


# Short on purpose: Laya's Neural Engine package shares 96 tokens between the state, the question
# and the options. Written once, before looking at any results, and used for both models.
QUESTION_INSTRUCTIONS = "What kind of window is this?"
OPTIONS = {
    "document": "main or document window",
    "panel": "tool panel, inspector or settings",
    "transient": "progress, splash or pop-up",
    "media": "video or call",
    "dialog": "asks the user something",
}


def footprint_mb():
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**20  # bytes on macOS


class Laya:
    def __init__(self, path):
        from laya_coreml import load
        t0 = time.perf_counter()
        self.agent = load(path, local_files_only=True)
        self.load_s = time.perf_counter() - t0
        self.questions = {"behavior": {"type": "choice", "instructions": QUESTION_INSTRUCTIONS, "criteria": OPTIONS}}

    def decide(self, state):
        r = self.agent.system_one(state, self.questions)
        a = r["answers"]["behavior"] if "answers" in r else r["behavior"]
        return a, r.get("usage", {})


class Julia:
    def __init__(self, path):
        sys.path.insert(0, path)
        from julia import load_model  # the model repo's own runtime
        t0 = time.perf_counter()
        self.engine = load_model(path, device="cpu", strict_encoding=True, max_length=1024, head_length=512)
        self.load_s = time.perf_counter() - t0
        self.questions = {"behavior": {"type": "choice", "instructions": QUESTION_INSTRUCTIONS, "criteria": OPTIONS}}

    def decide(self, state):
        r = self.engine.predict(state=state, questions=self.questions)
        a = r["answers"]["behavior"] if isinstance(r, dict) and "answers" in r else r["behavior"]
        return a, r.get("usage", {}) if isinstance(r, dict) else {}


def probabilities(answer):
    """{option: probability} from a choice answer, whatever the exact shape."""
    for key in ("probabilities", "probs", "distribution"):
        if key in answer:
            p = answer[key]
            if isinstance(p, dict):
                return {k: float(v) for k, v in p.items()}
            return {CLASSES[i]: float(v) for i, v in enumerate(p)}
    raise KeyError(f"no probabilities in {answer}")


def main():
    which, data = sys.argv[1], sys.argv[2]
    style = sys.argv[sys.argv.index("--prompt") + 1] if "--prompt" in sys.argv else "A"
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else None
    windows = [json.loads(l) for l in open(data)]
    base = "/Volumes/Master Storage/AI-Models/system-one"
    rss0 = footprint_mb()
    model = Laya(f"{base}/laya-multilingual-coreml-ane") if which == "laya" else Julia(f"{base}/Julia-1")
    rss1 = footprint_mb()
    print(f"{which}: loaded in {model.load_s:.2f} s, peak RSS {rss0:.0f} -> {rss1:.0f} MB")

    model.decide(state_text(windows[0]["traits"], style))  # warm up
    rows, times, tokens = [], [], []
    for w in windows:
        t = w["traits"]
        s = state_text(t, style)
        t0 = time.perf_counter()
        try:
            answer, usage = model.decide(s)
        except Exception as e:  # e.g. over the token budget
            print(f"  ! {w['id']} {t['app']}: {e}")
            answer, usage = None, {}
        times.append((time.perf_counter() - t0) * 1000)
        if usage:
            tokens.append(usage.get("state_tokens") or usage.get("input_tokens") or 0)
        if answer is None:
            probs = {c: (1.0 if c == by_rules(t) else 0.0) for c in CLASSES}
        else:
            probs = probabilities(answer)
        best = max(probs, key=probs.get)
        rows.append({"id": w["id"], "app": t["app"], "title": t.get("title"), "label": w["label"], "rule": by_rules(t),
                     "model": best, "confidence": probs[best], "probs": probs, "failed": answer is None})
    rss2 = footprint_mb()

    n = len(rows)
    def pct(k): return f"{100 * k / n:3.0f}% ({k}/{n})"
    tiles = lambda c: c == "document"
    print(f"\nzero-shot, prompt {style}, {n} windows")
    print("  rules       behavior", pct(sum(r["rule"] == r["label"] for r in rows)),
          "  tile-or-not", pct(sum(tiles(r["rule"]) == tiles(r["label"]) for r in rows)))
    print("  model alone behavior", pct(sum(r["model"] == r["label"] for r in rows)),
          "  tile-or-not", pct(sum(tiles(r["model"]) == tiles(r["label"]) for r in rows)))
    for th in (0.5, 0.6, 0.7, 0.8, 0.9):
        s = [shipped(next(w["traits"] for w in windows if w["id"] == r["id"]), r["rule"], r["model"], r["confidence"], th) for r in rows]
        print(f"  shipped@{th}  behavior", pct(sum(a == r["label"] for a, r in zip(s, rows))),
              "  tile-or-not", pct(sum(tiles(a) == tiles(r["label"]) for a, r in zip(s, rows))))
    print("  recall by class (rules | model):")
    for c in CLASSES:
        these = [r for r in rows if r["label"] == c]
        print(f"    {c:10} {sum(r['rule'] == c for r in these)}/{len(these)} | {sum(r['model'] == c for r in these)}/{len(these)}")
    print("  model's calls:", {c: sum(r["model"] == c for r in rows) for c in CLASSES},
          " failed:", sum(r["failed"] for r in rows))
    times.sort()
    print(f"  latency per decision: median {statistics.median(times):.2f} ms, p95 {times[int(0.95 * len(times)) - 1]:.2f} ms"
          f", max {times[-1]:.2f} ms;  peak RSS {rss2:.0f} MB" + (f";  state tokens median {statistics.median(tokens):.0f}" if tokens else ""))
    if out:
        json.dump({"model": which, "prompt": style, "rows": rows, "times_ms": times, "load_s": model.load_s,
                   "peak_rss_mb": rss2}, open(out, "w"), indent=1)


if __name__ == "__main__":
    main()
