"""Round 2: question designs and label-free calibration for open System One models on windows.

Usage: python -I bench2.py laya|julia <windows.jsonl> <out.json>

Every variant was written down before any of them was run:

States
  S1  the round-1 state: numbers and Accessibility names
      (`Finder "doc.pdf Info": StandardWindow, 265x565, 8% screen, close minimize zoom`).
  S2  plain words: size as a word, missing buttons spelled out, what floats or can't resize said
      (`Finder window "doc.pdf Info": normal window, small, no full screen button`).

Questions (asked about the state; all in one request)
  choice5       round 1's five-way choice, short labels.
  choice5desc   five-way choice, each option described (Julia's guidance: clear, distinct options).
  atomic        four yes/no questions with descriptive true/false criteria (Jev's guidance: atomic
                questions combined in code; Julia's: descriptive noul criteria), combined by a fixed
                cascade: asking something > video or call > temporary > main window or not.
  coarse        two-way choice, tile or float, then a four-way choice among the floating kinds.

Label-free corrections (computed from unlabeled windows, so a shipped LunchboxWM could do the same
with the windows it sees on a Mac)
  raw           as the model says.
  batch         batch calibration: divide each option's probability by its mean over all windows.
  null          contextual calibration: divide by the answer for a content-free window ("N/A").

Option order
  rot           choice5desc averaged over all five rotations of the options (Laya's guidance).
"""
import json
import sys
import time

sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
from bench import CLASSES, state_text  # noqa: E402

SIZE_WORDS = [(0.03, "tiny"), (0.08, "small"), (0.25, "medium"), (0.45, "large"), (9, "very large")]
KIND_WORDS = {"AXStandardWindow": "normal window", "AXDialog": "dialog", "AXSystemDialog": "system dialog",
              "AXFloatingWindow": "floating panel", "AXSystemFloatingWindow": "floating panel"}


def plain_state(t):
    app = t.get("appName") or t["app"].split(".")[-1]
    title = (t.get("title") or "").strip()
    named = f'"{title}"' if title else "with no title"
    kind = KIND_WORDS.get(t.get("subrole"), "unusual window")
    size = next(word for limit, word in SIZE_WORDS if t.get("screenShare", 0) < limit)
    b = t.get("buttons", 0)
    traits = []
    if b == 0:
        traits.append("no title bar buttons")
    else:
        if not b & 2:
            traits.append("no minimize button")
        if not b & 8:
            traits.append("no full screen button")
    if not t.get("resizable"):
        traits.append("can't be resized")
    if t.get("layer", 0) != 0:
        traits.append("stays above other windows")
    if t.get("modal"):
        traits.append("modal")
    if t.get("hasDefaultButton") and t.get("hasCancelButton"):
        traits.append("has OK and Cancel")
    if t.get("isDocument"):
        traits.append("shows a file")
    return f'{app} window {named}: {kind}, {size}' + (f', {", ".join(traits)}' if traits else "")


Q_CHOICE5 = {"type": "choice", "instructions": "What kind of window is this?", "criteria": {
    "document": "main or document window", "panel": "tool panel, inspector or settings",
    "transient": "progress, splash or pop-up", "media": "video or call", "dialog": "asks the user something"}}
Q_CHOICE5DESC = {"type": "choice", "instructions": "What kind of window is this?", "criteria": {
    "document": "the app's main window or a document, page or folder",
    "panel": "a helper: inspector, info, palette or settings",
    "transient": "temporary: progress, loading, splash or welcome",
    "media": "video, picture in picture, camera or call",
    "dialog": "asks the user: alert, prompt, open or save"}}
Q_ATOMIC = {
    "asks": {"type": "noul", "instructions": "Does this window ask the user to answer or decide something?",
             "criteria": {"false": "no: it shows content or tools", "true": "yes: an alert, prompt, or open or save panel"}},
    "media": {"type": "noul", "instructions": "Does this window show video or a call?",
              "criteria": {"false": "no: no video or call", "true": "yes: a video, picture in picture, camera or call"}},
    "temporary": {"type": "noul", "instructions": "Is this window temporary?",
                  "criteria": {"false": "no: it stays open while used", "true": "yes: progress, loading, splash or welcome"}},
    "main": {"type": "noul", "instructions": "Is this the app's main or document window?",
             "criteria": {"false": "no: a helper, tool, info or settings window", "true": "yes: the main window or a document"}},
}
Q_COARSE = {
    "tile": {"type": "choice", "instructions": "Should a tiling window manager tile this window?", "criteria": {
        "tile": "tile it: a main or document window", "float": "let it float: a helper, temporary, video or dialog"}},
    "kind": {"type": "choice", "instructions": "What kind of floating window is this?", "criteria": {
        "panel": "a helper: inspector, info, palette or settings", "transient": "temporary: progress, loading or welcome",
        "media": "video, picture in picture or call", "dialog": "asks the user: alert, prompt, open or save"}},
}

SETS = {
    "S1.choice5": ("S1", {"q": Q_CHOICE5}),
    "S2.choice5": ("S2", {"q": Q_CHOICE5}),
    "S2.choice5desc": ("S2", {"q": Q_CHOICE5DESC}),
    "S2.atomic": ("S2", Q_ATOMIC),
    "S2.coarse": ("S2", Q_COARSE),
}


def rotations(q):
    keys = list(q["criteria"])
    out = []
    for r in range(len(keys)):
        order = keys[r:] + keys[:r]
        out.append({**q, "criteria": {k: q["criteria"][k] for k in order}})
    return out


def answer_probs(a):
    if a.get("type") == "noul" or "noul" in a:
        p = float(a["noul"])
        return {"false": 1 - p, "true": p}
    return {k: float(v) for k, v in a["probabilities"].items()}


class Model:
    def __init__(self, which):
        base = "/Volumes/Master Storage/AI-Models/system-one"
        if which == "laya":
            from laya_coreml import load
            self.m = load(f"{base}/laya-multilingual-coreml-ane", local_files_only=True)
            self.ask = lambda s, q: self.m.system_one(s, q)
        else:
            sys.path.insert(0, f"{base}/Julia-1")
            from julia import load_model
            self.m = load_model(f"{base}/Julia-1", device="cpu", strict_encoding=True, max_length=1024, head_length=512)
            self.ask = lambda s, q: self.m.predict(state=s, questions=q)

    def run(self, state, questions):
        r = self.ask(state, questions)
        usage = r.get("usage", {}) if isinstance(r, dict) else {}
        return {qid: answer_probs(a) for qid, a in r["answers"].items()}, bool(usage.get("truncated"))


def main():
    which, data, out = sys.argv[1], sys.argv[2], sys.argv[3]
    windows = [json.loads(l) for l in open(data)]
    model = Model(which)
    states = {"S1": lambda t: state_text(t, "A"), "S2": plain_state}
    model.run("warm up", {"q": Q_CHOICE5})
    result = {"model": which, "windows": [], "null": {}, "ms": {}, "truncated": {}}
    # The content-free answer, for contextual calibration.
    for name, (_, qs) in SETS.items():
        result["null"][name], _ = model.run("N/A", qs)
    rot_null = [model.run("N/A", {"q": q})[0]["q"] for q in rotations(Q_CHOICE5DESC)]
    result["null"]["S2.choice5desc.rot"] = {"q": {k: sum(r[k] for r in rot_null) / len(rot_null) for k in rot_null[0]}}
    for name in list(SETS) + ["S2.choice5desc.rot"]:
        result["ms"][name] = []
        result["truncated"][name] = 0
    for w in windows:
        t = w["traits"]
        row = {"id": w["id"], "label": w["label"], "answers": {}}
        for name, (style, qs) in SETS.items():
            t0 = time.perf_counter()
            row["answers"][name], cut = model.run(states[style](t), qs)
            result["ms"][name].append((time.perf_counter() - t0) * 1000)
            result["truncated"][name] += cut
        t0 = time.perf_counter()
        rots = [model.run(plain_state(t), {"q": q}) for q in rotations(Q_CHOICE5DESC)]
        result["ms"]["S2.choice5desc.rot"].append((time.perf_counter() - t0) * 1000)
        result["truncated"]["S2.choice5desc.rot"] += any(c for _, c in rots)
        probs = [r[0]["q"] for r in rots]
        row["answers"]["S2.choice5desc.rot"] = {"q": {k: sum(p[k] for p in probs) / len(probs) for k in probs[0]}}
        result["windows"].append(row)
    json.dump(result, open(out, "w"), indent=1)
    print(f"{which}: {len(windows)} windows; truncated per variant: {result['truncated']}")


if __name__ == "__main__":
    main()
