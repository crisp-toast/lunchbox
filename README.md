# Tessel

A small, fast tiling window manager for macOS that lives in the menu bar.

- One window on a screen sits centered at a comfortable 16:10 size. Two or three tile side by side;
  the fourth makes a 2×2 grid, unless you've shown Tessel a shape you like better (see Learning).
- Everything is driven by the **left** ⌘ key, so right ⌘ + arrows still move the text cursor.
- Windows slide into place, in one move each. Apps that can't keep up, or stall now and then, just
  snap, so Tessel never adds lag; and an app's windows move together, never one after another. An
  app opening several windows at once (restoring them at launch) has them laid out together, instead
  of the layout reflowing once per window.
- A new window goes straight into its tile, within a frame or two of appearing, instead of
  showing up where its app put it and gliding over. Tessel moves it the moment the app makes it,
  often before it's even on screen.
- Three Workspaces on ⌘1, ⌘2 and ⌘3, switched instantly. Add more (up to nine) from the menu.
- Dialogs (Open, Save, alerts, password prompts) float, centered on their screen, instead of
  splitting the tiled windows apart, and stay in view when you switch Workspaces. So do small
  windows that can't be resized or minimized, like About boxes and progress windows. A "dialog"
  with every title-bar button that you can resize, like Little Arc, is a window in all but name and
  tiles like one.
- Windows that can't fill a tile still tile: Simulator (it keeps its device's shape), Calculator,
  System Settings, apps with a minimum size. Each sits at the size it takes, centered in its slot,
  and its column is sized to fit it, so a phone in Simulator gets a narrow column and the window
  beside it gets the rest. Tessel learns what each window takes from how it answers being asked for
  a size (no lists to keep), the moment it first places it, so it goes straight to the size and
  column it fits; it remembers that across relaunches, and relearns it when the window changes
  its own size, like switching to another device. Tidy (⌘⇧0) starts that over for the windows in
  view.
- The green button's full screen just works: the rest of the Workspace stays put, and the window
  goes back to the same spot when it leaves full screen (into Focus again, if it was in Focus).

## Shortcuts

⌘ goes somewhere; ⌘⇧ moves or changes something.

| Keys | What it does |
| --- | --- |
| Left ⌘ + ← → ↑ ↓ | Focus the next window in that direction (crosses to the other screen at the edge) |
| Left ⌘ ⇧ + ← → | Move the window one step sideways: first it stacks with its neighbor, a second press moves it past |
| Left ⌘ ⇧ + ↑ ↓ | Swap with the window above or below in a stack |
| Left ⌘ ⇧ + plus / minus | Give the window more or less space (a lone window, or one in Focus, grows or shrinks around the center) |
| Left ⌘ ⇧ + R | **Resize**: then the arrows push the window's edges (hold to keep going); Return or Esc when done |
| Left ⌘ ⇧ + F | **Focus**: the window alone in the center, the rest of the Workspace on the Shelf. Again, a click on a Shelf card, ⌘ (or ⌘ ⇧) with any arrow, or a file dragged onto a Shelf card ends it |
| Left ⌘ ⇧ + H | **Hide** the window: it moves to the last Workspace (3, unless you added more) |
| Left ⌘ ⇧ + Delete | Close the window (like clicking its close button, so unsaved-changes prompts still appear) |
| Left ⌘ + 1 / 2 / 3 | Go to that Workspace |
| Left ⌘ ⇧ + 1 / 2 / 3 | Move the focused window to that Workspace and go there with it |
| ⇧ Space | **Summon**: open an app, or go to any open window, file or website |
| Left ⌘ ⇧ + Space | The **Cheat Sheet**: every shortcut, with search |

**Resize mode** (Left ⌘ ⇧ + R): an arrow pushes the window's edge on its side, so it works the way
the window sits. In the right column ← makes it wider and → narrower; in the left column the other
way round; at the top of a stack ↓ makes it taller, at the bottom ↑. Only the edge it shares with
its neighbor moves. A centered window (alone, or in Focus) grows with → and ↑ and shrinks with ←
and ↓, around its center. + and − grow or shrink the window all round, like ⌘⇧+ and ⌘⇧−. A green outline
around the window and a line at the bottom of the screen say it's on; it ends with Return,
Esc, any other key, or after five seconds without one.

Workspaces are ⌘ and their number, and ⌘⇧ and the number takes the window along, like ⌘⇧ and an
arrow moves it. Right ⌘ and a number still reaches the app in front (a browser's tabs, say), right
⌘⇧3, ⌘⇧4 and ⌘⇧5 still take screenshots, and ⌘ (or ⌘⇧) and the number of a Workspace you don't have
is left alone, so with three Workspaces ⌘⇧4 and ⌘⇧5 are the Mac's screenshot keys on either side. **Add a Workspace** and
**Remove Workspace N** are in the menu; a removed Workspace's windows move to the one before it.
(Earlier versions had you pick three Workspace keys; a shortcut you changed back then keeps them.)

## Names

| Name | What it is |
| --- | --- |
| **Summon** | The ⇧Space search bar: apps, then open windows, then files and folders, then the web |
| **Focus** | ⌘⇧F: one window centered, the rest on the Shelf |
| **the Shelf** | The tilted cards beside a Focus window |
| **Tidy** | ⌘⇧0: even out every split in the space |
| **Hide** | ⌘⇧H: send the window to the last Workspace |
| **Cheat Sheet** | ⌘⇧Space: every shortcut, searchable |
| **Halo** | The blue outline around the focused window |
| **Workspaces 1–3** | Tessel's own instant Workspaces, on ⌘1, ⌘2 and ⌘3 (up to nine if you add them) |

## Your own shortcuts

Every command can be rebound: menu bar › Settings › **Keyboard Shortcuts…** (or **Customize…** in the
Cheat Sheet). Click a shortcut and press new keys. Tessel refuses a combination another command already
uses, or one that would get in the way of typing; **Show defaults** lists the original keys next to yours,
and each changed shortcut has its own reset, plus **Restore All Defaults**. Changes are saved as
overrides on top of the defaults (`Sources/TesselCore/Keymap.swift`).

The Cheat Sheet's search forgives: synonyms ("maximize", "minimize", "virtual desktop"), symbols
(⌘ ⇧ ← ↩), abbreviations (cmd, alt), filler words ("how do I make it bigger") and typos. When nothing
matches exactly it shows the closest lines instead of an empty list.

## Summon

Press **⇧ Space** (Shift, then Space, with nothing in between, so typing a capital
and a space quickly never opens it). Type part of an app's name: prefixes, word starts
("code" for Visual Studio Code), initials ("vsc") and letters in order ("xcd") all match.
Apps you open often rise to the top.

- An app with a window you can get to (tiled in a space, minimized, or floating on screen) shows two rows: **go to its window** (switching spaces if
  needed) and **New … window** (⇧↩), which uses the app's own File › New Window and lands
  tiled and focused in the current space.
- **Open windows** are found by the words in their titles: type "invoice", "lunch" or "Tiler"
  and the window whose title has a word starting that way is listed, with its app and Workspace
  beneath. Return goes to it wherever it is: another Workspace, another display, or minimized in
  the Dock. A word can also be the app's name ("slack" lists each Slack window). Windows that match
  more of what you typed come first, then the ones you used most recently. Window rows sit below
  apps whose name you typed and above files. It's plain word matching on titles read as Summon
  opens, so typing never waits on another app, and titles are never saved.
- **Files and folders** come from Spotlight's index as you type (two letters or more), after apps
  and windows, three at most. Only things you'd look for: documents, pictures, video, music and
  downloads (not data, scripts, code or logs that programs leave behind), in your Desktop,
  Documents and Downloads, iCloud Drive and cloud folders (Dropbox, Google Drive), at most three
  folders in. A name that is what you typed comes first, then names that start with it, then names
  with a word starting each typed word; among those, the most recently used.
- **Apps go by their other names too**: "simulator" finds Device Hub (Xcode 27 put Simulator in
  it), "system preferences" finds System Settings, "itunes" finds Music. Xcode's own tools are
  found wherever that version of Xcode keeps them, and so are apps in another drive's
  Applications folder.
  macOS hides the files in Desktop, Documents and Downloads from apps it hasn't let into those
  folders, Spotlight's answers included, and only asks once an app looks inside one. Tessel never
  looks on its own, so nothing pops up while you type: until you've answered, file searches end
  with **Find files on your Desktop and in Documents too**. Choose it and Tessel reads those
  folders (and iCloud Drive's Desktop and Documents) once, macOS asks whether to allow each, and
  Summon opens again on the same search. Its second line, **Don't show this again** (⇧↩), hides
  the row instead. Either way it never comes back, and with Full Disk Access it never shows. To
  change an answer later, use Files & Folders in Privacy & Security.
- Opening an app that isn't running yet (or is running with no windows), or a **New … window**,
  makes room right away, so a slow launch never looks like nothing happened: the windows here glide
  aside and a frosted **placeholder** with the app's icon, gently pulsing, holds the exact spot and
  size the window will get (alone, or in Focus, it's centered at 16:10). The app's first new window lands right in it and nothing else moves; any more windows
  it opens tile as usual. If no window comes within about 8 seconds (a little longer while a big app
  is still starting up), the app quits, or its window opens while you're in another Workspace, the
  placeholder fades and the gap closes. A placeholder belongs to its Workspace like a window does.
  You can't click or focus it.
- ↑ ↓ to choose, Return to open, ⇧↩ for a new window, Esc or ⇧ Space to close. When nothing matches, it offers to search the web with your Mac's search engine in your default browser (or opens a typed address). The page opens as a new tab in the browser's window in this Workspace, or in a new window here when it has none, never a pop-up like Little Arc. This works with Arc, Safari, Chrome, Edge, Brave and Vivaldi; the first time, macOS asks whether Tessel may control the browser. Other browsers, or a browser you said no to, get the link the usual way, and Tessel still tiles whatever window it lands in.

With the mouse: drag a tiled window onto another to swap them, onto the other screen to move it
there, or drag its edge to resize. A centered window (alone, or in Focus) stretches on both sides as you drag an edge or corner, as if ⌥
were held, so it stays centered, and keeps the shape you give it; Tidy (⌘⇧0) returns it to the default size without leaving Focus. ⌘-Tab to a window in another space switches to that space.

The Dock works the same way: clicking a running app's icon goes to that app, using its window in
the current Workspace if it has one, else switching to the Workspace its window is in. An app that
isn't running, or has no windows, opens a new window here, with a placeholder holding its spot
just as Summon does. Only these opens get one: apps opened from Finder or Spotlight, login items
and background launches tile when their windows appear, as always. **New Window** from the icon's
right-click menu opens here too, and picking one of the app's windows from that menu goes to it.
Summon is the one that brings things to you: whatever it opens lands in the current Workspace.

The menu bar shows the current space. Its menu can pause tiling, put the focused window in Focus (or end Focus),
normalize, re-tile everything, and open **Keyboard Shortcuts…** (the same searchable list as Left ⌘⇧Space). **Settings** holds Launch at Login, Set Up Space Keys, and
**Use All Displays** (on by default). Turn that off to tile only on the main display, for example
when the second display is a dummy plug: windows that open on other displays move to the main one,
while a window something moves onto another display (an agent testing on a dummy plug) is left there.

## How it works

- `Sources/TesselCore` is the layout engine: columns of stacked windows per display, plus the
  directional-focus search. No AppKit, fully unit-tested (`swift test`).
- `Sources/Tessel` is the app:
  - `HotkeyTap` is a CGEventTap on its own high-priority thread. It tells left from right ⌘ by the
    device-dependent modifier bit.
  - `Tiler` tracks apps and windows through the Accessibility API and owns the per-display,
    per-space layouts.
  - `Animator` moves windows off the main thread, with one serial queue per window, so an app's
    windows move together. It measures each app's response time and picks full animation,
    slide-only, or snap; a glide that stalls partway finishes in one move.
  - `Overlays` draws the focus ring and the space badge with Core Animation in click-through panels.
  - `Placeholders` draws a placeholder tile: a click-through frosted panel just above the desktop, under
    every app's windows, so the arriving window glides in over it. In a layout a placeholder is just a
    window ID from a reserved range (`Placeholder` in TesselCore), so it gets exactly the new window's
    slot, and `Layout.fill` swaps the real window in. Placeholders are never saved.
- Windows in other spaces are parked just off the bottom-right corner of the right-most screen.
  Quitting Tessel (menu, `kill`, or reinstall) brings them back first.
- Tessel saves each Workspace's layout as it changes: which windows share a stack, the column
  order, and the sizes you gave them. Relaunching (or pausing and resuming tiling) puts every
  window that's still open back in the same Workspace, display, stack and column, at the same
  size. Windows opened in the meantime join as new windows do.

## Build and install

```bash
./scripts/build.sh --install
```

This builds a release binary, wraps it in `build/Tessel.app`, signs it with the Apple Development
identity (so macOS keeps the Accessibility permission across rebuilds), copies it to
`/Applications`, and relaunches it. The first launch asks for Accessibility access in
System Settings → Privacy & Security.

## Scripting and debugging

Tessel listens for distributed notifications named `com.tyleryouens.tessel.command`:

```bash
osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("com.tyleryouens.tessel.command", "focus-left", $(), true)'
```

Commands: `welcome`, `welcome-<step 0…4>`, `welcomeclose`, `find:<text>` (opens the launcher with that text), `help`, `help:<text>`, `launcher`, `launcher-open|up|down`, `focus-left|right|up|down`, `move-…`, `grow`, `shrink`, `close` (the focused window) or `close-<windowID>`, `hide`, `spotlight`, `space-1…3`, `send-1…3`,
`balance`, `retile`, `displays-all`, `displays-main`, `pause`, `resume`, `expect:<bundle id>` (holds a
placeholder for a window of that app, without opening anything, to try placeholders), `leave-app:<bundle id>` and
`manage-app:<bundle id>` (stop and resume tiling one app's windows, for agents testing it on a
dummy-plug display), the learning commands (see below), and `dump`, which writes the
current state to `~/Library/Application Support/Tessel/state.json`.

`pause` and `resume` do what the menu's **Tiling** item does. Pausing brings back windows parked in
other spaces, stops tiling, and lets every shortcut through to apps. Both are safe to send twice.
Agents that drive the screen (computer use, screen recordings, anything that needs a window at an
exact size) should pause first and resume when they're done:

```bash
osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("com.tyleryouens.tessel.command", "pause", $(), true)'
```

```bash
osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("com.tyleryouens.tessel.command", "resume", $(), true)'
```

**Testing window handling:** `scripts/windowlab/build.sh` builds WindowLab, a small app that opens every
kind of window Tessel has to handle on command: fixed-size, minimum or maximum size, keeps its shape,
an alert, an About box, a utility panel, two at once, one that animates itself like Little Arc, and one
that switches "device"; it can also open a burst of windows (an app restoring them), answer slowly
(Arc at times), or draw slowly (a browser). `scripts/windowlab/windowlab report:<path>` writes where
each one ended up. Run it in a test VM, never on a Mac someone is using.
`scripts/windowlab/smooth.py` is the smoothness benchmark: it records every window's frame every 2 ms
(`motion.swift`) through arrivals, a burst, an app restoring its windows, closing, moving, swapping,
growing, Tidy, Focus, Workspace switches and windows that can't fill a tile, and counts each window's
separate motions and stops, the time until everything settles, edges that shake, and overlap
(results: [docs/smoothness.md](docs/smoothness.md)). `dump`'s state includes each window's learned
size limits.

Logs (`/usr/bin/log`, since zsh has its own `log` builtin):

```bash
/usr/bin/log stream --predicate 'subsystem == "com.tyleryouens.tessel"' --info
```

## Learning where your windows go (off by default for now)

**Settings › Learn Where Windows Go** turns it on. Tessel then learns from what you do, entirely
on this Mac ([docs/learning.md](docs/learning.md)):

- **It knows what kind of window it's looking at.** A window classifier decides, as each window
  appears, whether it's a document (tiles), a tool panel, a here-and-gone window, a video or call,
  or a dialog the rules missed, in well under a millisecond. **What Tessel Learned › How Tessel
  Sees Your Windows** shows its call for every open window ([docs/window-classifier.md](docs/window-classifier.md)).
- **It floats what you'd float.** Float a window from the menu (**Float This Window**), or drag
  it out of its tile twice in a row, and the next window like it floats by itself. A full
  document window takes two.
- **It opens apps in your usual arrangement.** A split you made and kept comes back when one of
  the apps opens again beside the others, and so does the size you gave a lone window. When a
  fourth window would make a 2×2 grid, a shape you made instead (say, Claude alone on the left at
  full height, the rest stacked on the right) comes back whenever that app is one of the four.
- **It sends new windows to the Workspace they belong in.** Move an app's window to a Workspace
  and keep it there for ten minutes, and its new windows open there. Windows you open from
  Summon or the Dock still come to you.

It only decides where a new window lands (and, with a fourth window, the grid's shape), never
takes focus, and never asks anything. Each time it acts, a quiet line at the bottom of the screen
says what happened, and ⌘ with the number of the Workspace you were in undoes it. Undo the same thing twice and Tessel forgets it.
**Settings › What Tessel Learned** lists every lesson in words: click one to forget it, or reset
them all. It keeps everything in `~/Library/Application Support/Tessel/Learning`, out of
backups, and never sends any of it anywhere.

Commands: `learning-on`, `learning-off`, `classes` / `classify` (the window classifier's calls),
`snapshot:<path>` (every window with its traits, for building the labeled set in the test VMs),
`float` (float or tile the focused window),
`learning-reset`, and `learning-lived:<seconds>` (counts that much window time at once, to try
Workspace homes without waiting). `dump` adds a `learning` section.

## Website

`site/` is the landing page: `index.html` (self-contained apart from Google Fonts) and the logo as
`logo.svg`. It sells Tessel at $9.99 USD, one-time, with lifetime updates, and walks through every
feature with an animated mini Mac. Preview it with `python3 -m http.server 4173 --directory site`.

The Buy buttons go nowhere yet: set `CHECKOUT_URL` at the top of the page's script once a checkout
(Lemon Squeezy, Paddle, Stripe, …) exists. Until then they scroll to pricing and say checkout opens soon.

## Staying out of your way

- **Crashes:** Open at Login runs Tessel as a launchd agent. If it ever crashes, it's back within
  seconds and puts every window where it was. Parked windows never stay stranded, and Quit still quits.
- **Displays coming and going:** when a display is unplugged, its windows move to another display.
  When it comes back, they return to their spots on it. Changes wait a second to settle, so a display
  blinking off as the Mac wakes doesn't shuffle anything.
- **macOS 27:** a parked window that macOS pulls back into view is parked again.
- **Native tabs** share one tile. **Dialogs** float, centered. **Windows that can't fill a tile** tile at their own size. **Full screen** windows keep their spot.
  **Show Desktop** works as usual.
- **Updates:** Sparkle checks once a day and asks before installing (see docs/store.md).

## Selling it

Buying, licensing, the free trial and the release are described in [docs/store.md](docs/store.md).
