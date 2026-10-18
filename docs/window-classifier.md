# The window classifier

Results as of 2026-10-17, measured against Tessel's rules as of main's cbfafb9 (built on branch
`claude/bold-villani-c70383`, in main since 2026-10-18). This is the first part of
Tessel's learning layer ([learning.md](learning.md)): a fast model that decides how each window
should behave the moment it appears. It sits behind **Settings › Learn Where Windows Go**, which
is off by default.

## What it decides

| Class | What it is | What Tessel does |
|---|---|---|
| **document** | a document or main window | tiles |
| **panel** | inspector, palette, Fonts or Colors, Get Info, settings window, a small companion window like a Stickies note | floats where it is |
| **transient** | here and gone: copy or progress windows, splash and first-run windows | floats; never shuffles the tiles |
| **media** | Picture in Picture, a mini player, a call's floating window | floats (floating windows already show in every Workspace) |
| **dialog** | asking you something, including the ones the rules miss | floats, centered once |

## How it decides

- **Inputs:** everything Tessel can read about a window when it appears (`WindowTraits`):
  - Accessibility role and subrole, identifier, and title-bar buttons;
  - resizable, modal, default and cancel buttons, toolbar, tabs, document and main;
  - the window server's level (normal 0, floating panels 3, overlays higher);
  - size as a share of the screen;
  - the app's App Store category;
  - how many windows the app has.

  The **title** is read too, in memory only, and is never written anywhere Tessel keeps.
- **Two views:** the structure, and what the title says. The title view is a UI vocabulary (tool,
  transient, media, dialog and document words), the title's shape (empty, the app's name, a file
  name), and Apple's on-device word vectors (`NLEmbedding`, about 0.02 ms a word). Those are
  projected down to 6 numbers.
- **Model:** a softmax head over both views (`BehaviorModel`, weights in
  `Sources/TesselCore/BehaviorModelWeights.swift`, 45 KB). It's shaped like a System One model:
  the window's state in, one probability per behavior out, nothing generated.
- **Safety floor** (`BehaviorDecision.combine`):
  - the rules decide every window Tessel never asks the classifier about:
    - dialogs;
    - windows that can be neither resized nor minimized, like About boxes (they float
      centered, like dialogs);
    - windows that aren't window-like, like a palette without every title-bar button or a
      helper window;
    - the always-float overlays (the screenshot UI and Tessel itself, which Tessel never
      watches);
  - the model only counts when it's at least 50% sure.

  The old "never tile a window that can't be resized" is gone. Since cbfafb9 the rules tile a
  fixed-size window that can be minimized (Calculator) at its own size, and that's the only kind
  of fixed-size window the classifier is ever asked about.
- **What the classifier owns:** for the windows it's asked about (68 of the 84 labeled ones),
  whether each one tiles, floats where it is (panel, transient or media) or floats centered
  (dialog). Those are:
  - standard windows, including fixed-size ones the rules tile at their own size;
  - "dialogs" that are windows in all but name (Little Arc);
  - resizable windows with every title-bar button (Fonts, Colors).
- **Your corrections** on top: Float/Tile and the double drag still teach `FloatClassifier`, and
  the classifier's call is the starting point those lessons adjust.

### Open System One models, tried in its place

Tyler's direction was an open, on-device System One decision model like Jev. The two that fit
on a Mac were benchmarked on the same 84 windows: Laya-multilingual on the Neural Engine, and
Julia 1. Results are in [system-one-research.md](system-one-research.md).

- **Zero-shot,** they get 38–52% of windows right, against the rules' 80%.
- **Fed to this head as extra inputs,** they add nothing.
- **Cost:** they are 100–400× slower and use about a gigabyte.

So this small classifier keeps their shape (a typed choice with calibrated probabilities and a
confidence gate) without their weight. An earlier JEPA-style encoder was removed: it never
helped either.

## How well it does

- **Data:** 84 windows from 52 apps, collected in the macOS 27 test VM with the `snapshot:` command
  and labeled by hand (`Training/windows.jsonl`). The apps are Apple's own plus Chrome, VS Code,
  iTerm, Claude, 1Password and RustDesk. There are 52 documents, 19 panels, 10 dialogs, 3
  transient windows and no media windows. No one's own windows: the base model is trained only
  on test machines.
- **Labels changed on 2026-10-17** to follow main's cbfafb9, which tiles Calculator (at its own
  size), System Settings and QuickTime. Those four windows went from panel or media to document,
  and so did Digital Color Meter's (a small app's only fixed-size window, like Calculator's).
  The model was retrained on the new labels.
- **Evaluation: leave-one-app-out.** Each app's windows are judged by a model that never saw that
  app, which is what a new user's apps are. Reproduce it with:

  ```bash
  swift run -c release TesselTrain Training/windows.jsonl
  ```

| | Right behavior (5 classes) | Right tile-or-not | Right placement (tile / float / float centered) |
|---|---|---|---|
| Today's rules | 81% (68/84) | 86% (72/84) | 83% (70/84) |
| Model alone | 83% (70/84) | 89% (75/84) | 83% (70/84) |
| **Shipped** (safety floor, model when ≥ 50% sure) | **85% (71/84)** | **92% (77/84)** | **87% (73/84)** |
| Shipped at a more cautious 70% | 82% | 87% | 85% |

**Lower than before.** Until 2026-10-17 this table said 88% and 98% for the shipped decision.
Those numbers were measured against the old rules and labels, under which Calculator, System
Settings and QuickTime always floated. Now the rules tile them and the labels agree, so the
rules do better on their own, and the classifier floats three windows that should tile:
Preview's image window (as before), Digital Color Meter's and, at 51% sure, Activity Monitor's
main window.

**One thing the census didn't record:** whether a fixed-size window's minimize button is
enabled. Since cbfafb9 that decides whether the rules tile such a window at its own size or
center it.
- Calculator's is enabled: main tiles it.
- For the Settings windows of TextEdit, Finder and Safari, the numbers above assume it's enabled
  too. That's the fallback for windows recorded before the trait existed.
- If it isn't, the rules center those three and the classifier is never asked about them:
  - tile-or-not becomes 89% for the rules and 93% shipped;
  - placement becomes 83% for the rules and 85% shipped;
  - the classifier's fixes of TextEdit's and Finder's Settings go away.
- New `snapshot:` records note it (`minimizable`).

Recall per class, for the rules, the model alone, and the shipped decision:

| Class | Rules | Model alone | Shipped |
|---|---|---|---|
| document (52) | 100% | 90% | 94% |
| panel (19) | 37% | 74% | 68% |
| dialog (10) | 90% | 80% | 90% |
| transient (3 examples) | 0% | 33% | 0% |
| media | no examples left | | |

**What changes against the rules** (held out, shipped):
- **Fixed (7):** two of Finder's Get Info windows, Finder's and TextEdit's Settings, Script
  Editor's Library, and both Stickies notes.
- **Broke (5):**
  - Preview's image window, Digital Color Meter's window and Activity Monitor's main window
    float when they should tile. These are the changes that really matter, since a window you
    work in stops tiling.
  - TextEdit's Spelling panel is called a dialog, so it gets centered once.
  - Finder's Connect to Server is called a panel instead of a dialog. It floats either way, which
    already fixes the rules' mistake of tiling it.

**Read these numbers with care:**
- 84 windows is small. A difference of 5 points is about 4 windows, so it's promising, not proven.
- The 50% threshold was picked on these same results, which flatters it a little.
- There are too few transient windows to learn anything from, and no media windows left: the
  model barely recognizes either, and the rules decide there.
- Every window came from one macOS version. The VMs for 14, 15 and 26 exist and run the same
  `snapshot:` command.

## How fast

- **Decision**, from the title's word vectors through the model: **about 0.045 ms** (measured over
  16,800 decisions in the trainer), and 0.09 ms in the app in the VM. The word vectors load once
  in about 30 ms and add about 5 MB.
- **Reading the traits** over Accessibility: **1.0–1.6 ms a window** in the VM, once per new window,
  on the app's own queue (never the main thread), inside the read Tessel already does.
- **Total:** a new window is decided in about 2 ms off the main thread, inside the "few
  milliseconds" budget.

## How Tyler can see it on his own windows

1. Install the branch (`./scripts/build.sh --install`) and turn on **Settings › Learn Where Windows Go**.
2. Open **Settings › What Tessel Learned › How Tessel Sees Your Windows…**. Every open window is
   listed with Tessel's call, how sure it is, what the old rules would have done, and what that
   means ("tiles", "floats", "floats, centered"). Windows where Tessel goes against the old rules
   come first, marked ◆. The footer shows the measured read and decision times per window.
   **Look Again** refreshes.
3. When it's wrong, float or tile the window from the menu and Tessel learns from that. Telling
   us which windows it got wrong is how the labeled set grows.

For agents: the `classes` command shows the panel, and `classify` writes the same report, without
titles, to `~/Library/Application Support/Tessel/classes.json`.

Live in the VM with the first weights (2026-10-16, tiling on, learning on): Finder's Get Info windows, both Stickies notes and
Script Editor's Library floated the moment they opened, while Finder, TextEdit, Script Editor and
Voice Memos documents tiled. Under the old rules all of these would have tiled.

## Next

1. **More labeled windows.** Run `snapshot:` in the 14, 15 and 26 VMs, and in apps people
   actually complain about: Zoom, Slack, Teams, Discord, JetBrains, Adobe, Steam, Electron
   pop-ups. Aim for 300+ windows with at least 20 per class before trusting the per-class
   numbers. Re-snapshot the 27 VM's fixed-size windows too, now that `minimizable` is recorded.
2. **Media and transient:** capture Picture in Picture from browsers, call windows, and copy and
   install progress on slower disks.
3. **A System One model again,** fine-tuned on windows rather than zero-shot, once there are
   several hundred labeled windows: see system-one-research.md.
4. **Tyler's own windows:** use the panel for a few days and note every ◆ that's wrong.
