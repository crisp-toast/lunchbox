# LunchboxWM

A small, fast tiling window manager for macOS that lives in the menu bar.

- One window on a big display sits centered at a comfortable 16:10 size (never smaller than
  1440×900); on a laptop's screen, or any without room to spare around that, it fills the screen
  (⌘⇧− makes it smaller, still centered). Two tile side by side; a third
  goes beneath the second, so the first keeps its half; a fourth goes beneath the first, making a
  2×2 grid without any window crossing the screen. Ultrawide displays give each new window a column
  of its own (up to four), and any window can be moved into more columns by hand.
- Everything is driven by the **left** ⌘ key, so right ⌘ + arrows still move the text cursor.
- Windows slide into place, in one move each. Apps that can't keep up, or stall now and then, just
  snap, so LunchboxWM never adds lag; and an app's windows move together, never one after another. An
  app opening several windows at once (restoring them at launch) has them laid out together, instead
  of the layout reflowing once per window.
- A new window goes straight into its tile, within a frame or two of appearing, instead of
  showing up where its app put it and gliding over. LunchboxWM moves it the moment the app makes it,
  often before it's even on screen.
- Three Workspaces on ⌘1, ⌘2 and ⌘3, switched instantly. Add more (up to nine) from the menu.
  Whenever you change Workspace, however you got there, "Workspace 2" shows at the top of the
  screen for a moment, with a dot for each Workspace.
- **Sort My Windows** sorts a messy desktop into Workspaces by kind: your work, the web, and chat and
  music, in that order, using only as many Workspaces as it takes (up to three). A Workspace holds
  only as many windows as fit two to a column (four, a 2×2, on most displays; six on an ultrawide):
  a few windows stay together, small kinds share a Workspace while they fit, and a big kind spills
  into the next free Workspace. With all three taken, they share a third row (six on most displays);
  only past that do the ones you've used least lately go out of the way, still open, parked
  off screen like Hide: Summon, the Dock or ⌘-Tab brings one back (80 windows: three Workspaces of
  six, 62 out of the way, and setup says so before you agree).
  It goes by how you work, not just what the windows are:
  - **What matters most** is mostly how long each window has been in front lately while you were at
    the Mac (fading by half every half hour), partly how recently you used it: Lunchbox's own record,
    then for windows from before it started, the order macOS keeps apps in for ⌘-Tab. So after an
    hour in Xcode and a glance at Messages, you land in your work with Xcode first, not in chat.
  - **What belongs together stays together.** A browser window you keep going back and forth with
    from your work (the docs beside your code, the page you're building) stays beside it. A kind too
    big for one Workspace splits by task: windows you go between, an app's windows, and windows whose
    titles name the same project (Lunchbox in Xcode, Terminal and VS Code in one Workspace, Delta
    Binder's in the next).
  - **The room goes where it's used.** Each Workspace's layout is worked out, not just evened out:
    every way of putting its windows in columns and stacks is tried, with each split nudged a step at a
    time, the window that matters most top left. The window you've been in gets the big tile when one
    clearly stands out; chat, music, terminals and notes take a narrow column so a browser or editor
    gets the width (three chats on a desktop display get a tall column each); bigger windows sit above
    smaller ones in a stack; and minimum sizes are kept. It never squeezes a window that's easy to use
    at an even share below that to grow another, and windows used about as much, or a crowded
    Workspace, stay even. Apps for making music (Logic, GarageBand, DAWs) count as your work.
  How long windows were in front is kept in memory only, and goes when the window closes.
  A short show covers the screen in color while the windows move and
  flies each window to its Workspace so you see where everything went. Then it waits for you to pick
  the Workspace to start in: click one, press its number or its Workspace key (⌘1), or use ← → and
  Return (the one with the window that matters most is lit up first). It opens onto that Workspace's
  real windows; with only one Workspace there's nothing to pick, and it opens by itself. A soft chord
  and bells play with it when macOS plays interface sounds, and the chord opens up again with the
  Workspace you pick; with Reduce Motion nothing flies. Click or Esc skips straight to picking. Undo
  (on the note afterwards, which stays until you close it, and in the menu for ten minutes) puts
  everything back. Setup ends with it whenever two or more windows are open (Not Now skips it);
  otherwise it's in the menu. It never runs on its own.
- **Start Fresh**, the other choice on that setup step, closes every window instead, each as if you
  clicked its red button: apps still ask before closing anything unsaved, nothing is forced, no app
  quits, and windows with no close button are left alone. It asks first (Return cancels), says how
  many it closed and how many are still open, and is in setup only.
- Dialogs (Open, Save, alerts, password prompts) float, centered on their screen, instead of
  splitting the tiled windows apart, and stay in view when you switch Workspaces. So do small
  windows that can't be resized or minimized, like About boxes and progress windows. A "dialog"
  with every title-bar button that you can resize, like Little Arc, is a window in all but name and
  tiles like one.
- Windows that can't fill a tile still tile: Simulator (it keeps its device's shape), Calculator,
  System Settings, apps with a minimum size. Each sits at the size it takes, centered in its slot,
  and its column is sized to fit it, so a phone in Simulator gets a narrow column and the window
  beside it gets the rest. LunchboxWM learns what each window takes from how it answers being asked for
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
| Left ⌘ ⇧ + R | **Resize**: then the arrows (or your focus keys) push the window's edges (hold to keep going); Return or Esc when done |
| Left ⌘ ⇧ + F | **Focus**: the window alone in the center, the rest of the Workspace on the Shelf. Click a Shelf card to swap that window into the center. Again, ⌘ (or ⌘ ⇧) with any arrow, or a file dragged onto a Shelf card ends it, every window back in its tile |
| Left ⌘ ⇧ + H | **Hide** the window: it goes out of sight, parked off the screen the way other Workspaces' windows wait, still open; the others close the gap |
| Left ⌘ ⇧ + Delete | Close the window (like clicking its close button, so unsaved-changes prompts still appear) |
| Left ⌘ + 1 / 2 / 3 | Go to that Workspace |
| Left ⌘ ⇧ + 1 / 2 / 3 | Move the focused window to that Workspace and go there with it |
| ⇧ Space | **Summon**: open an app, or go to any open window or website |
| Left ⌘ ⇧ + Space | The **Cheat Sheet**: every shortcut, with search |

**Prefer Vim keys?** Pick **Vim keys (H J K L)** on the setup's practice screen, or under Settings › Keyboard Shortcuts › Move around with. Left ⌘ and H J K L then move focus, ⇧ adds the window, Hide moves to ⇧ Left ⌘ M, and in Resize H J K L push the edges too. Every shortcut can also be changed one by one.

**Resize mode** (Left ⌘ ⇧ + R): an arrow pushes the window's edge on its side, so it works the way
the window sits. In the right column ← makes it wider and → narrower; in the left column the other
way round; at the top of a stack ↓ makes it taller, at the bottom ↑. Only the edge it shares with
its neighbor moves. A centered window (alone, or in Focus) grows with → and ↑ and shrinks with ←
and ↓, around its center. + and − grow or shrink the window all round, like ⌘⇧+ and ⌘⇧−. A green outline
around the window and a line at the bottom of the screen say it's on; it ends with Return,
Esc, any other key (⌘ and an arrow ends it and moves focus, as usual), or after five seconds
without one.

Shrinking stops where the window does. A window that won't go any smaller (most apps have a
minimum size) takes no more ⌘⇧− or arrow presses, so the next press to grow it always shows.
The same goes for growing a window that's as big as it gets.

Workspaces are ⌘ and their number, and ⌘⇧ and the number takes the window along, like ⌘⇧ and an
arrow moves it. Right ⌘ and a number still reaches the app in front (a browser's tabs, say), right
⌘⇧3, ⌘⇧4 and ⌘⇧5 still take screenshots, and ⌘ (or ⌘⇧) and the number of a Workspace you don't have
is left alone, so with three Workspaces ⌘⇧4 and ⌘⇧5 are the Mac's screenshot keys on either side. **Add a Workspace** and
**Remove Workspace N** are in the menu; a removed Workspace's windows move to the one before it.
(Earlier versions had you pick three Workspace keys; a shortcut you changed back then keeps them.)

## Names

| Name | What it is |
| --- | --- |
| **Summon** | The ⇧Space search bar: apps, then open windows, then the web |
| **Focus** | ⌘⇧F: one window centered, the rest on the Shelf |
| **the Shelf** | The tilted cards beside a Focus window |
| **Tidy** | ⌘⇧0: even out every split in the space |
| **Hide** | ⌘⇧H: put the window out of sight, in no Workspace. Summon lists it as Hidden; choosing it, or going to its app with ⌘-Tab or the Dock, brings it back, tiled where you are. Pausing or quitting LunchboxWM brings hidden windows back too |
| **Cheat Sheet** | ⌘⇧Space: every shortcut, searchable |
| **Halo** | The blue outline around the focused window |
| **Workspaces 1–3** | LunchboxWM's own instant Workspaces, on ⌘1, ⌘2 and ⌘3 (up to nine if you add them) |

## Your own shortcuts

Every command can be rebound: menu bar › Settings › **Keyboard Shortcuts…** (or **Customize…** in the
Cheat Sheet). Click a shortcut and press new keys. LunchboxWM refuses a combination another command already
uses, or one that would get in the way of typing; **Show defaults** lists the original keys next to yours,
and each changed shortcut has its own reset, plus **Restore All Defaults**. Changes are saved as
overrides on top of the defaults (`Sources/LunchboxCore/Keymap.swift`).

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
  apps whose name you typed. It's plain word matching on titles read as Summon
  opens, so typing never waits on another app, and titles are never saved.
- **Apps go by their other names too**: "simulator" finds Device Hub (Xcode 27 put Simulator in
  it), "system preferences" finds System Settings, "itunes" finds Music. Xcode's own tools are
  found wherever that version of Xcode keeps them, and so are apps in another drive's
  Applications folder.
- **No files.** Summon doesn't search files: that would need macOS's permission prompts for
  Desktop, Documents and Downloads. Spotlight (⌘Space) is right there for files.
- Opening an app that isn't running yet (or is running with no windows), or a **New … window**,
  makes room right away, so a slow launch never looks like nothing happened: the windows here glide
  aside and a frosted **placeholder** with the app's icon, gently pulsing, holds the exact spot and
  size the window will get (alone, or in Focus, it's centered at 16:10, or alone on a laptop, the whole screen). The app's first new window lands right in it and nothing else moves; any more windows
  it opens tile as usual. If the app shows something that doesn't tile instead (Xcode's welcome
  window, a template chooser, a dialog), brings back a window it already had, or closes what it
  showed, the placeholder goes at once. If no window comes within about 8 seconds (a little longer
  while a big app is still starting up), the app quits, or its window opens while you're in another
  Workspace, the placeholder fades and the gap closes. A placeholder belongs to its Workspace like a window does.
  You can't click or focus it.
- ↑ ↓ to choose, Return to open, ⇧↩ for a new window, Esc or ⇧ Space to close. When nothing matches, it offers to search the web with your Mac's search engine in your default browser (or opens a typed address). The page opens as a new tab in the browser's window in this Workspace, or in a new window here when it has none, never a pop-up like Little Arc. This works with Arc, Safari, Chrome, Edge, Brave and Vivaldi; the first time, macOS asks whether LunchboxWM may control the browser. Other browsers, or a browser you said no to, get the link the usual way, and LunchboxWM still tiles whatever window it lands in.

With the mouse: drag a tiled window onto another to swap them, onto the other screen to move it
there, or drag its edge to resize. A centered window (alone, or in Focus) stretches on both sides as you drag an edge or corner, as if ⌥
were held, so it stays centered, and keeps the shape you give it; Tidy (⌘⇧0) returns it to the default size without leaving Focus.
Any arrangement of two or more windows stays centered and touching as you resize it. Drag an outer
side, top or bottom (one on the arrangement's edge) and only that window grows or shrinks, its edge
following the pointer, while the others keep their size and slide over. Windows that span the full
height change with a top or bottom, so the tops and bottoms stay lined up. Drag an outer corner and
the whole arrangement resizes evenly around the middle, every window keeping its share, the opposite
corners moving to match. Drag an edge between two windows and the split between them moves, both windows following as you drag. Corners reach a little way along each edge, as macOS's rounded corners do, and whatever you grab keeps its distance from the pointer. Nothing
gets smaller than a window allows. The size is for those windows: open or close one, or Tidy, and
the arrangement fills the screen again. ⌘-Tab to a window in another space switches to that space.

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
while a window you drag onto another display (or send there with a shortcut or Window › Move to) is
left there, untiled. An app moving its own window there (Simulator going back to where it was last)
gets it back in its tile, so nothing ends up on a screen you can't see; agents testing an app on a
dummy plug use `leave-app:` first (the mac-mini skill's `spoof.sh claim`).

## How it works

- `Sources/LunchboxCore` is the layout engine: columns of stacked windows per display, plus the
  directional-focus search. No AppKit, fully unit-tested (`swift test`).
- `Sources/LunchboxWM` is the app:
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
    window ID from a reserved range (`Placeholder` in LunchboxCore), so it gets exactly the new window's
    slot, and `Layout.fill` swaps the real window in. Placeholders are never saved.
- Windows in other spaces are parked just off the bottom-right corner of the right-most screen.
  Quitting LunchboxWM (menu, `kill`, or reinstall) brings them back first.
- LunchboxWM saves each Workspace's layout as it changes: which windows share a stack, the column
  order, and the sizes you gave them. Relaunching (or pausing and resuming tiling) puts every
  window that's still open back in the same Workspace, display, stack and column, at the same
  size. Windows opened in the meantime join as new windows do.

## Build and install

```bash
./scripts/build.sh --install
```

This builds a release binary, wraps it in `build/LunchboxWM.app`, signs it with the Apple Development
identity (so macOS keeps the Accessibility permission across rebuilds), copies it to
`/Applications`, and relaunches it. The first launch asks for Accessibility access in
System Settings → Privacy & Security.

## Scripting and debugging

LunchboxWM listens for distributed notifications named `com.sentientdonut.lunchbox.command`:

```bash
osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("com.sentientdonut.lunchbox.command", "pause", $(), true)'
```

Any process on the Mac can post one, so which commands LunchboxWM takes depends on the build, and that's
fixed when it's compiled (no setting or environment variable changes it):

- **Every build**, including the download customers get (`scripts/release.sh`): `pause`, `resume`,
  `retile` and `balance`. Anything else is ignored, and the log says `ignored command <name>`.
- **Development builds only** (`scripts/build.sh`, which passes `-DLUNCHBOX_DEV`, and `swift build`, a
  debug build): everything else. The test VMs (`vm.sh install-lunchbox`), WindowLab and Tyler's Mac run
  these. `release.sh` uses its own build folder (`.build/dist`) and refuses a binary that was compiled
  with them. Settings › Copy Diagnostics says which kind of build is running. A build.sh build is
  version 1 to Sparkle, so once a release ships it offers to update to it: on a Mac where agents need
  `leave-app:` (the mac-mini skill's `spoof.sh claim`) or `dump`, say no, or install build.sh's again.

The development commands: `welcome`, `welcome-<step 0…4>` (`@<display id>` opens it on that display without
taking focus), `welcomeclose`, `find:<text>` (opens Summon with that text), `help`, `help:<text>`,
`launcher`, `launcher-open|new|up|down`, `shortcuts`, `focus-left|right|up|down`, `move-…`, `grow`,
`shrink`, `close` (the focused window) or `close-<windowID>`, `hide`, `spotlight`, `space-1…9`,
`send-1…9`, `workspaces-3…9`, `displays-all`, `displays-main`, `press:<keycode>[:cmd][:shift][:opt]`
(presses the keys through the whole system, with LunchboxWM's Accessibility permission, for end-to-end
tests and demo recordings), `expect:<bundle id>` (holds a placeholder for a window of that app, without
opening anything, to try placeholders), `leave-app:<bundle id>` and `manage-app:<bundle id>` (stop and
resume tiling one app's windows, for agents testing it on a dummy-plug display), `license:<key>`,
`license:window`, `license:remove`, `license:snapshot:<png>`, `practice:<command>` (drives
onboarding's practice screen), `timeback-add:<action>:<count>[:<days ago>]`, `copy-diagnostics`,
`float` (float or tile the focused window), `sort` (Sort My Windows), `sort@<display id>` (only that
display's windows, without switching Workspace, taking focus or playing sound), `sort-demo@<display id>`
(the show with made-up windows of apps on the Mac, moving nothing), `sort-pick` (goes to the Workspace
lit up at the end of the show) and `sort-pick:<n>` (the show's nth, from 1; a test sort on one display
stays in the Workspace you're in), `sort-undo`, `sort-sound:<wav path>` (writes the show's sound, and
the part played when you pick a Workspace to `<name>-opening.wav` beside it), `fresh-app:<bundle id>@<display id>` (Start Fresh on one app's windows,
no question asked, its note on that display), `fresh-question` and `fresh-cancel` (setup's Start
Fresh question, for screenshots), and `dump`, which writes the current state (Summon's results with
file paths among it) to `~/Library/Application Support/LunchboxWM/state.json`.

`pause` and `resume` do what the menu's **Tiling** item does. Pausing brings back windows parked in
other spaces, stops tiling, and lets every shortcut through to apps. Both are safe to send twice.
Agents that drive the screen (computer use, screen recordings, anything that needs a window at an
exact size) should pause first and resume when they're done:

```bash
osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("com.sentientdonut.lunchbox.command", "pause", $(), true)'
```

```bash
osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("com.sentientdonut.lunchbox.command", "resume", $(), true)'
```

**Copy Diagnostics** (Settings) puts a summary for support on the clipboard: the LunchboxWM and macOS
versions, the build kind, the displays, the Workspaces and each one's windows (as app bundle IDs, what
kind of window LunchboxWM took each for, and the size limits it learned), the windows not in a tile, the
license state, and the last day's errors from LunchboxWM's log. It never includes window titles, file
paths, the license key or the email address: log lines go through `SupportSummary.scrub` first.

**Testing window handling:** `scripts/windowlab/build.sh` builds WindowLab, a small app that opens every
kind of window LunchboxWM has to handle on command: fixed-size, minimum or maximum size, keeps its shape,
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
/usr/bin/log stream --predicate 'subsystem == "com.sentientdonut.lunchbox"' --info
```

## Restarted apps, floating windows and installers

- **A restarted app goes back where it was.** When an app quits (an update, a crash, ⌘Q and
  back), LunchboxWM remembers where each of its tiled windows was. For an hour, its new windows go
  back to the same Workspace and spot instead of the one you're in. If you opened the app yourself
  you go with it; if it came back by itself you stay where you are, and a quiet line says where it
  went, with ⌘ and the number of the Workspace you were in to bring it to you instead.
- **Float This Window** (the menu, or the `float` command) takes the focused window out of the
  tiles at the size it opened at; **Tile This Window** puts it back.
- **A downloaded app's disk image window** ("drag the app to Applications") floats centered at the
  size its maker chose, like a dialog, instead of stretching into a tile.

## Website

`site/` is the landing page: `index.html` (self-contained apart from Google Fonts) and the logo as
`logo.svg`. It sells LunchboxWM at $4.99 USD, one-time, with lifetime updates, and walks through every
feature with an animated mini Mac. Preview it with `python3 -m http.server 4173 --directory site`.

The Buy buttons go nowhere yet: set `CHECKOUT_URL` at the top of the page's script once a checkout
(Lemon Squeezy, Paddle, Stripe, …) exists. Until then they scroll to pricing and say checkout opens soon.

## Staying out of your way

- **Crashes:** Open at Login runs LunchboxWM as a launchd agent. If it ever crashes, it's back within
  seconds and puts every window where it was. Parked windows never stay stranded, and Quit still quits.
- **Displays coming and going:** when a display is unplugged, its windows move to another display.
  When it comes back, they return to their spots on it. Changes wait a second to settle, so a display
  blinking off as the Mac wakes doesn't shuffle anything.
- **Sleep and the lock screen:** close a laptop's lid and open it again (or let the displays sleep,
  or lock the screen) and every Workspace is as you left it. While the Mac is away, and for a few
  seconds after it's back in use, windows keep their tiles whatever their apps say (apps answer
  slowly or not at all as they wake up); then every app is asked again. An app that doesn't answer
  never loses its windows' tiles for it, and a window that went missing without closing goes back
  to its own Workspace and spot when it turns up, never the one you're in.
- **macOS 27:** a parked window that macOS pulls back into view is parked again.
- **Native tabs** share one tile. **Dialogs** float, centered. **Windows that can't fill a tile** tile at their own size. **Full screen** windows keep their spot.
- **Mission Control, App Exposé and Show Desktop** take windows out of sight without moving
  anything: every tile stays where it was, and nothing reflows while they're up. **A hidden app**
  (⌘H, Hide Others) gives up its tiles while it's hidden, and its windows come back to the same
  spots, each in its own Workspace, when it's shown again (Show All too).
- **Updates:** Sparkle checks once a day and asks before installing (see docs/store.md).

## Selling it

Buying (paid up front, $4.99, no free trial), licensing and the release are described in [docs/store.md](docs/store.md).
