"""Can an open System One model do Tessel's text jobs? A synthetic probe, written before any run.

1. Find a window by describing it: a desktop of 15 windows with realistic titles, and three
   queries per window (one with the title's words, one partial, one that only describes it).
2. Plain-English commands: 12 of Tessel's actions, four phrasings each, plus which app and which
   Workspace a command names.

Baseline: word matching (query words that start a word in the window's app or title), roughly
what Summon's matching can do today.

Usage: python -I texttasks.py laya|julia
       python -I texttasks.py dump texttasks.json   (the same data, for embedprobe.swift)
"""
import re
import statistics
import sys
import time

DESKTOP = [
    ("Slack", "#design-reviews"), ("Slack", "Huddle with Maya"), ("Mail", "Re: lunch Thursday? — Inbox"),
    ("Preview", "INV-2026-0042.pdf"), ("Google Chrome", "Pull request #142 · crisp-toast/tessel"),
    ("Google Chrome", "Flights SFO to JFK — Google Flights"), ("Xcode", "tessel — Tiler.swift"),
    ("Terminal", "~/code/tessel — zsh"), ("zoom.us", "Zoom Meeting"), ("Notes", "Groceries"),
    ("Numbers", "Q3 Budget"), ("Spotify", "Spotify Premium"), ("Calendar", "Calendar"),
    ("Finder", "Downloads"), ("Messages", "Mom"),
]
# (query, index of the window it means, kind)
QUERIES = [
    ("design reviews", 0, "words"), ("slack design", 0, "partial"), ("the team's channel for critiquing mockups", 0, "meaning"),
    ("huddle", 1, "words"), ("maya", 1, "partial"), ("the voice call on slack", 1, "meaning"),
    ("lunch thursday", 2, "words"), ("lunch email", 2, "partial"), ("the message about where to eat", 2, "meaning"),
    ("INV-2026-0042", 3, "words"), ("invoice", 3, "partial"), ("the bill I need to pay", 3, "meaning"),
    ("pull request 142", 4, "words"), ("PR", 4, "partial"), ("the code review in the browser", 4, "meaning"),
    ("google flights", 5, "words"), ("flights", 5, "partial"), ("the plane tickets to New York", 5, "meaning"),
    ("Tiler.swift", 6, "words"), ("xcode", 6, "partial"), ("the swift source file I'm editing", 6, "meaning"),
    ("terminal", 7, "words"), ("zsh", 7, "partial"), ("the command line", 7, "meaning"),
    ("zoom meeting", 8, "words"), ("zoom", 8, "partial"), ("the video call", 8, "meaning"),
    ("groceries", 9, "words"), ("notes", 9, "partial"), ("my shopping list", 9, "meaning"),
    ("q3 budget", 10, "words"), ("budget", 10, "partial"), ("the spreadsheet with our spending", 10, "meaning"),
    ("spotify", 11, "words"), ("music", 11, "partial"), ("the song that's playing", 11, "meaning"),
    ("calendar", 12, "words"), ("cal", 12, "partial"), ("my schedule for today", 12, "meaning"),
    ("downloads", 13, "words"), ("finder", 13, "partial"), ("the folder with things I downloaded", 13, "meaning"),
    ("messages mom", 14, "words"), ("mom", 14, "partial"), ("texting my mother", 14, "meaning"),
]

INTENTS = {
    "open": "open or switch to an app",
    "side_by_side": "put two apps side by side",
    "move_workspace": "move a window to another workspace",
    "go_workspace": "go to a workspace",
    "focus_mode": "focus on one window, hide the rest",
    "hide": "hide a window or app",
    "close": "close a window",
    "float": "make a window float",
    "grow": "make a window bigger",
    "shrink": "make a window smaller",
    "tidy": "even out all windows",
    "new_window": "open a new window of an app",
}
COMMANDS = [
    ("open slack", "open"), ("switch to mail", "open"), ("bring up xcode", "open"), ("take me to spotify", "open"),
    ("mail and calendar side by side", "side_by_side"), ("put xcode next to terminal", "side_by_side"),
    ("split screen chrome and notes", "side_by_side"), ("slack on the left, mail on the right", "side_by_side"),
    ("send this to workspace 2", "move_workspace"), ("move slack to the third workspace", "move_workspace"),
    ("put the zoom window in workspace 1", "move_workspace"), ("throw chrome over to workspace two", "move_workspace"),
    ("go to workspace 3", "go_workspace"), ("switch to my second workspace", "go_workspace"),
    ("show workspace one", "go_workspace"), ("jump to desktop 2", "go_workspace"),
    ("focus on xcode", "focus_mode"), ("just this window please", "focus_mode"),
    ("distraction free mode", "focus_mode"), ("only show the notes, nothing else", "focus_mode"),
    ("hide slack", "hide"), ("get messages out of my way", "hide"), ("tuck spotify away", "hide"), ("put this away for later", "hide"),
    ("close this window", "close"), ("close the zoom window", "close"), ("get rid of this window", "close"), ("shut the finder window", "close"),
    ("float this", "float"), ("let calculator float", "float"), ("stop tiling this window", "float"), ("pop this out of the grid", "float"),
    ("make this bigger", "grow"), ("give xcode more room", "grow"), ("widen this window", "grow"), ("more space for mail", "grow"),
    ("make it smaller", "shrink"), ("shrink chrome", "shrink"), ("less space for slack", "shrink"), ("narrower please", "shrink"),
    ("tidy up", "tidy"), ("even everything out", "tidy"), ("reset the layout", "tidy"), ("make all the windows the same size", "tidy"),
    ("new chrome window", "new_window"), ("another terminal", "new_window"), ("open a fresh notes window", "new_window"),
    ("start a new mail window", "new_window"),
]
APPS = ["Slack", "Mail", "Calendar", "Xcode", "Terminal", "Google Chrome", "Notes", "Spotify", "zoom.us", "Messages", "Finder", "Calculator"]
APP_COMMANDS = [(c, a) for c, a in [
    ("open slack", "Slack"), ("switch to mail", "Mail"), ("bring up xcode", "Xcode"), ("take me to spotify", "Spotify"),
    ("move slack to the third workspace", "Slack"), ("put the zoom window in workspace 1", "zoom.us"),
    ("throw chrome over to workspace two", "Google Chrome"), ("focus on xcode", "Xcode"), ("hide slack", "Slack"),
    ("get messages out of my way", "Messages"), ("tuck spotify away", "Spotify"), ("close the zoom window", "zoom.us"),
    ("shut the finder window", "Finder"), ("let calculator float", "Calculator"), ("give xcode more room", "Xcode"),
    ("more space for mail", "Mail"), ("shrink chrome", "Google Chrome"), ("less space for slack", "Slack"),
    ("new chrome window", "Google Chrome"), ("another terminal", "Terminal"), ("open a fresh notes window", "Notes"),
    ("start a new mail window", "Mail"), ("only show the notes, nothing else", "Notes"),
]]
SPACE_COMMANDS = [("send this to workspace 2", "2"), ("move slack to the third workspace", "3"),
                  ("put the zoom window in workspace 1", "1"), ("throw chrome over to workspace two", "2"),
                  ("go to workspace 3", "3"), ("switch to my second workspace", "2"), ("show workspace one", "1"),
                  ("jump to desktop 2", "2")]


def words_match(query, text):
    q = re.findall(r"\w+", query.lower())
    t = re.findall(r"\w+", text.lower())
    return sum(any(w.startswith(x) for w in t) for x in q)


class Model:
    def __init__(self, which):
        base = "/Volumes/Master Storage/AI-Models/system-one"
        self.which = which
        if which == "laya":
            from laya_coreml import load
            m = load(f"{base}/laya-multilingual-coreml-ane", local_files_only=True)
            self.ask = lambda s, q: m.system_one(s, q)["answers"]["q"]["probabilities"]
            self.group = 6  # options per pass: Laya's Neural Engine package has 96 tokens in all
        else:
            sys.path.insert(0, f"{base}/Julia-1")
            from julia import load_model
            m = load_model(f"{base}/Julia-1", device="cpu", strict_encoding=True, max_length=1024, head_length=512)
            self.ask = lambda s, q: m.predict(state=s, questions=q)["answers"]["q"]["probabilities"]
            self.group = 20

    def choose(self, state, instructions, options):
        """The best option key; a tournament of groups when there are more options than fit."""
        keys = list(options)
        while len(keys) > self.group:
            winners = []
            for i in range(0, len(keys), self.group):
                chunk = keys[i:i + self.group]
                if len(chunk) == 1:
                    winners += chunk
                    continue
                p = self.ask(state, {"q": {"type": "choice", "instructions": instructions, "criteria": {k: options[k] for k in chunk}}})
                winners.append(max(p, key=p.get))
            keys = winners
        p = self.ask(state, {"q": {"type": "choice", "instructions": instructions, "criteria": {k: options[k] for k in keys}}})
        return max(p, key=p.get)


def main():
    if sys.argv[1] == "dump":
        import json
        json.dump({"desktop": DESKTOP, "queries": QUERIES, "intents": INTENTS, "commands": COMMANDS}, open(sys.argv[2], "w"))
        return
    m = Model(sys.argv[1])
    windows = {f"w{i}": f"{app}: {title}" for i, (app, title) in enumerate(DESKTOP)}
    times = []
    print(f"\n{m.which}: find a window by describing it ({len(QUERIES)} queries, {len(DESKTOP)} windows)")
    for kind in ("words", "partial", "meaning"):
        rows = [q for q in QUERIES if q[2] == kind]
        right_m = right_b = 0
        for query, target, _ in rows:
            t0 = time.perf_counter()
            pick = m.choose(query, "Which window is the user asking for?", windows)
            times.append((time.perf_counter() - t0) * 1000)
            right_m += pick == f"w{target}"
            scores = [words_match(query, w) for w in windows.values()]
            right_b += scores.index(max(scores)) == target and max(scores) > 0
        print(f"  {kind:8} model {right_m}/{len(rows)}   word matching {right_b}/{len(rows)}")
    right = right_app = right_space = 0
    for command, intent in COMMANDS:
        t0 = time.perf_counter()
        right += m.choose(command, "What does the user want to do with their windows?", INTENTS) == intent
        times.append((time.perf_counter() - t0) * 1000)
    for command, app in APP_COMMANDS:
        right_app += m.choose(command, "Which app does the user mean?", {a: a for a in APPS}) == app
    for command, space in SPACE_COMMANDS:
        right_space += m.choose(command, "Which workspace number?", {"1": "workspace 1, the first", "2": "workspace 2, the second", "3": "workspace 3, the third"}) == space
    print(f"{m.which}: plain-English commands: action {right}/{len(COMMANDS)}, app {right_app}/{len(APP_COMMANDS)}, "
          f"workspace {right_space}/{len(SPACE_COMMANDS)}")
    print(f"  time per answer: median {statistics.median(times):.1f} ms, max {max(times):.1f} ms")


if __name__ == "__main__":
    main()
