# Tessel

A small, fast tiling window manager for macOS that lives in the menu bar.

- One window on a screen sits centered at a comfortable 16:10 size. Two or more tile side by side.
- Everything is driven by the **left** ⌘ key, so right ⌘ + arrows still move the text cursor.
- Windows slide into place. Apps that can't keep up just snap, so Tessel never adds lag.
- Three spaces, switched instantly from the keyboard.

## Shortcuts

| Keys | What it does |
| --- | --- |
| Left ⌘ + ← → ↑ ↓ | Focus the next window in that direction (crosses to the other screen at the edge) |
| Left ⌘ ⇧ + ← → | Move the window one step sideways: first it stacks with its neighbor, a second press moves it past |
| Left ⌘ ⇧ + ↑ ↓ | Swap with the window above or below in a stack |
| Left ⌘ ⇧ + plus / minus | Give the window more or less space (a lone window grows or shrinks around the center) |
| Left ⌘ ⇧ + Delete | Close the window (like clicking its close button, so unsaved-changes prompts still appear) |
| Left ⌘ ⇧ + H | Hide the window by sending it to the next space (1 → 2 → 3 → 1) |
| ⌘ ⇧ + space key 1 / 2 / 3 | Switch to that space |
| ⌥ ⌘ ⇧ + space key 1 / 2 / 3 | Send the focused window to that space |

The space keys are whatever three keys you teach it on first launch (menu → **Set Up Space Keys…**).
On Tyler's Boop65 they're the three keys on the far right, above the right arrow.

With the mouse: drag a tiled window onto another to swap them, onto the other screen to move it
there, or drag its edge to resize. ⌘-Tab to a window in another space switches to that space.

The menu bar shows the current space. Its menu can pause tiling, float or tile the focused window,
even out sizes, and re-tile everything. **Settings** holds Launch at Login, Set Up Space Keys, and
**Use All Displays** (on by default). Turn that off to tile only on the main display, for example
when the second display is a dummy plug: windows on other displays move to the main one.

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
- Windows in other spaces are parked just off the bottom-right corner of the right-most screen.
  Quitting Tessel (menu, `kill`, or reinstall) brings them back first.

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

Commands: `focus-left|right|up|down`, `move-…`, `grow`, `shrink`, `close` (the focused window) or `close-<windowID>`, `hide`, `space-1…3`, `send-1…3`,
`balance`, `retile`, `displays-all`, `displays-main`, `pause`, `resume`, and `dump`, which writes the current state to
`~/Library/Application Support/Tessel/state.json`.

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
