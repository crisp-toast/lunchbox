# Tessel

A small, fast tiling window manager for macOS that lives in the menu bar.

- One window on a screen sits centered at a comfortable 16:10 size. Two or more tile side by side.
- Everything is driven by the **left** ⌘ key, so right ⌘ + arrows still move the text cursor.
- Windows slide into place. Apps that can't keep up just snap, so Tessel never adds lag.
- Three Workspaces, switched instantly from the keyboard.
- Dialogs (Open, Save, alerts, password prompts) float, centered on their screen, instead of
  splitting the tiled windows apart.
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
| Left ⌘ ⇧ + F | **Focus**: the window alone in the center, the rest of the Workspace on the Shelf. Again, a click on a Shelf card, ⌘ (or ⌘ ⇧) with any arrow, or a file dragged onto a Shelf card ends it |
| Left ⌘ ⇧ + H | **Hide** the window: it always moves to Workspace 3 |
| Left ⌘ ⇧ + Delete | Close the window (like clicking its close button, so unsaved-changes prompts still appear) |
| ⌘ + Workspace key 1 / 2 / 3 | Go to that Workspace |
| ⌘ ⇧ + Workspace key 1 / 2 / 3 | Move the focused window to that Workspace and go there with it |
| ⇧ Space | **Summon**: open an app, file or website |
| Left ⌘ ⇧ + Space | The **Cheat Sheet**: every shortcut, with search |

The Workspace keys are whatever three keys you pick on first launch (menu → **Set Up Workspace Keys…**).
On Tyler's Boop65 they're the three keys on the far right, above the right arrow.

## Names

| Name | What it is |
| --- | --- |
| **Summon** | The ⇧Space search bar: apps, then files and folders, then the web |
| **Focus** | ⌘⇧F: one window centered, the rest on the Shelf |
| **the Shelf** | The tilted cards beside a Focus window |
| **Tidy** | ⌘⇧0: even out every split in the space |
| **Hide** | ⌘⇧H: send the window to Workspace 3 |
| **Cheat Sheet** | ⌘⇧Space: every shortcut, searchable |
| **Halo** | The blue outline around the focused window |
| **Workspaces 1–3** | Tessel's own instant Workspaces, on your three **Workspace keys** |

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
- When no app matches, it searches Spotlight's index for files and folders, most
  recently used first.
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
there, or drag its edge to resize. A centered window (alone, or in Focus) keeps any shape you
drag it to and glides back to the center; Tidy (⌘⇧0) returns it to the default size without leaving Focus. ⌘-Tab to a window in another space switches to that space.

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
  - `Animator` moves windows off the main thread, with one serial queue per app. It measures each
    app's response time and picks full animation, slide-only, or snap.
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
dummy-plug display), `float` and `learning-reset` (see Learning below), and `dump`, which writes the
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

Logs (`/usr/bin/log`, since zsh has its own `log` builtin):

```bash
/usr/bin/log stream --predicate 'subsystem == "com.tyleryouens.tessel"' --info
```

## Learning (prototype, off by default)

Tessel can learn which windows you want floating instead of tiled, from your corrections, entirely
on this Mac ([docs/learning.md](docs/learning.md) has the whole plan). Turn it on with
`defaults write com.tyleryouens.tessel learnFloating -bool YES`, then pause and resume tiling. The
menu gains **Float This Window** / **Tile This Window** (also the `float` command), and dragging a
tiled window out of its tile twice in a row floats it where you drop it. The next window of the same
kind follows. **Settings › Reset What Tessel Learned** (or `learning-reset`) forgets it all. The log
is `~/Library/Application Support/Tessel/Learning/float.jsonl`, and `dump` adds a `learning` section.

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
- **Native tabs** share one tile. **Dialogs** float, centered. **Full screen** windows keep their spot.
  **Show Desktop** works as usual.
- **Updates:** Sparkle checks once a day and asks before installing (see docs/store.md).

## Selling it

Buying, licensing, the free trial and the release are described in [docs/store.md](docs/store.md).
