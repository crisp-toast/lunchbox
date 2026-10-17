# Making Tessel worth $9.99

For Tyler, 2026-10-17. The question: get window decisions above 95% correct, or use Laya or
Julia 1 some other way, so that Tessel feels like a power tool that people want to pay for
because it really saves them time.

## The short answer

1. **The decision you'd notice is already above 95%.** Whether a window tiles or floats is
   right **98% of the time (82 of 84)** on apps the classifier never saw. The exact placement
   (tile, float, or float centered) is right 92% of the time. Every miss costs one correction,
   and that kind of window is right from then on.
2. **Laya and Julia 1 lose in the other jobs too.** On finding a window by typing, plain word
   matching beats them. On plain-English commands they get 38–58% of actions right. Don't ship
   either one now; it would add 40–650 MiB for nothing a user would feel.
3. **What gets people to pay is seeing their own time come back.** Four things, in order:
   - turn learning on by default;
   - count the time Tessel gives back, honestly, and show it in the menu and on the
     trial-end screen;
   - let Summon jump to any window by a word in its title;
   - sell "you never set it up" against the free tiling managers, which make you write rules.

## 1. Accuracy, as you'd see it

Held out by app (each app judged by a model that never saw it), on the 84 labeled windows from 52
apps:

| | Tiles or floats | Exact placement (tile / float / float centered) |
|---|---|---|
| Today's rules | 89% (75) | 86% (72) |
| The classifier alone | 93% (78) | 87% (73) |
| **As shipped** (classifier when sure, rules as the floor) | **98% (82)** | **92% (77)** |

**The 2 misses that change your layout:**
- A Preview image floats when it should tile.
- Archive Utility's progress window tiles when it should float.

(A third, 1Password's main window floating, came from a rule in Tessel's first commit that
floated every 1Password window. That rule is gone since 2026-10-17: 1Password tiles like any
app, and its small windows still float by the usual rules.)

**The 5 misses that only change where a floating window sits:**
- **Settings windows Tessel centers:** Terminal's settings ("General"), iTerm's Settings and
  TextEdit's Spelling and Grammar. macOS marks them as dialogs, so Tessel centers them; the
  labels say they should stay where the app put them.
- **The screenshot toolbar** (⇧⌘5): macOS calls it a system dialog. Check in the VM whether
  Tessel really moves it. If it does, it happens on every screenshot, and it's worth fixing
  whatever else you decide.
- **Finder's Connect to Server:** it floats where it opened, but the label says it should be
  centered.

**What's behind these numbers:**
- 84 windows is a small set.
- I labeled them myself.
- The 0.5 threshold was picked on the same windows, so 98% flatters a little.

**Getting a trustworthy "above 95%":**
- **It's already true in use, after a fix:** float a window once (a document window twice), and
  every window like it is right from then on. A miss costs one correction per kind of window,
  not one every day.
- **One decision for you:** should settings windows that macOS marks as dialogs stay where the
  app put them, instead of being centered? On these windows, that would make exact placement
  96% (81 of 84). But that change would be chosen on the very windows it's measured on, so it
  only counts once fresh windows confirm it.
- **The real proof is a fresh census of 300+ windows** (already proposed as a follow-up). It's
  also the data any fine-tuned model would need.

## 2. Laya and Julia 1 in other jobs

Details are in [system-one-research.md](system-one-research.md#round-3-other-jobs-text-typed-by-you).

| Job | Best open model | Plain matching | What macOS ships (0 MB) |
|---|---|---|---|
| Find a window by its title's words (of 15) | 9 (Julia 1) | **15** | 15 |
| Find a window by part of its title (of 15) | 5 (Julia 1) | **12** | 9–13 |
| Find a window by a description only (of 15) | **6** (Laya) | 1 | 3–5 |
| Pick the action in a typed command (of 48) | 28 (Laya) | – | 22–25 |

- **No small encoder has the world knowledge** to find a window from a description alone
  ("the bill I need to pay" for INV-2026-0042.pdf).
- **The words people actually type** are handled best by plain matching, instantly, at 0 MB.
- **A command that picks the wrong action** moves windows you're looking at, which breaks
  Tessel's own rule against being annoying. At 58%, that would happen about every other
  command.
- **If you want typed commands later:**
  - fine-tune Laya (it's built to be specialized) on a few thousand synthetic phrasings, with no
    user data;
  - test it on phrasings someone else wrote;
  - ship it at 95% of actions right, with a preview row before anything runs.

  That's a separate project, and not what makes people pay.

## 3. What makes people pay $9.99

**What $9.99 is up against:**
- **Free:** Rectangle (snapping), and AeroSpace, yabai and Amethyst (tiling).
- **Paid:** Magnet is $4.99.
- **Rules you have to write:** the free tiling managers float windows only through rules you
  write yourself, like yabai's `manage=off` rules or AeroSpace's `on-window-detected` blocks.
  That config file is why most people try tiling and quit.
- **Switching by typing sells:** apps whose main job is jumping to a window by typing (Contexts,
  Witch) sell on that alone.

**No study says how many minutes a day people spend arranging windows.** The closest research
measures what task switching costs. So Tessel shouldn't claim a number. It should measure each
person's own.

### 1. Turn learning on by default

- **Why:** a trial user who never opens Settings never sees the thing the site promises.
- **What makes it safe:** the "not annoying" rules in [learning.md](learning.md). It only places
  new windows, never takes focus, shows nothing but the quiet line, and two undos make it stop.
- **Open question 1 in learning.md:** I'd say yes, after a few days on your own Mac.

### 2. Count the time Tessel gives back, and show it

**A small ledger of things you'd otherwise do by hand on a plain Mac.** Each is counted at a
conservative number of seconds, and the screen shows how it was counted, so nobody has to take
it on trust.

| Counted | Seconds each (proposal) |
|---|---|
| A new window tiled into place | 2 |
| An app opening into its usual spot and share | 2 |
| A new window sent to its Workspace | 3 (switch, find it, move it) |
| A window put back when a display returns, after waking, or after a restart | 2 |
| A jump to a window from Summon | 1 |
| A correction or an undo (subtracted) | −3 |

**Where it shows:**
- **The menu:** "This week: 23 minutes back · 412 windows placed."
- **What Tessel Learned.**
- **The trial-end screen.**
- **Never as a notification:** that would break the no-popups rule.

**How it's kept:**
- Daily counts, stored in the learning folder.
- The same privacy as everything else: no account, and nothing leaves the Mac.
- Reset clears it.

**What to claim:** "time back", not "productivity". It counts the drags and moves you didn't
make, nothing more.

### 3. Make the trial-end screen about their week

Today it says "Your free trial has ended." Instead (proposed wording):

> **This week, Tessel gave you back 26 minutes.**
> It placed 412 windows, put 9 apps back the way you like them, sent 41 windows to their
> Workspace, and put everything back the 6 times your display came back. It learned 14 things
> about how you work.
>
> **Keep Tessel: $9.99, once.** What it learned stays on your Mac either way.

- **The lessons are listed, never held hostage.** That's loss aversion, done honestly.
- **Two days before the end,** the menu's trial line can carry the number too: "Free trial: 2
  days left · 21 minutes back so far."

### 4. Let Summon jump to any window

- **Today:** Summon (⇧Space) finds apps and files, not windows.
- **The change:** add the open windows' titles to its matching, so typing "invoice", "lunch" or
  "Tiler" goes straight to that window, in any Workspace, on any display.
- **Why plain matching:** the probe above says it's enough (15 of 15 on title words). It adds
  0 MB, it's instant, and it's the feature people already pay other apps for.
- **It feeds the ledger:** each jump counts.

### 5. Sell "you never set it up"

Against free tools, the pitch isn't tiling. It's the config file you'll never write. Proposed
copy, not published (site copy stays yours):
- **Headline:** **The tiling window manager you never set up.**
- **Sub:** *No float rules, no config file, nothing to learn first. Fix a window once and Tessel
  gets it right from then on. On your Mac, with no account.*
- **Under the price:** *7 days free, then $9.99 once. Before you decide, Tessel shows you how
  many minutes it gave you back.*
- **A 20-second demo:**
  - plug in a display, and every window goes back;
  - open Mail, and it lands in Workspace 2;
  - a small panel floats by itself, with the quiet line on screen.

  Record it in the VM or on the spoof display.

## Build order

| # | What | Why first | Size |
|---|---|---|---|
| 1 | The time-back ledger, its menu line and the trial-end screen | The biggest effect on paying | About a day: a `TimeBack` type in TesselCore with tests, plus Learning, StatusMenu and LicenseWindow |
| 2 | Learning on by default | Without it, a trial user never sees any of this | One line, plus a few days on your Mac |
| 3 | Window search in Summon | The power-tool feel, and it feeds the ledger | About a day: Launcher, plus the titles Tiler already reads |
| 4 | The onboarding step that shows learning once | Value in the first five minutes | Already proposed as a follow-up |
| 5 | A fresh census of 300+ windows | A trustworthy "above 95%", and the data any fine-tune needs | Already proposed as a follow-up |
| – | Laya or Julia 1 | Not now | – |

## Decisions for you

1. **Learning on by default** at launch?
2. **Settings windows** that macOS marks as dialogs: center them (as today), or leave them where
   the app put them?
3. **The seconds per action** in the ledger: are the proposals above conservative enough?
4. **The headline:** "The tiling window manager you never set up", or keep "Tiling that learns
   where your windows go"?
