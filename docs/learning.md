# Learning: the window manager you never configure

Design, 2026-10-16. Tessel's pitch is that it learns how you work: no account, and everything it
learns stays on your Mac. This doc covers how that works and in what order to build it. It is
grounded in the code as of `b554a7d`. Item 1 (float or tile) is prototyped in this branch behind a
default that is off. Everything else here is a plan.

**The short version**

- Tessel's rules stay in charge. Small models, trained on this Mac from Tessel's own window events,
  adjust the rules only where you've shown it they're wrong.
- Every model starts as counting statistics. Bandits and small classifiers come next. A JEPA-style
  embedding predictor under 1 MB comes last, and only if it beats counting on your own history.
- Apple's Foundation Models framework is an optional extra for language only (names, topics,
  typed commands) on macOS 26 and later. It can't learn from you, it needs Apple Intelligence, and
  it's far too slow for per-window decisions.
- Learning adds no network calls. A unit test (`NothingLeavesThisMac`) fails if any Swift file
  besides `Licensing.swift` starts talking to the network.

Build order: **1 float or tile → 2 layout memory → 3 Auto Workspaces (the headline) → 4 Predictive
Summon → 5 Autopilot (opt-in)**. Items 1 and 2 are about retention: Tessel stops doing the thing
that annoys you. Item 3 is what makes people talk about it.

---

## What Tessel decides today, and what it already remembers

Every decision is a hand-written rule:

| Decision | Where | Rule today |
|---|---|---|
| Tile or float | `Tiler.readWindows` and `consider` ([Tiler.swift:338](../Sources/Tessel/Tiler.swift:338), [:498](../Sources/Tessel/Tiler.swift:498)) | A window tiles if it's `AXStandardWindow`, resizable, not minimized, not full screen, and not a dialog (`Dialogs.isDialog`). Eight apps always float (`floatingApps`, [Tiler.swift:65](../Sources/Tessel/Tiler.swift:65)). A non-standard window that answers a Summon open is "adopted" and tiles. `userFloating` ([Tiler.swift:86](../Sources/Tessel/Tiler.swift:86)) is checked but nothing ever adds to it, so there is no way to float a window yourself. |
| Where a new window goes | `Tiler.insert` ([Tiler.swift:637](../Sources/Tessel/Tiler.swift:637)) → `Layout.insert(near:maxColumns:)` ([Layout.swift:89](../Sources/TesselCore/Layout.swift:89)) | The Workspace you're viewing (`saved?.space ?? currentSpace`, [Tiler.swift:646](../Sources/Tessel/Tiler.swift:646)). It gets its own column right of the focused window until `maxColumns` (width / 800, at most 4), then stacks into the column with the fewest windows, at an average share. |
| A lone window's size | `Layout.singleScale` / `singleHeight` / `singleOwner` ([Layout.swift:42](../Sources/TesselCore/Layout.swift:42)) | Centered at 16:10, 0.6 of the screen width. A shape you drag to is kept only for that one window (`singleOwner`). App-chosen sizes were removed on purpose in e9d3bac (`tileSizes` and `appSizes` are deleted at startup). |
| Summon's order | `Launcher.update` ([Launcher.swift:182](../Sources/Tessel/Launcher.swift:182)) | `launcherUses` counts opens per path. With an empty query: apps by count. With a query: `Fuzzy.score + min(uses, 40) × 25`. This is frequency, not frecency: counts never decay and ignore context (time, Workspace, what's open). |
| Workspace for a focused window elsewhere | `ForeignFocus.decide` ([Activation.swift](../Sources/TesselCore/Activation.swift), called at [Tiler.swift:948](../Sources/Tessel/Tiler.swift:948)) | Summon brings it here, a Dock click goes there, and a focus macOS hands over by itself while settling stays put. |

What's saved in `UserDefaults` (`com.tyleryouens.tessel`) today, all on this Mac:

| Key | What | Learned? |
|---|---|---|
| `layouts` | Each Workspace's `Layout` as JSON, keyed `"space|displayUUID"`, written by `persist()` ([Tiler.swift:1380](../Sources/Tessel/Tiler.swift:1380)) | No: it's where your windows are now, keyed by window number, which dies with the window |
| `placement` | window number → `"space|displayUUID"` | No: current state |
| `adopted` | window numbers tiled because they answered Summon | No |
| `launcherUses` | path → open count (apps and files) | Yes, frequency only |
| `currentSpace`, `useAllDisplays`, `spaceKeys`, `keymap`, `loginItemConfigured` | settings | No |
| `license`, `trialStarted` (also in the Keychain), `revocationChecked` | licensing | No |

So the "layout memory" Tessel has today is relaunch memory: `Layout.restore(_:from:)` puts a
window that's still open back exactly where it was. Once a window closes, Tessel forgets everything
about it. Learning means remembering things about kinds of windows, apps and situations instead of
window numbers.

---

## Principles (all five items)

1. **The rules are the cold start.** With nothing learned, Tessel behaves exactly as it does today.
   Every model's output is "the rule, unless there's enough evidence otherwise".
2. **Learn from what you do, not from what you put up with.** A correction (floating a window,
   sending it back, undoing a move) is strong evidence. A window you left where the rules put it
   is not: most people never find the command that would have changed it.
3. **A guess never moves a window that's already in place.** Learned behavior applies to windows
   as they arrive, and to arrangements as they form. The one exception is Autopilot, which is
   opt-in.
4. **Everything automatic says what it did, and one key undoes it.** The undo is also the label.
5. **Decide fast and off the main thread.** A decision is under 1 ms. It runs where Tessel already
   reads the window: the app's own serial queue (`AppHandle.queue`), or a learning queue that
   precomputes the answer before the main thread asks. Training runs only when the Mac is idle.
6. **Local, inspectable, erasable.** Plain JSON Lines files in one folder, readable only by you and
   left out of backups. Window titles, keystrokes and file names are never written down. Settings
   has "Reset What Tessel Learned".

## Shared machinery

**Storage.** Everything lives in `~/Library/Application Support/Tessel/Learning/` (next to
`state.json`, which `dump` writes). The folder is created `0700`, files are `0600`, and the folder
is marked `isExcludedFromBackup`. That keeps "stays on this Mac" literally true: it isn't in Time
Machine, and Application Support never goes to iCloud. The cost is that a new Mac starts learning
from scratch, which is fine.

**Event logs.** `EventLog<Event>` ([EventLog.swift](../Sources/TesselCore/EventLog.swift), built
in the prototype) writes one JSON object per line, so anyone can open the file in TextEdit and read
every word. When the current file would pass `maxBytes`, it becomes `name.1.jsonl` and the older
`.1` is dropped, so a stream never takes more than two files. Events older than `maxAge` are left
out when read and erased by `prune()` at startup. A line cut off mid-write is skipped. The log is
synchronous and not thread-safe: `Learning` calls it from one utility-QoS serial queue.

| Stream | Item | Written when | Expected volume | Cap | Retention |
|---|---|---|---|---|---|
| `float.jsonl` | 1 | a correction, or a close that counts as evidence | a few KB/day | 2 × 1 MB | 90 days |
| `arrange.jsonl` | 2 | an arrangement you made and then kept for 30 s | ~5–20 KB/day | 2 × 1 MB | 90 days |
| `focus.jsonl` | 3, 4 | focus leaves a window after at least 2 s | ~50–100 KB/day | 2 × 2 MB | 30 days |
| `place.jsonl` | 3 | an Auto Workspace suggestion or move, and what you did about it | a few KB/day | 2 × 512 KB | 90 days |
| `summon.jsonl` | 4 | Summon opens an app (apps only: no files, no web, no query text) | a few KB/day | 2 × 512 KB | 90 days |
| `autopilot.jsonl` | 5 | Autopilot acts, and whether you undid it | a few KB/day | 2 × 512 KB | 90 days |
| `models/` | all | snapshots of counts, bandit posteriors and weights | — | 2 MB total, embeddings < 1 MB | until reset |

That's at most about 13 MB, and typically under 1 MB. Logs are the training set. Models are
rebuilt from them at startup (the prototype does this: `FloatClassifier.replay`) or loaded from a
snapshot once replay gets slow (above about 50 ms).

**What an event may contain:** bundle IDs, Accessibility roles and subroles, which title-bar buttons
a window has, its size in points and as a share of the screen, the *kind* of title (empty, the app's
name, a utility word, anything else; see `TitleKind`), Workspace index, a display class (size in
points, not its name or serial), times rounded to 0.1 s, and Tessel's own choices.
**What it never contains:** window titles, file paths, URLs, typed text, key codes, screenshots,
user names, or anything that could identify the Mac.

**The `Learning` object** ([Learning.swift](../Sources/Tessel/Learning.swift), in the prototype)
owns the models behind an `OSAllocatedUnfairLock`, the IO queue, and the per-window decisions.
`Tiler.start()` and `stop()` start and stop it. Reads take the lock for well under a microsecond.
Anything slow (disk, replay, training) runs on its queue.

**Idle-time training** (from item 2 on; the counting models need none). Tessel trains only when all
of these hold:
- no keyboard or mouse input for 2 minutes (`CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)`, the same idle clock the mac-mini skill reads as `HIDIdleTime`);
- on AC power (`IOPSCopyPowerSourcesInfo`) and not in Low Power Mode;
- `ProcessInfo.thermalState == .nominal`;
- at `.background` QoS, with at most 30 s of CPU a day and a 50 MB peak.

Training stops the moment input arrives. Nothing trains while the Mac is asleep, and nothing is
scheduled with launchd.

**The model ladder.** Each item starts at step 1 and moves up only when an on-device evaluation
says it should:
1. **Counting statistics**: decayed counts with empirical-Bayes backoff (kind → app → rule). These
   are explainable in a sentence and correct from the first event.
2. **Bandits and small classifiers**: Thompson sampling where Tessel has to choose whether to act,
   and logistic regression over hashed features (4,096 weights, 16 KB) where kinds of window need
   to generalize across apps.
3. **A JEPA-style embedding predictor** (its own section below), < 1 MB, trained in idle time.
   It's for cold start (new apps, new situations) and for Auto Workspaces.

**Evaluation stays on the Mac too.** Before a model level replaces the one below it, Tessel replays
the last 14 days of the log through both and compares how often each would have agreed with what you
did, such as your corrections and undos. It switches only on a clear win (5 points or more). The
numbers can be shown in the "What Tessel Learned" window. They are never sent anywhere.

---

## 1. Float or tile (prototyped)

The most common complaint about tiling window managers is "it tiled a window that should
float". Tessel's answer today is a hard-coded list of eight apps plus the dialog rules, and the
launch checklist lists per-app rules as a known gap. Instead of adding a rules UI, Tessel learns
them from the moment you correct it.

### How you correct it (the labels)

| Gesture | Label | Status |
|---|---|---|
| **Float / Tile** on the focused window: the `float` command, and the menu's "Float This Window" / "Tile This Window" | strong, either way | prototyped |
| **Drag a tiled window out of its tile twice within 10 s.** The first drop glides back as always. The second time Tessel stops fighting you: the window floats where you dropped it. | strong, toward float | prototyped (`userDropped`, [Tiler.swift:1170](../Sources/Tessel/Tiler.swift:1170)) |
| A shortcut for Float / Tile (left ⌘⇧T, free in `Keymap`) | strong | to do: needs a `Command`, a Cheat Sheet line and an onboarding mention |
| Dragging a floating window onto a tile, so it takes that spot | strong, toward tile | to do |
| A tiled window that closes within 3 s of appearing (splash screens, progress windows, quick pop-ups) | weak hint toward float (0.25) | prototyped |
| A window placed by what was learned, then left that way for over a minute | weak confirmation (0.25): the lesson stays fresh | prototyped |
| A window the rules placed that you left alone | **nothing**: tolerating isn't consent | by design |

### Features (`FloatFeatures`, [FloatLearning.swift](../Sources/TesselCore/FloatLearning.swift))

These are read once, the first time a window that could tile shows up, on its app's queue,
inside the same `readWindows` pass Tessel already makes:

- bundle ID; Accessibility subrole; resizable;
- title-bar buttons: close, minimize, zoom, full screen (`kAXFullScreenButtonAttribute`);
- size in points, and its share of the display's usable area (small under 12%, medium under
  40%, large otherwise);
- `TitleKind`: empty / the app's name / a utility word ("Settings", "Inspector", "Downloads",
  "Picture in Picture", …) / anything else. The title is classified in memory and never written
  down. The word list is English only for now; Foundation Models can do this in any language
  later.
- native tabs;
- **min/max size.** macOS has no Accessibility attribute for a window's minimum or maximum size
  (`AXMinValue` / `AXMaxValue` are for sliders), so Tessel finds out by asking. When
  `Animator.onSettled` reports a frame that doesn't match the tile, the window has a limit, and
  `sizeLimited` is set ([Tiler.swift:2078](../Sources/Tessel/Tiler.swift:2078)). It's only known
  after the first tile, so it's logged for the step-2 model but isn't part of the step-1 kind.
- **lifetime**, taken at close, which is a label rather than a feature.

A window's **kind** is `app | subrole (or "std") | buttons | size class | title kind`, for example
`com.apple.finder|std|15|l|document`. It is coarse on purpose, so a lesson carries over to the
next window like it.

### Event log schema (`float.jsonl`)

```json
{"choice":"float","features":{"app":"com.apple.finder","buttons":1,"height":420,"resizable":true,"screenShare":0.048,"sizeLimited":false,"subrole":"AXStandardWindow","tabs":false,"title":"utility","width":300},"gesture":"toggle","kind":"corrected","time":1792195200.1}
{"choice":"float","features":{…},"kind":"closed","lifetime":412.3,"source":"learned","time":1792195612.4}
```

Only events that carry evidence are written (`FloatClassifier.evidence(in:)`): corrections,
fleeting tiled windows, and learned choices you lived with. A close the rules decided and you
ignored isn't kept. That keeps the log to a few KB a day, so a lesson isn't rotated out of the
2 MB cap long before 90 days.

### Step 1, as built: counting with backoff (`FloatClassifier`)

For each kind and each app, Tessel keeps decayed evidence for float and for tile (half-life 180
days), plus the direction and time of your latest correction. A new window gets:

```
prior   = 0.9 if the rule says float, else 0.1
p_app   = (float_app  + 2.0 × prior) / (total_app  + 2.0)
p       = (float_kind + 0.5 × p_app) / (total_kind + 0.5)

float  if rule = tile  and p ≥ 0.75 and your latest correction (of the kind, else the app) = float
tile   if rule = float and p ≤ 0.25 and your latest correction (of the kind, else the app) = tile
else   the rule
```

How it behaves (each line is a unit test in
[FloatLearningTests.swift](../Tests/TesselCoreTests/FloatLearningTests.swift)):

- With nothing learned, the rules decide.
- One correction of a new kind is enough: the next window of that kind follows (p = 0.8).
- Other kinds in the same app, and other apps, are left alone (p = 0.4).
- Float eight different kinds in one app and new kinds of that app float too: an app-wide rule
  you never had to write.
- It never goes against your latest correction. After five floats and then one tile, it tiles,
  even though p is still above 0.75.
- If you change your mind back and forth, it falls back to the rules.
- Windows the rules float (QuickTime, Simulator, System Settings, …) can be taught to tile.
- Hints alone never override the rules, even 200 of them.
- Thirty windows you left tiled don't hold back a correction.
- A lesson you never use fades after about two months. One you live with stays.
- A decision is two dictionary lookups and some arithmetic: about 0.5 µs. The test allows 10 µs.

What can never be learned (hard rules, unchanged): dialogs, sheets, Open/Save panels (`Dialogs`);
minimized, full screen, and non-resizable windows; hidden apps; windows on an unmanaged display;
apps an agent has `leave-app`'d; Tessel's own windows.

### Step 2: logistic regression over hashed features

Once there are 20 or more corrections across 3 or more apps, add an online logistic regression
over hashed features: subrole, buttons, size class × title kind, `sizeLimited`, tabs, and bigrams of
those. It has 4,096 weights (16 KB), trained by SGD with L2 regularization on each correction and
replayed at startup. Its output replaces the fixed `prior`, so "small, non-zoomable windows titled
'Info' float" carries over to an app you've never corrected. The latest-correction gate still
applies, now at the "similar kinds" level. Ship it only if the replay evaluation says so.

### Step 3: embeddings for cold start

An app you've never used tiled or floated borrows from the nearest apps in the JEPA embedding
space (below). This affects `prior` only, never the gate.

### Budgets

- **Decision:** about 0.5 µs, on the app's queue, inside `readWindows`, once per window. It's cached
  in `Learning` for the window's life, so a window never flips while it's open. Reading the extra
  features costs four or five more Accessibility calls once per new window, also on the app's queue.
- **Main thread:** one lock read per window per scan in `consider` (`tiles`,
  [Tiler.swift:589](../Sources/Tessel/Tiler.swift:589)).
- **Memory:** about 200 bytes per kind, so under 100 KB for a heavy user. The log is at most 2 MB.
- **Startup:** a full 2 MB log (about 7,000 events, far more than a typical one) reads in about
  50 ms and replays in 4 ms on the learning queue, measured in a debug build. Window decisions wait
  for it (`DispatchGroup`, up to 1 s, on app queues only), so a window taught to float doesn't tile
  after a relaunch.

### Failing safe

- Off (the default) means no files, no logging, no extra Accessibility reads, and behavior
  identical to today's. `tiles` returns the rule untouched.
- A guess never moves a window that's already tiled. A window that was tiled before a relaunch or
  a pause stays tiled, and a window answering a Summon open follows the rules
  (`Learning.overrule`).
- Your own choice for a window survives a pause and resume.
- If the log can't be read or written, Tessel decides by the rules and says so in the log (subsystem
  `com.tyleryouens.tessel`, category `learning`).
- Floating never moves anything: the window stays exactly where it is and the tiles close the gap.

### Trying the prototype

```bash
defaults write com.tyleryouens.tessel learnFloating -bool YES
```

Then pause and resume tiling (the setting is read when tiling starts). Float a window from the menu
(**Float This Window**), or post the `float` command, or drag it out of its tile twice. `dump`
writes a `learning` section into `state.json` with every window's kind and choice and the lessons
so far. `learning-reset` (or **Settings › Reset What Tessel Learned**) forgets everything. The
log is `~/Library/Application Support/Tessel/Learning/float.jsonl`.

**Not yet tested live.** The prototype builds and its unit tests pass (`swift test`: 116 tests).
It hasn't been run against real windows. That should happen in the Tart VM (`vm.sh install-tessel`)
once nothing else is using the VM's 4 GB.

---

## 2. Layout memory

**Today.** Tessel remembers each layout as window numbers (`layouts`) and restores windows that
are still open (`Layout.restore`). When a window closes, its slot is gone. A new window always
lands right of the focused one at an average share, and a lone window always starts at 16:10.
People rebuild the same arrangement every morning: Xcode wide on the left with Simulator narrow on
the right, or Mail stacked over Messages.

**Remember arrangements per context.**
- **Context key:** the display class (usable size in points, like `2560x1415`; the display UUID
  is a tie-breaker), the set of apps in the layout (sorted bundle IDs, up to 8), and the
  Workspace. Lookups back off from `space+display+apps` to `display+apps` to `class+apps`.
- **Template:** the layout with window numbers replaced by slots (`bundleID#n`, where n numbers the
  app's windows in column order), keeping column order, stacks, column weights and stack weights.
- **Lone-window shape:** `singleScale` and `singleHeight` per `bundleID × display class`, learned
  only from your own `adopt` (drag), grow and shrink, never from the app's own size. That keeps
  e9d3bac's decision (Tessel ignores app-chosen sizes) intact.

**Recording.** After a change you make (move, grow or shrink, drag-resize, swap, Tidy), once the
layout has stayed the same for 30 s. Tidy (⌘⇧0) is recorded too: even shares become the preference
for that context. Each context keeps up to 3 variants with their total dwell time. The model is
the variant with the most decayed dwell (half-life 30 days), which is counting statistics again.

`arrange.jsonl`:
`{"time":…,"space":0,"display":"2560x1415","apps":["com.apple.dt.Xcode","com.apple.iphonesimulator"],"columns":[{"slots":["com.apple.dt.Xcode#0"],"weight":0.68,"weights":[1]},{"slots":["com.apple.iphonesimulator#0"],"weight":0.32,"weights":[1]}],"dwell":1800}`

**Applying it, using the existing restore.** When a window arrives in `Tiler.insert`, the learning
queue has already worked out the template for "this layout plus one window of app X". It
precomputes the likely next arrivals each time `persist()` runs, so `insert` does a single
dictionary read. Tessel builds a synthetic `saved: Layout` by mapping template slots to the windows
actually there (same bundle ID; among equals, the most recently focused), then calls
`layout.restore(newID, from: synthetic)`. That's the same `Layout.restore` that already has
permutation tests: the arriving window takes its remembered stack, position and shares. The other
windows keep their order. If every slot maps exactly, the column weights come from the template.
If the mapping is ambiguous, `Layout.insert` runs as today.

**Cold start.** No template, so today's insert. **Budget:** precompute about 50 µs on the learning
queue per change; the main thread does one dictionary read. **Memory:** at most 500 contexts × 3
variants, about 150 KB. **Failing safe:** it only places an arriving window and never reshuffles
existing ones. Tidy and the arrow keys work as always. A variant you undo within 30 s (by moving
the new window again) loses its dwell.

---

## 3. Auto Workspaces (the headline)

**Today.** A new window lands in the Workspace you're viewing ([Tiler.swift:646](../Sources/Tessel/Tiler.swift:646)).
Summon and Dock clicks deliberately bring windows here (`prepareForOpening`, `expectWindow`). If
you keep Mail and Messages in Workspace 2, every new Mail window still opens in Workspace 1 and you
send it over with ⌘⇧ + the Workspace 2 key.

**The goal:** a NEW window that Tessel didn't open for you goes to the Workspace it belongs in,
learned from which apps you use together where.

**Which windows qualify.** Only new windows. That means not open at launch, not in
`savedPlacement`, not a tab taking over a tile, not filling a placeholder, not answering Summon or
a Dock click (`summonedArrival`, `expectedArrival`, `dockClick`), and not on an unmanaged display.
Existing windows are never moved. Summon stays "the one that brings things to you".

**Signals** (`focus.jsonl`, one line when focus leaves a window after at least 2 s):
`{"time":…,"app":"com.apple.mail","space":1,"display":"2560x1415","dwell":340}`. These come from
`focusChanged` ([Tiler.swift:932](../Sources/Tessel/Tiler.swift:932)), which already maintains
`lastFocused[space]`. Dwell stops counting after 60 s with no input, so leaving Mail focused
overnight doesn't count as 8 hours of Mail. Strong labels come from what you do with new windows:
sending one with ⌘⇧ + Workspace key within 30 s of it opening, or undoing an automatic move.

**Model, step 1: counting.**
- `P(space | app)`: Dirichlet-smoothed, decayed focus dwell (half-life 14 days, because what a
  Workspace is for drifts).
- Co-occurrence: a PMI score between the app and the apps currently in each Workspace, counted over
  "Workspace sessions" (the time between switches).
- `score(s) = log P(s | app) + 0.5 × Σ PMI(app, b) over apps b in s`, then softmax.

**Step 2: a bandit decides when to act**, per app, with three actions: nothing, suggest, move.
Thompson sampling on Beta(kept, undone) for moves, and Beta(accepted, ignored) for suggestions.
Exploration happens only through suggestions, which cost you nothing, never through moves.

**The tiers, matching the brief:**
- **Not sure:** today's behavior.
- **Low confidence: a placeholder first, nothing moves.** The window opens here as it always has.
  The Workspace badge shows the frosted placeholder card (the `PlaceholderTile` look, with the
  app's icon) over Workspace 2: "Mail goes in Workspace 2? ⌘⇧2". Pressing the existing send key
  moves it and counts as a yes; ignoring it counts as a weak no. Tessel needs p ≥ 0.6 and 30
  minutes of dwell for the app.
- **Confident: it goes there directly.** This needs p ≥ 0.9 and a moves-kept rate of 0.9 or
  better, earned through accepted suggestions. The window is placed in Workspace 2 (parked, like
  any window there). The badge says "Mail opened in Workspace 2". **One key undoes it:** ⌘⇧ + the
  key of the Workspace you're in, which today is a no-op (`send` ignores the current Workspace),
  brings the window here next to the focused one, and counts as a strong no.

**One trap to handle.** The app usually focuses its new window. That goes through
`ForeignFocus.decide` with the window in another Workspace, and today's answer is `.goThere`,
which would switch you to Workspace 2 and defeat the point. `ForeignFocus.decide` needs a
`placedForYou` input that returns `.stay` for a few seconds. It's a pure function in TesselCore,
so that gets a unit test like the others.

`place.jsonl`: `{"time":…,"app":"com.apple.mail","from":0,"to":1,"p":0.93,"action":"move","outcome":"kept"}`

**Cold start.** Nothing at all until there are 2 hours of focus dwell across at least 2 Workspaces,
then suggestions only, for 3 days. Step 3 (embeddings) helps a brand-new app by borrowing the
Workspace of apps that play the same role.

**Budget.** Scores are recomputed on the learning queue on each focus change (3 Workspaces × about
30 apps: microseconds). `insert` reads a cached `[bundleID: (space, p, action)]`.

**Failing safe.**
- It never touches existing windows.
- It never acts on a window you asked for.
- It never moves a window into a Workspace you can't reach (Workspace keys not set up).
- It never acts while you're dragging.
- Two undos in a row for an app pause that app's moves for a week.
- A global "Place New Windows for Me" switch sits in Settings, on by default once item 3 ships.

**Foundation Models helps** here by grouping windows by what their titles are about (see that
section): all the windows of one project together.

---

## 4. Predictive Summon

**Today.** `launcherUses[path] += 1` on every open ([Launcher.swift:275](../Sources/Tessel/Launcher.swift:275)).
The empty-query list is sorted by that count, and typed queries add `min(uses, 40) × 25` to the
fuzzy score ([Launcher.swift:190](../Sources/Tessel/Launcher.swift:190)). The counts never decay
and ignore context. The keys are file paths too, so opened files' paths sit in the preferences
plist; that's local, but worth knowing.

**Context-aware ranking.** The context is:
- the Workspace and the apps in it;
- the focused app;
- the hour (6 buckets) and weekday or weekend;
- the display setup (a laptop alone, or docked);
- whether the app is running;
- how long since you last opened it.

The step-1 model is naive Bayes over decayed counts (half-life 30 days):
`log P(app) + Σ log P(context feature | app)` with Laplace smoothing. Its output replaces the
`min(uses, 40) × 25` term with a bonus capped at the same 1,000, so a typed match always beats a
prediction, exactly as today. `launcherUses` seeds the counts once, so nobody's list changes order
overnight.

**Signals** (`summon.jsonl`): `{"time":…,"picked":"com.apple.dt.Xcode","rank":2,"shown":["…","…","…"],"queryLength":2,"space":0,"focused":"com.apple.Terminal","hour":3}`.
These are apps only. Files, web searches and the query text are never logged. Rows shown above the
pick are mild negatives (a cascade click model).

**The bandit, step 2,** only reorders the empty-query list (⇧Space then nothing typed, where
prediction matters most): Thompson sampling among the top 5 when their scores are close. The top
row is never chosen by exploration.

**Pre-launch, in two tiers:**
- **Warm, on by default with item 4.** When Summon opens with an empty query and the top prediction
  has p ≥ 0.6 and isn't running, Tessel reads that app's main executable and frameworks into the
  file cache (`fcntl(F_RDADVISE)` on a background queue). No process starts, there are no side
  effects, and a cold launch becomes a warm one.
- **Launch, opt-in per app.** Start the predicted app hidden (`NSWorkspace.OpenConfiguration`:
  `activates = false`, `hides = true`). This needs p ≥ 0.9 and 20 or more picks in that context,
  with one app at a time and never on battery. `expectWindow` ([Tiler.swift:1858](../Sources/Tessel/Tiler.swift:1858))
  currently refuses a hidden app ("nothing new is coming"), so a pick must unhide it and then hold
  the placeholder. On a 16 GB Mac a pre-launched app costs 100 MB to 1 GB, so this stays off by
  default.

**Budget.** Context scores are precomputed on the learning queue on each focus or Workspace change.
`Launcher.update` reads a `[path: bonus]` dictionary. **Cold start:** today's counts. **Failing
safe:** a fuzzy match dominates, the bonus is capped, nothing is ever hidden, and pre-launch never
starts an app you haven't opened yourself at least 20 times.

---

## 5. Autopilot (opt-in)

This is a Settings switch, off by default. It's the only item that moves windows that are already
in place, so it says so every time and backs off when you undo it.

**Grow the window you're typing in.**
- **Signal:** `HotkeyTap` already sees every keyDown on its own high-priority thread
  ([HotkeyTap.swift:57](../Sources/Tessel/HotkeyTap.swift:57)). It adds one to a counter for each
  key pressed without ⌘ or ⌃. It never records which key: no key codes, no text.
- **"Typing":** 40 or more keys in the last 20 s in the same window.
- **Action:** at the next pause of 1.2 s with no keys, `Layout.resize(id, by: 0.08)` (the same
  step as ⌘⇧+), up to 0.6 of the width or the share you settled on for that app. It happens at most
  once every 2 minutes, never in Focus or for a lone window, and never with a mouse button down.
- **Undo and label:** ⌘⇧− or Tidy within 60 s counts as a no.
- **Model:** per-app Thompson sampling on Beta(kept, undone) for "grow or not", plus a decayed
  average of the share you leave it at.

**Drift stale windows to Workspace 3.**
- **Signal:** time since each window was last focused, which Tessel can track from `focusChanged`.
- **Action:** a window unfocused for longer than its app's threshold goes to Workspace 3 through the
  existing Hide path (`send(toSpace: 2, follow: false)`, [Tiler.swift:1549](../Sources/Tessel/Tiler.swift:1549)).
  The threshold starts at 8 h and is learned per app from {2 h, 4 h, 8 h, 24 h, never}.
- **Only when you aren't looking:** in a Workspace not in view, or after 5 minutes of no input. It
  never drifts:
  - the last window in a Workspace;
  - the focused window;
  - a window you brought back from Workspace 3 before;
  - windows of apps marked "never".
- **Telling you:** on your return the badge says "2 windows rested in Workspace 3", with a key that
  brings them back.
- **Model:** a bandit over the thresholds. Bringing a window back within a day moves that app one
  arm longer, and closing it from Workspace 3 confirms the threshold.
- **Don't oversell it:** parked windows still draw (the battery note in
  [launch-checklist.md](launch-checklist.md)), so drifting tidies up but doesn't save power.

`autopilot.jsonl`: `{"time":…,"app":"com.apple.TextEdit","action":"grow","share":0.58,"outcome":"kept"}`

**Failing safe:** off by default, at most one action every 2 minutes, every action says what it
did, every undo counts, and two undos in a row turn that behavior off for that app for a week.

---

## The JEPA-style predictor (step 3, shared)

This is the same idea as Meta's JEPA (predict in representation space, with an EMA target encoder)
at a tiny scale, trained only on this Mac's own window events. It is **not** V-JEPA's
300M-parameter video model.

- **Input tokens for a "situation":** hashed bundle IDs per Workspace, the focused app, window
  kinds (item 1's signature), the display class, hour and weekday as sin/cos, and the Workspace
  index.
- **Context encoder** `f_θ`: token embeddings (1,024 hashed buckets × 32 dims), mean-pooled per
  Workspace, then an MLP 32→64→32, giving `z`.
- **Target encoder** `f_ξ`: an EMA of θ (τ = 0.99) with stop-gradient, applied to the situation a
  few minutes later or after the next window event.
- **Predictor** `g_φ(z, action)`: an MLP (32 + 16-dim action) → 64 → 32, where the action is a
  window opening, a focus change or a Workspace switch.
- **Loss:** `smooth-L1(g(z, a), sg(f_ξ(y)))` plus a VICReg-style variance and covariance term on
  `z`. With this little data, EMA alone can collapse.
- **Size:** about 41k parameters, roughly 165 KB in fp32 or 80 KB in fp16, plus the target copy.
  The file is `models/jepa.bin`, under 1 MB with room to grow 4×.
- **Training:** idle time only (the conditions above). It's hand-written forward and backward
  passes over Accelerate (`cblas_sgemm`, vDSP): 10k situations × 20 epochs is about 2·10¹⁰ FLOPs,
  a few seconds on an M-series CPU. MLX Swift would work too, but it adds a dependency and Metal
  for no gain at this size. Use it only if the model grows tenfold.
- **Inference:** one encoder pass, about 50k multiply-adds or 10–20 µs, on the learning queue at
  each context change, with the result cached.

**Uses:**
1. Cold start for an app Tessel has never seen: its nearest known apps in embedding space lend
   their priors for float or tile (item 1), Workspace (item 3) and Summon (item 4).
2. Auto Workspaces: the predicted embedding of "after this window opens" against each Workspace's
   current embedding gives a second opinion next to the counts.
3. Summon: rank candidate apps by how close their token is to the predicted next situation.

**Gate:** each use ships only if the on-device replay evaluation beats the counting model by 5
points or more on held-out recent days. If it doesn't, counting stays. That's a real possibility
with one person's data, and a fine outcome.

---

## Apple Foundation Models (optional, language only)

These are extras for Macs that have the on-device model. Tessel never depends on them, and none
of them is part of the learning core. The model can't learn from you (there's no per-user
fine-tuning), needs Apple Intelligence turned on and an eligible Mac, takes about 0.3–2 s per
answer, and only exists on macOS 26, while Tessel supports macOS 14.

**Gating:**

```swift
#if canImport(FoundationModels)
import FoundationModels
#endif

func languageModelAvailable() -> Bool {
    #if canImport(FoundationModels)
    if #available(macOS 26, *) {
        if case .available = SystemLanguageModel.default.availability { return true }
        // .unavailable(.deviceNotEligible / .appleIntelligenceNotEnabled / .modelNotReady):
        // the feature just doesn't appear. No prompts, no nagging.
    }
    #endif
    return false
}
```

The package stays at `.macOS(.v14)`. FoundationModels has to be weak-linked so Tessel still
launches on macOS 14 and 15. Add `-weak_framework FoundationModels` to the Tessel target's
linker flags, then check `otool -l` for `LC_LOAD_WEAK_DYLIB`. Each request uses a fresh
`LanguageModelSession`, with `prewarm()` when Summon opens. Results are cached in memory, and
nothing generated is written to disk except a Workspace name you keep.

**1. Naming Workspaces.** The input is the app names and window titles in the Workspace. The output
is a `@Generable struct WorkspaceName { @Guide(description: "one or two words") var name: String }`,
shown in the badge and the menu instead of "Workspace 2". It's regenerated when more than half the
Workspace changes. A name you edit is never overwritten.

**2. Grouping by what titles mean.** For each new window, a `@Generable struct Topic { var project: String }`
from its title ("tessel" from an Xcode project, a Terminal path, a Safari tab), batched, at most one
call per new window, and skipped on battery. The topic becomes one more token in Auto Workspaces'
co-occurrence counts, so windows about the same project end up together. The title and the topic
stay in memory only. The topic token is hashed before it reaches `focus.jsonl`.

**3. Plain-English commands in Summon.** When a query matches no app and reads like a sentence
("put Safari and Xcode side by side", "move everything about tessel to 2"), the model fills a
`@Generable struct WindowCommand { var action: Action; var apps: [String]; var workspace: Int? }`.
`Action` is an enum of Tessel's own verbs: move, side by side, focus, hide, float. Apps are
constrained to running apps. Summon shows a preview row ("↩ Put Safari and Xcode side by side")
above the web-search row, and nothing runs until you press Return. There's no close or quit verb.

---

## Privacy

### Every network call Tessel makes today

| What | When | Sends | Code |
|---|---|---|---|
| Sparkle update check: `GET https://tessel.sentientdonut.com/appcast.xml` | Once a day (`SUEnableAutomaticChecks`, `SUScheduledCheckInterval` 86400), or **Check for Updates…** | An ordinary request with Sparkle's User-Agent (app name and version). System profiling is off (`SUEnableSystemProfiling` isn't set). | [Info.plist](../Resources/Info.plist), [Updater.swift](../Sources/Tessel/Updater.swift) |
| Sparkle download of an update | Only after you agree to install | Nothing beyond the request | Sparkle |
| Refund check: `GET https://tessel.sentientdonut.com/api/revoked` | Licensed copies only, at most every 6.5 days (looked at on launch, every 30 minutes and on wake) | Nothing: no body, an ephemeral session, no identifiers. The list is compared on the Mac. | [Licensing.swift:70](../Sources/Tessel/Licensing.swift:70), [main.swift:104](../Sources/Tessel/main.swift:104) |
| Summon's web search or typed address | When you choose it | **Tessel itself sends nothing.** It builds the URL from macOS's chosen search engine and hands it to your default browser over Apple Events, or `NSWorkspace.open`. The browser makes the request. | [Launcher.swift](../Sources/Tessel/Launcher.swift), [Browsers.swift](../Sources/Tessel/Browsers.swift) |
| Buy, Lost License | When you choose them | Opens the website in your browser | [LicenseWindow.swift](../Sources/Tessel/LicenseWindow.swift), [main.swift](../Sources/Tessel/main.swift) |

These aren't network calls, for completeness: license activation (an Ed25519 signature checked
offline, `License.parse`), the `tessel://activate` link (handled locally), Spotlight file search
(`NSMetadataQuery` on the local index), and `state.json`.

### What learning adds: nothing

No new requests, no telemetry, no crash reports, no "anonymous statistics", and no model downloads:
models are trained here from your events, and Tessel ships with rules only. This is enforced by
`NothingLeavesThisMac.onlyTheLicenseCheckGoesOnline`
([EventLogTests.swift](../Tests/TesselCoreTests/EventLogTests.swift)). It scans every Swift file
under `Sources/` for networking APIs (`URLSession`, `URLRequest`, `NWConnection`, `import Network`,
sockets, WebSockets…) and fails if any file other than `Licensing.swift` has one. Foundation Models
runs Apple's on-device model, and Tessel never asks a server model anything.

### Controls

- **Settings › Reset What Tessel Learned** (prototyped, shown while learning is on; `learning-reset`
  for scripts). It deletes the `Learning` folder (every log, model and embedding) and the in-memory
  models. Once item 4 ships it also clears `launcherUses` and learned lone-window shapes. Windows
  open right now stay where they are. It keeps your license, trial, shortcuts, Workspace keys,
  and current `layouts`/`placement`, because that's where your windows are, not something learned.
  The shipping version asks first: "Forget everything Tessel learned about how you work? Your
  windows stay where they are."
- **Settings › What Tessel Learned…** (to do). A list of lessons in words, from
  `FloatClassifier.lessons()` and friends, such as "Finder: small utility windows float (you floated
  2)". Each has **Forget**, along with the on-device evaluation numbers and a **Show Log in Finder**
  button.
- **Settings › Learn From How I Work** (to do). A global switch: when it's off, nothing is logged and
  only the rules decide. There's also a switch per feature (Auto Workspaces, Predictive Summon,
  Autopilot).

### Loose ends found while writing this (not changed here)

- `privacy.html` says the daily update check can be turned off, but there's no switch for it in
  Tessel's menu. Sparkle honors `defaults write com.tyleryouens.tessel SUEnableAutomaticChecks -bool NO`.
  Either add an "Automatically Check for Updates" item or change the sentence.
- Summon's file search always adds `/Volumes/Master Storage` to its scopes
  ([Launcher.swift:242](../Sources/Tessel/Launcher.swift:242)). That's harmless elsewhere, but it's
  specific to Tyler's Mac.
- `userFloating` was never written to before this branch. The prototype leaves it alone and keeps
  its own per-window choice in `Learning`.
- When learning ships, `privacy.html` needs one more sentence, along the lines of: "To learn how you
  arrange windows, Tessel keeps a log of app names, kinds of windows and times (never titles,
  keystrokes or file names) in your Library on this Mac. It's never sent anywhere, and Settings ›
  Reset What Tessel Learned deletes it."

---

## Marketing copy that stays literally true

Use:
- "No account. Everything it learns stays on your Mac."
- "Learns how you work, on your Mac." *(true from item 1; "the window manager you never configure"
  is fair once items 1–3 ship)*
- "Float a window once, and the next one like it floats too."
- "It only changes what it does after you've shown it what you want." *(item 1; item 3's moves are
  earned through suggestions you accepted)*
- "Every automatic move says what it did, and one key undoes it."
- "Forget everything it learned with one click."
- "Works offline. Learning never needs the internet." *(update checks and the refund list just
  wait)*
- "No titles, keystrokes or file names are ever written down."
- With Foundation Models: "On Macs with Apple Intelligence, it can name your Workspaces, using
  Apple's on-device model."

Avoid:
- "No backend server" or "never connects to the internet": Sparkle and the refund list use
  tessel.sentientdonut.com.
- "100% private AI", "AI-powered" or anything that implies a cloud model.
- "Learns from millions of users", or shipping any prior trained on other people's data. If that
  ever changes, "learns from you" has to change with it.
- "Saves battery" for Autopilot's drifting: parked windows still draw.
- "Never sends anything": it fetches update and refund lists. "Never sends what it learns" is the
  true version.

---

## Milestones

1. **Float or tile**: the prototype in this branch. Next: live testing in the VM, the ⌘⇧T
   shortcut, the "What Tessel Learned" list, the global switch, and the reset confirmation. Then
   turn it on by default.
2. **Layout memory**: the template store and the synthetic `Layout.restore`, with tests built from
   the existing permutation fixtures.
3. **Auto Workspaces**: `focus.jsonl`, counts, suggestions, then moves, `ForeignFocus` gaining
   `placedForYou`, and the undo key.
4. **Predictive Summon**: naive Bayes ranking and warm pre-launch.
5. **Autopilot**: opt-in, last.
6. **The JEPA predictor**: once items 1–3 have a month of logs to evaluate against.
7. **Foundation Models extras**: any time after item 3, since they're independent.

## Open questions

- Should Float/Tile get a default shortcut (left ⌘⇧T) at launch, or stay in the menu until item 1
  is on by default?
- Auto Workspaces' undo key reuses ⌘⇧ + the current Workspace key. Is that discoverable enough, or
  should the badge be clickable?
- Should the learning folder be in backups after all? Leaving it out makes "stays on this Mac"
  airtight, but a new Mac starts from zero.
