# The window classifier

Results as of 2026-10-16 (branch `claude/bold-villani-c70383`). This is the first part of
Tessel's learning layer ([learning.md](learning.md)): a fast model that decides how each window
should behave the moment it appears. It sits behind **Settings › Learn Where Windows Go**, which
is off by default.

## What it decides

| Class | What it is | What Tessel does |
|---|---|---|
| **document** | a document or main window | tiles |
| **panel** | inspector, palette, Fonts or Colors, Get Info, settings window, a small companion window like a Stickies note or Calculator | floats where it is |
| **transient** | here and gone: copy or progress windows, splash and first-run windows | floats; never shuffles the tiles |
| **media** | Picture in Picture, a movie or camera window, a mini player | floats (floating windows already show in every Workspace) |
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
  `Sources/TesselCore/BehaviorModelWeights.swift`, 47 KB).
- **Safety floor** (`BehaviorDecision.combine`):
  - a dialog by the old rules is always a dialog;
  - the model only counts when it's at least 50% sure;
  - it never tiles a window that can't be resized, or one from an app Tessel always floats
    (System Settings, QuickTime, Calculator…).
- **Your corrections** on top: Float/Tile and the double drag still teach `FloatClassifier`, and
  the classifier's call is the starting point those lessons adjust.

### The JEPA-style part, honestly

The trainer includes a JEPA-style encoder: two linear encoders, one per view. Each learns to
predict the other view's embedding against a slowly-moving target copy, with VICReg-style
variance and covariance terms so it can't collapse. With 84 labeled windows it **doesn't help**:

- feeding only that embedding to the head scores 58–61%;
- adding it next to the views scores no better than the views alone, and is noisier.

So the shipped head reads the two views directly (the encoder is off in the shipped weights).

JEPA's real strength is learning *without labels*, and every Mac has plenty of unlabeled
windows. The next experiment is to train the encoder on each Mac's own windows, privately and
in idle time, and to use its embedding for your corrections: "float this inspector" would then
carry over to inspectors in other apps. It ships only if it beats this head on held-out apps.

## How well it does

- **Data:** 84 windows from 52 apps, collected in the macOS 27 test VM with the `snapshot:` command
  and labeled by hand (`Training/windows.jsonl`). The apps are Apple's own plus Chrome, VS Code,
  iTerm, Claude, 1Password and RustDesk. There are 47 documents, 22 panels, 10 dialogs, 3
  transient and 2 media windows. No one's own windows: the base model is trained only on test
  machines.
- **Evaluation: leave-one-app-out.** Each app's windows are judged by a model that never saw that
  app, which is what a new user's apps are. Reproduce it with:

  ```bash
  swift run -c release TesselTrain Training/windows.jsonl
  ```

| | Right behavior (5 classes) | Right tile-or-not |
|---|---|---|
| Today's rules | 80% (67/84) | 88% (74/84) |
| Model alone (plain head, any seed) | 85% (71/84) | 92–93% |
| **Shipped** (safety floor, model when ≥ 50% sure) | **87% (73/84)** | **96% (81/84)** |
| Shipped at a more cautious 70% | 85% | 92% |

Recall per class, for the rules, the model alone, and the shipped decision:

| Class | Rules | Model alone | Shipped |
|---|---|---|---|
| document | 98% | 94% | 96% |
| panel | 55% | 82% | 82% |
| dialog | 90% | 80% | 90% |
| transient (3 examples) | 0% | 33% | 33% |
| media (2 examples) | 0% | 0% | 0% |

**What changes against the rules** (held out, shipped):
- **Fixed (8):** Finder's three Get Info windows, Disk Utility's Info, Script Editor's Library,
  both Stickies notes, and Chrome's first-run prompt.
- **Broke (3):**
  - Preview's image window now floats, the one change that really matters, since a document
    window stops tiling.
  - TextEdit's Spelling panel is called a dialog, so it gets centered once.
  - Finder's Connect to Server is called a panel instead of a dialog. It floats either way, which
    already fixes the rules' mistake of tiling it.

**Read these numbers with care:**
- 84 windows is small. A difference of 5 points is about 4 windows, so it's promising, not proven.
- The 50% threshold and the plain-versus-JEPA choice were picked on these same results, which
  flatters them a little.
- There are too few transient and media windows to learn anything from: the model barely
  recognizes them, and the safety floor keeps the rules there.
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

Live in the VM (tiling on, learning on): Finder's Get Info windows, both Stickies notes and
Script Editor's Library floated the moment they opened, while Finder, TextEdit, Script Editor and
Voice Memos documents tiled. Under the old rules all of these would have tiled.

## Next

1. **More labeled windows.** Run `snapshot:` in the 14, 15 and 26 VMs, and in apps people
   actually complain about: Zoom, Slack, Teams, Discord, JetBrains, Adobe, Steam, Electron
   pop-ups. Aim for 300+ windows with at least 20 per class before trusting the per-class
   numbers.
2. **Media and transient:** capture Picture in Picture from browsers, call windows, and copy and
   install progress on slower disks.
3. **JEPA on unlabeled windows,** trained on each Mac in idle time as described above, plus
   few-shot corrections in its embedding.
4. **Tyler's own windows:** use the panel for a few days and note every ◆ that's wrong.
