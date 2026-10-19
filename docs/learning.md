# Lunchbox learns where your windows go

Design and status, 2026-10-16. Lunchbox's headline: **a smart window manager that's never
annoying about it.** It learns from what you do, on your Mac, with no account and no setup,
and it never moves anything you're looking at.

**Status.** In main since 2026-10-18 (built on branch `claude/bold-villani-c70383`), behind
**Settings › Learn Where Windows Go**, off by default until Tyler has lived with it. All three proofs below work on real windows
in the test VM (macOS 27), including undo, "undo twice and it forgets", relaunch and Forget.
`swift test`: 245 tests pass (with the time-back count and Summon's window and file search).

**Try it:** build and install (`./scripts/build.sh --install`), then turn on
Settings › Learn Where Windows Go. Then:
- Float a small tool window from the menu (**Float This Window**), or drag a window out of its
  tile twice in a row. The next window like it floats by itself.
- Give two apps an uneven split (⌘⇧ + / −), leave it for half a minute, then quit one app and
  open it again. It comes back in its spot, at its share.
- Move an app's window to Workspace 2 (⌘⇧2) and keep it there for ten
  minutes. New windows of that app now open in Workspace 2.

Each time, a quiet line at the bottom of the screen says what happened, and ⌘ with the key of
the Workspace you were in undoes it.

**Not built yet:**
- the onboarding moment that shows Lunchbox learning once, live (designed below);
- a shortcut for Float/Tile (only the menu, the `float` command and the double drag for now);
- turning learning on by default;
- trying it on Tyler's own Mac, and after a logout and login (where Workspace homes matter most).

How this turns into a reason to pay (a time-back count, the trial-end screen, window search):
[worth-paying-for.md](worth-paying-for.md).

**Time back (built 2026-10-17).** Lunchbox counts what it did that you'd otherwise do by hand, at
a few seconds each, less 3 s for every correction or undo. The menu says "This week: 23 minutes
back · 412 windows placed", What Lunchbox Learned says how it's counted, and the trial-end screen
leads with the trial week and what Lunchbox learned. It's kept as daily counts in the learning
folder (`timeback.json`, below) and never shown as a notification. What's counted and where:
[Item 1, as built](worth-paying-for.md#item-1-as-built-2026-10-17).

---

## Step one: deciding how each window behaves

The first piece of the smart layer is a **window classifier**. The moment a window appears, it
decides whether the window is a document (tiles), a tool panel, a here-and-gone window, a video
or call, or a dialog. It reads the window's Accessibility traits and its title, and decides in
about 0.05 ms, plus 1–1.6 ms of Accessibility reads on the app's own queue. The old rules stay
underneath it as a safety floor.

Held out by app, it gets 85% of windows' behavior right where the rules get 81%, and 92% of
tile-or-not decisions where the rules get 86%, on a small labeled set of 84 windows. That's
measured against Lunchbox's rules as of 2026-10-17, which tile Calculator, System Settings and
QuickTime (against the older rules it was 88% and 98%). Its call is the starting point your own
corrections adjust. Details, the honest caveats, and how to see it on your own windows are in
[window-classifier.md](window-classifier.md).

## One promise, three proofs

**Lunchbox learns where your windows go.** That's the sentence people should repeat. Three things
prove it, and each pays off the first time you repeat yourself:

1. **It floats what you'd float.** Float a window once (twice for a full document window), and
   the next window like it floats by itself.
2. **It opens apps in your usual arrangement.** Arrange apps once and leave them that way. The
   next time one of them opens next to the others, it takes its spot and its share.
3. **It sends new windows to the Workspace they belong in.** Keep an app in Workspace 2, and its
   new windows open there. That includes after a restart, when today everything piles into
   Workspace 1.

These are decision models, not chat:
- counting statistics with backoff (kind of window → app → Lunchbox's rules);
- dwell time for arrangements;
- "moved there and kept there" for Workspaces;
- an undo ledger that makes Lunchbox back off.

Each runs in microseconds, learns from your own corrections, and stays on your Mac. That's
literally true, and it's what the marketing can say. Predictive Summon, Autopilot, a
fine-tuned open System One model and Foundation Models are later extras (see the end of this
doc). They're not part of the promise.

## Not annoying, as hard rules

Annoyance is the failure that would sink this, so it's treated like a crash. These rules are in
`Etiquette` ([Etiquette.swift](../Sources/LunchboxCore/Etiquette.swift)) and enforced in code. Most
of them have a unit test.

| Rule | How it holds | Checked by |
|---|---|---|
| **It only decides where a *new* window lands.** It never rearranges what you're looking at. | Learned placement only applies to windows Lunchbox first saw under 10 s ago (`ManagedWindow.isNew`), never to windows back from a relaunch, minimize or full screen. A usual spot is applied with `Layout.restore`, which places the newcomer without reordering the windows already there. A window's float or tile choice is decided once, and a tiled window stays tiled (`tiles`). | `UsualArrangements.windowsAlreadyThereNeverChangeOrder`, VM run |
| **It never takes focus.** | A window placed in another Workspace while you stay is marked `placedForYou`, so its app grabbing focus is ignored (`ForeignFocus` returns `.stay`) and the keyboard goes back to your window. You only go along when you just opened the app yourself, the same as the Dock does. | `NotAnnoying.aWindowPlacedForYouNeverTakesYouThere`, VM run |
| **No popups, notifications or questions.** | The only thing it shows is the quiet line: a click-through, non-activating pill that's gone after 2.5 s, with a newer line replacing an older one. Nothing ever asks. Reset asks for confirmation, but only because you clicked it. The time back is a line in the menu and on the trial-end screen, never a notification. | VM screenshots |
| **Silent when unsure.** | The rules decide unless you've taught otherwise:<br>• A float needs a correction (two for a document window).<br>• An arrangement needs to have stood 30 s.<br>• A Workspace home needs your move plus 10 minutes of window time, nine tenths of it there.<br>• An app that also has windows elsewhere gets no home placement.<br>Hints alone never override the rules. | `FloatClassifierLearns`, `WorkspaceHomes`, `UsualArrangements` |
| **Everything automatic is one quiet line, and one key undoes it.** | The key is ⌘ and the number of the Workspace you were in (⌘1 in Workspace 1). Pressed in that Workspace it otherwise only shows the Workspace badge, so it takes nothing new from you. It works for 10 s, or 3.5 s when Lunchbox took you to another Workspace (so just going back doesn't also drag the window along). Things done within a second of each other share one line and one undo. | `NotAnnoying.oneQuietLine…`, `…manyThingsAtOnceShareOneLine`, VM run |
| **Two undos in a row, and it forgets that lesson.** It stops until you teach it again. | `UndoLedger`, then `Learning.forget`. Undoing a learned float is itself a correction, so one undo is enough there. | `NotAnnoying.twoUndosInARowAndItStops`, VM run |
| **Never slower than today.** | Float decisions run on the app's own queue during the window read Lunchbox already does (about 0.5 µs, plus four or five Accessibility reads once per new window). Usual spots and homes are dictionary lookups when a window is placed. All disk work happens on its own queue. Only the app queues ever wait at startup, for up to 1 s, while lessons load. | `FloatClassifierLearns.decidingTakesAboutAMicrosecond` |
| **Lessons are visible and forgettable, in words.** | **Settings › What Lunchbox Learned** lists lessons like "TextEdit: medium document windows float", "Terminal and TextEdit: your usual arrangement", "Mail: new windows open in Workspace 2". Clicking one forgets it, including from the log. **Reset What Lunchbox Learned…** forgets everything. | `WindowKinds.lessonsInWords`, VM run |

## Day one (the cold start)

The trial is 7 days, so something smart has to happen within the first hour, without guessing.

- **Minutes in: floats.** The first time you float a small tool window (from the menu, or by
  dragging it out of its tile twice, which is what people already do when a tiling manager
  fights them), the next one floats. A full document window needs it twice, because floating one
  document is often a one-off.
- **The first time you reopen an app: arrangements.** Arrange two apps (⌘⇧ + / − or a drag),
  leave them 30 s, and the next time one opens beside the other it takes its usual spot and
  share. A lone window you resized comes back at that size straight away.
- **Within the hour: Workspaces.** Move an app's window to a Workspace and keep it there for 10
  minutes. From then on its new windows go there. The big moment is the first restart, when every
  window that comes back goes to its Workspace instead of all piling into Workspace 1.
- **Onboarding (to build): show it once, live.** Add a step to the practice screen
  (`Playground`):
  1. A pretend "Colors" palette opens and tiles.
  2. The step asks you to drag it out of its tile twice.
  3. It floats where you dropped it.
  4. A second "Colors" opens and floats by itself, with the real quiet line: "Colors floats, like
     the last one".

  That's one sentence of reading and five seconds of doing. Then the finish step lists the three
  proofs in a line each.

## How each proof works

### 1. Floats what you'd float

*Code:* `FloatClassifier` ([FloatLearning.swift](../Sources/LunchboxCore/FloatLearning.swift)),
`Learning.decide` ([Learning.swift](../Sources/Lunchbox/Learning.swift)), `Tiler.tiles` and
`toggleFloating`.

- **You teach it** with **Float This Window** / **Tile This Window** (the menu, or the `float`
  command). You can also drag a tiled window out of its tile twice within 10 s: the first drop
  glides back as always, the second floats it where you dropped it.
- **What it looks at**, once, the first time a window that could tile appears:
  - bundle ID, subrole, title-bar buttons;
  - size, and its share of the screen (small, medium or large);
  - the *kind* of title: empty, the app's name, a tool word like "Settings" or "Inspector", or
    anything else. The title itself is never stored.
  - native tabs;
  - whether it refused its tile size: macOS has no attribute for minimum or maximum size, so
    `Animator.onSettled` notices instead.

  The window's **kind** is app, subrole, buttons, size class and title kind.
- **How it decides:** decayed counts per kind and per app (half-life 180 days), backing off to
  the rules. It goes against a rule only in the direction of your latest correction:

  ```
  prior = 0.9 if the rule says float, else 0.1
  p_app = (float_app  + 2.0 × prior) / (total_app + 2.0)
  p     = (float_kind + s × p_app)   / (total_kind + s)     s = 1.5 for a document window, else 0.5
  float if rule = tile  and p ≥ 0.75 and your latest correction says float
  tile  if rule = float and p ≤ 0.25 and your latest correction says tile
  ```

  - Evidence: a correction counts 1. A learned choice you lived with for over a minute counts
    0.25, which keeps a lesson fresh. A tiled window that closed within 3 s counts as a 0.25 hint
    toward floating, but only for windows that opened while Lunchbox ran and didn't close because
    their app quit.
  - Windows you simply left as the rules placed them don't count, so someone who finds the Float
    command after a year of tiling doesn't have to repeat themselves.
  - What can never be learned stays hard-coded: dialogs, sheets, Open and Save panels;
    minimized, full-screen and non-resizable windows; Lunchbox's own windows; and apps an agent has
    `leave-app`'d.
- **When it floats a window,** whether learned or by your hand, the window goes back to the size
  it opened at. That's centered where its tile was, or with its corner where you dropped it, and
  kept on screen.
- **It survives a relaunch:** each open window's kind and choice are kept in `memory.json`, so
  your floats stay floating and kinds stay stable.

### 2. Opens apps in your usual arrangement

*Code:* `Arrangement`, `ArrangementMemory` ([Arrangements.swift](../Sources/LunchboxCore/Arrangements.swift)),
`Tiler.usualPlace` and `noteArranged`.

- **Recording:**
  - After you change a layout (move, resize, swap, drag, send, Tidy), Lunchbox remembers that
    arrangement for as long as it stays the same. An arrangement it applied for you counts too,
    if you leave it be.
  - It's stored without window numbers: which app's window is in which column and stack, and
    the shares.
  - It's keyed by display size (`1920x1080`) and the set of apps.
  - The time it stood is counted on each change and every ten minutes. Up to 3 variants are kept
    per context, and the one that stood longest (half-life 30 days) wins once it has stood 30 s
    in total.
- **Lone windows:** resizing a window that's alone (or Tidying it) records its shape for that app
  and display. Only *your* resize counts, never the app's own size, which keeps e9d3bac's
  decision that Lunchbox ignores app-chosen sizes.
- **Applying:**
  - When a new window opens, Lunchbox looks up the arrangement for "these apps plus this one".
  - It builds a stand-in `Layout` from it and calls the existing, permutation-tested
    `Layout.restore`. The newcomer goes beside, or into the stack of, the same windows it had
    before, and the windows already there never change order.
  - If everything then matches the arrangement exactly, the shares become the arrangement's too.
  - A placeholder (Summon, a Dock click) takes the usual spot as well, so the window lands right
    where it belongs.
- **Undo** puts the window where it would have gone without the lesson.
- **Four windows:** the fourth window in a Workspace makes a 2×2 grid (`Layout.grid(adding:)`),
  moving the three already there as little as it can. That's the one moment Lunchbox reshapes
  windows already in place, because you asked for a grid there. Instead of the grid, it uses:
  1. the whole arrangement you kept for exactly these four apps, if there is one;
  2. otherwise, a shape you made around one of the apps (`AnchoredShape`). For example: Claude
     alone in the left column at full height, with the other three stacked on the right. It's
     learned per app and display size, from four-window arrangements you made yourself (not
     ones Lunchbox made that you let stand) and kept for 30 s. The latest shape you made wins.
     Going back to a grid with that app sharing a column, and keeping it, unlearns it.

  Either way, one quiet line ("Claude has the left to itself, like last time · ⌘1 makes a
  grid"), and the undo key gives the grid instead. Two undos forget it. The grid and the
  shape give way to size limits (main's `SizeLimits`): a window whose minimum height can't
  share a column gets a column with room instead, and a new window is moved into its learned
  spot before it shows (`plannedFrame`), not into the grid and then across. It's listed under What
  Lunchbox Learned as "Claude: the left side to itself, with four windows".

### 3. Sends new windows to the Workspace they belong in

*Code:* `WorkspaceMemory` ([Workspaces.swift](../Sources/LunchboxCore/Workspaces.swift)),
`Tiler.insert`, `placedInHome`, `undoAutomatic`.

- **The lesson:** you move one of an app's windows to a Workspace yourself (⌘⇧ and its number).
  Hide (⌘⇧H) is putting it away, not a home, so it doesn't count. Once the app's windows have then
  spent 10 minutes of window time there, and nine tenths of their time since the move, that's its
  home. Window time is only counted while you're at the Mac (input within 5 minutes). Moving one
  of its windows elsewhere starts over.
- **Which windows go home:**
  - Only new windows you didn't open from Lunchbox: Summon, the Dock and the Dock's New Window
    still bring windows to you.
  - Never if the app also has a window somewhere other than its home.
  - Never if you're already there.
- **You stay or you go.** If you just opened the app yourself (it launched within 1.5 s of a key
  press or click, or it's in front within 2 s of one), you go with it, exactly like a Dock click
  takes you to an app's window today. If the window opened by itself (a login item, a document
  opened by a script, an app's own pop-up), you stay where you are and keep the keyboard.
- **Undo** brings the window to the Workspace you were in. Pressed twice in a row for the same
  app, Lunchbox forgets that home.
- **Known interaction:** activating an app whose windows are all in another Workspace already
  takes you there today (`ForeignFocus.goThere`). So `open -a Mail` with a Mail window in
  Workspace 2 switches to Workspace 2 before any new window appears. That's existing behavior, and
  consistent with this feature.

## Storage and privacy

Everything lives in `~/Library/Application Support/Lunchbox/Learning/`. The folder is mode 0700 and
the files 0600, and the folder is excluded from Time Machine (`isExcludedFromBackup`), so "stays
on your Mac" is literally true. Logs are JSON Lines anyone can read in TextEdit
(`EventLog`, [EventLog.swift](../Sources/LunchboxCore/EventLog.swift)). Each log holds at most two
files of its cap, and anything older than 90 days is pruned at start.

| File | What | Cap |
|---|---|---|
| `float.jsonl` | your float/tile corrections, and closes that count as evidence | 2 × 1 MB |
| `arrange.jsonl` | arrangements and how long they stood, lone shapes, forgotten lessons | 2 × 1 MB |
| `workspace.jsonl` | moves, placements, undos, forgotten homes (the story; the numbers are in memory.json) | 2 × 512 KB |
| `memory.json` | Workspace homes and their window time, the undo ledger, each open window's kind and choice | small (KB) |
| `timeback.json` | the time back: how many windows Lunchbox tiled, put in their usual spot, sent home or put back each day, Summon jumps, and corrections. Dates and numbers only. Kept whether or not learning is on | 90 days, a few KB |

`timeback.json` follows the same rules as the logs: 0600, in the same folder, pruned after 90
days, and Reset What Lunchbox Learned deletes it. A typical day writes a few kilobytes. Events hold bundle IDs, kinds of window, sizes, Workspace
numbers, display sizes and times. **Never** window titles, file names, URLs, typed text or key
codes.

### Every network call Lunchbox makes, and learning adds none

| What | When | Sends |
|---|---|---|
| Sparkle update check, `GET lunchboxwm.com/appcast.xml` | daily, or **Check for Updates…** | Sparkle's User-Agent (app name and version); system profiling is off |
| Sparkle download | only after you agree to an update | the request |
| Refund list, `GET lunchboxwm.com/api/revoked` | licensed copies, at most every 6.5 days | nothing: no body, an ephemeral session, compared on the Mac |
| Summon's web search, Buy, Lost License | when you choose them | nothing from Lunchbox: the URL opens in your browser |

`NothingLeavesThisMac.onlyTheLicenseCheckGoesOnline` fails if any Swift file other than
`Licensing.swift` uses networking APIs, so a learning feature that phones home breaks the build.
Lunchbox ships with no pretrained model and no shared data: everything it knows, it learned from
you.

**Loose ends found along the way (not changed here):**
- `privacy.html` says the daily update check can be turned off, but there's no switch for it in
  Lunchbox. Sparkle honors `defaults write com.sentientdonut.lunchbox SUEnableAutomaticChecks -bool NO`.
- Summon's file search always includes `/Volumes/Master Storage`, which only exists on Tyler's
  Mac.
- When learning ships, `privacy.html` needs a sentence like: "To learn where your windows go,
  Lunchbox keeps a log of app names, kinds of windows and times (never titles, keystrokes or file
  names) in your Library on this Mac. It's never sent anywhere, and Settings › What Lunchbox Learned
  › Reset deletes it."

## Tested

- **Unit tests** (`swift test`, 245 in all). New suites: `FloatClassifierLearns`, `WindowKinds`,
  `UsualArrangements`, `WorkspaceHomes`, `NotAnnoying`, `EventLogStaysSmallAndLocal`,
  `NothingLeavesThisMac`, and for the time back `TimeBackCounts`, `TimeBackStaysOnThisMac` and
  `TimeBackInWords`.
- **Live, in the test VM (tessel-vm, macOS 27), 2026-10-16,** with TextEdit and Terminal:
  - **Floats:** a document floated once still tiles next time. Floated twice, the next one floats
    by itself at its natural size, with the quiet line. The undo key tiles it, and the next one
    tiles.
  - **Relaunch:** your floats and learned floats survive it.
  - **Drag out twice:** floats the window where it's dropped.
  - **Arrangements:** after a ⅔ / ⅓ split stood 35 s, a reopened TextEdit came back at ⅓ on the
    right. Undo gave 50/50. Two undos forgot the arrangement.
  - **Lone shape:** it came back.
  - **Workspaces:** after moving TextEdit to Workspace 2 and counting 700 s there, a document
    opened from a script went to Workspace 2 while Terminal kept the keyboard in Workspace 1.
    Launched from Spotlight, it went to Workspace 2 and took me with it. The undo key brought it
    back, and two undos forgot the home.
  - **Lessons:** listed in words, and a click forgets one.
- **Bugs found live and fixed:**
  - Floating a document window once floated every document of that app. Now it takes two.
  - Floats didn't survive a relaunch. Fixed with `memory.json`.
  - A floated window kept its tall tile size. It now goes back to the size it opened at.
  - Killing an app looked like "these windows should float".
  - Moving windows recorded fake lone-window shapes.
- **Not tested yet:**
  - Tyler's real apps and displays;
  - a logout and login (homes at startup);
  - more than one display;
  - Mail, Messages or Slack opening windows on their own;
  - macOS 14 to 26 (the VMs exist: `VM_NAME=tessel-sonoma` etc.).

## Later, and only behind the same rules

- **Predictive Summon.** Rank Summon's empty-query list by context (Workspace, the app in front,
  time of day) with decayed counts, capped so a typed match always wins. Optionally warm the
  predicted app's files into the disk cache. Today's `launcherUses` is frequency only and never
  decays.
- **Autopilot (opt-in).** Grow the window you're typing in, or let windows you haven't touched for
  hours drift to Workspace 3. It's the only thing that would move windows already in place, which
  is why it's opt-in and last.
- **An open System One decision model** (Laya, Julia 1), fine-tuned on labeled windows once there
  are several hundred. Zero-shot they lose to the rules on windows
  ([system-one-research.md](system-one-research.md)). One ships only if it beats the small window
  classifier on held-out apps, and fits Lunchbox's memory and size budget.
- **Apple Foundation Models**, behind `#available(macOS 26, *)`, `canImport(FoundationModels)`,
  `SystemLanguageModel.default.availability == .available` and a weak link. It's for language
  only: naming Workspaces, grouping windows by what their titles mean, and plain-English commands
  in Summon that always show a preview row before running. It can't learn from you and is far too
  slow for per-window decisions, so it's never part of the core.

## Proposed site copy (for Tyler; not on the site)

This is written to be literally true of the branch as built. The day it ships, learning must be
**on by default** for the hero to be honest. Until then, use the feature section only, with
"Turn on Learn Where Windows Go".

**Hero**
- Headline: **Tiling that learns where your windows go.**
- Sub: *Float a window once and the next one floats. Arrange your apps once and they open that
  way. Keep Mail in Workspace 2 and it opens there. No settings, no account, and everything it
  learns stays on your Mac.*

Alternatives: "The window manager that learns your habits, not your secrets." / "Smart about
your windows. Never annoying about it."

**Feature section: "It learns. Quietly."**
- **Floats what you'd float.** Pull a window out of the tiles and Lunchbox stops tiling windows
  like it.
- **Opens apps the way you arranged them.** Your split, your sizes, every time.
- **Sends new windows where they belong.** Each app opens in its Workspace, even after a
  restart.
- **Never in your way.** It only decides where *new* windows go. It never moves what you're
  looking at, never steals focus, and never asks. One quiet line says what it did, and one key
  undoes it.
- **Yours, and only yours.** No account, no cloud, nothing sent anywhere. See every lesson in
  words, and forget any of them with a click.

**Avoid:** "AI-powered", "no backend server" (Sparkle and the refund list are served from
lunchboxwm.com), "never goes online", "learns from millions of users", and "saves
battery".

## Open questions for Tyler

1. Turn learning on by default after you've used it for a few days?
2. The undo key is ⌘ and the number of the Workspace you were in, named in every quiet line. Is that
   discoverable enough, or should the line also be clickable?
3. Should a window you launched from Spotlight take you to its app's Workspace (as built, like
   the Dock), or open where you are?
4. Should Float/Tile get a default shortcut? Every free combination clashes with something:
   ⌘⇧T reopens closed tabs in browsers, and ⌘⇧↩ inserts a line in editors.
5. Should the learning folder stay out of backups? That keeps "stays on this Mac" literal, but a
   new Mac starts from zero.
