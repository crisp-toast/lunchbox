# Older macOS

LunchboxWM promises macOS 14 or later. Until 2026-10-16 it had only run on the Mac mini's macOS 27 beta.
This is what happened when it ran on macOS 14, 15 and 26 in virtual machines.

**Verdict: keep "macOS 14 or later".** Sonoma, Sequoia and Tahoe pass every feature tested.
Two real bugs turned up along the way, and both are fixed (below): Sequoia found the first (macOS window
tiling), and Tahoe found the second (focus after a dialog closes). Neither is specific to the
version it was found on.

## How it was tested

- Tart VMs on the Mac mini (Cirrus Labs vanilla images, 1920×1080, 4 GB), one at a time:
  Sonoma 14.8.7 (23J520), Sequoia 15.7.7 (24G720), Tahoe 26.6.2 (25G83).
- The release build: `scripts/release.sh 1.0 --dry-run` (arm64, hardened runtime, Apple
  Development signature, `minos 14.0`), copied into `/Applications`.
- Accessibility and Screen Recording were granted in each VM's own System Settings. macOS asks
  for the admin password for both. Driven over the VM's VNC screen and LunchboxWM's `com.sentientdonut.lunchbox.command` notifications.
- The VMs' VNC keyboard can't send Page Up or Page Down, so the Workspace keys were pressed with
  LunchboxWM's `press:<keycode>:cmd[:shift]` command instead. That goes through the same event tap a
  real keyboard does.
- Test apps: TextEdit (documents, the Open panel, native tabs), Finder, and on Tahoe Terminal.

## Results

✓ passes · ✗ broke · – not run

| Feature | 14 Sonoma | 15 Sequoia | 26 Tahoe |
|---|---|---|---|
| Launches (no missing symbols), menu bar icon | ✓ | ✓ | ✓ |
| Onboarding, Accessibility prompt and Settings link | ✓ | ✓ | ✓ |
| Screen Recording prompt and Settings link | ✓ | ✓ | ✓ |
| Open at Login (SMAppService agent; "Background Items Added") | ✓ | ✓ | ✓ ("App Background Activity") |
| Opening the app by hand hands off to the agent | ✓ | ✓ | ✓ |
| Basic tiling: lone window centered 16:10 (full screen on a laptop), columns and stacks, 8 pt gaps | ✓ | ✓ | ✓ |
| Focus and move shortcuts (left ⌘), Halo | ✓ | ✓ | ✓ |
| Three Workspaces, windows parked off the corner | ✓ | ✓ | ✓ (a 1 pt sliver shows, below) |
| Focus and the Shelf; a card click ends Focus | ✓ with live previews | ✓ (previews denied, so app icons) | ✓ with live previews |
| Dialogs float centered (TextEdit Open panel), tiles untouched | ✓ | ✓ | ✓ |
| Closing a dialog gives focus back to the window that opened it | – (same code) | – (same code) | ✗ → fixed ✓ |
| Native tabs share one tile (Merge All Windows, ⌃Tab) | ✓ | ✓ | ✓ |
| Full screen and back to the same tile | ✓ (also Split View) | ✓ | ✓ |
| Show Desktop (F11) and back | ✓ | ✓ | ✓ |
| Sonoma's click-wallpaper-to-show-desktop | ✓ | n/a | ✓ (off by default; turned on to test) |
| macOS window tiling (Window › Fill, drag to the top edge) | n/a | ✗ → fixed ✓ | ✓ (with the fix) |
| Crash relaunch (SIGSEGV under the agent), parked windows kept | ✓ | ✓ | ✓ |
| Trial ends: tiling pauses, license window; restored from the Keychain copy | ✓ | ✓ | ✓ |
| License window, invalid key, trial-ended view | ✓ | ✓ | ✓ |
| Sparkle "Check for Updates…" window | ✓ | ✓ | ✓ |
| Summon and the Cheat Sheet | ✓ | ✓ | ✓ |

Sparkle's check itself can't finish anywhere yet: `lunchboxwm.com` isn't live
(launch checklist item 11).

## Bug 1: macOS window tiling left a window over its neighbour (fixed)

On macOS 15 and later, **Window › Fill** (and dragging a window to the top edge of the screen)
made the window cover the whole screen, on top of the window beside it, and LunchboxWM never put it back.

Why: Fill animates for about half a second. LunchboxWM saw the window move "on its own" and moved it
back 0.2 s later, mid-animation, so the rest of the animation undid it. After that its "never
wrestle more than once every two seconds" rule ignored the window. A drag to the edge was worse:
the animation starts after the drop, while LunchboxWM ignores moves from its own glide back.

Fix (`Tiler.windowChangedOnItsOwn`): wait until the window has held still for 0.25 s before
putting it back. For 1.5 s after a drop, also look at moves that land while LunchboxWM's own glide
settles. The check still acts only when the window really is off its tile.

Verified in the Sequoia VM:
- Fill on Finder and on a TextEdit tab group glides back within about a second.
- A drag to the top edge fills (948 → 1904 pt wide), then glides back to 948.
- Edge drags left and right are fine.
- Swap-by-drop and dragging the split to resize still work.

`swift test` passes (91). The bug and the fix aren't specific to 15: macOS 26 and 27 have the
same Fill command.

Verified again in the Tahoe VM: Fill on a TextEdit tab group fills, then glides back within about
0.7 s. A drag to the top edge fills when let go, and glides back about 0.5 s after the animation.
A drag to the left edge tiles the window to the left half, then it glides back to its own tile, as
on Sequoia.

## Bug 2: closing a dialog sent focus to a different window (fixed)

Found on Tahoe; the code isn't version-specific, so 14, 15 and 27 had it too. With Terminal and
two TextEdit windows tiled, ⌘O in TextEdit and then Cancel left Terminal in front, so typing went
there. With LunchboxWM paused, macOS hands focus back to the TextEdit window.

Why: when the focused window closes, LunchboxWM focuses the tile nearest to where it was, so macOS
can't hand focus to a window of the same app parked in another Workspace. That's right for a
tile. A dialog sits in the middle of the screen, though, so "nearest" was whichever tile happened
to be closest to the middle.

Fix (`Tiler`): when a floating window (a dialog, a panel, an app that floats) closes or is
minimized while focused, focus goes back to the tile focused before it, if that tile is still in
view. Otherwise focus goes to the nearest tile, as before. `focusChanged` now notes that tile at
the moment a floating window takes focus. It used to miss a window that got focus before LunchboxWM
had tiled it, such as a brand-new document.

Verified in the Tahoe VM: Cancel in the Open panel goes back to the TextEdit window that opened
it, with Terminal nearer the middle and with a document opened just before. Closing a tiled window
still focuses its nearest neighbour. `swift test` passes (91).

## Worth knowing

- **Parking:** older macOS clamps how low a window may go, so a parked window sits at
  y ≈ 943–967 instead of the corner, but only 1 pt of it is on screen. Nothing showed in
  screenshots on 14 and 15. On Tahoe (clamped to y = 958) a parked light window's left edge does
  show: a pure white line 1 pt wide down the screen's right edge, from y ≈ 972 to the bottom
  (about 110 pt). It's easy to miss, but it's there in screenshots. On 27 there's no clamp, so at
  most 1 pt in the corner shows.
- **Tahoe's capture prompt:** the first time Focus captured Shelf previews after Screen Recording
  was granted, macOS showed its own alert: "LunchboxWM" is requesting to bypass the system private
  window picker and directly access your screen and audio (Allow / Open System Settings). The
  previews were already live behind it. macOS shows this to apps that capture windows without the
  system picker, and may ask again from time to time; the support pages could mention it.
- **Tahoe's Screen Recording switch** restarts LunchboxWM by itself (no "Quit & Reopen" prompt).
  Harmless: it came straight back.
- **Tahoe's drag to the top edge** only fills if the pointer rests at the edge for about a second
  before letting go. A quick flick just moves the window, and LunchboxWM puts it back. (`vm.sh drag`
  rests for 150 ms, so the Tahoe run used a copy of its VNC client that rests for 1.2 s.)
- **First launch** on a fresh Mac takes a few seconds longer before the menu bar icon and welcome
  window appear (the system checks the new app). Expected.
- **Native tabs:** LunchboxWM notices a ⌃Tab switch about a second later. Nothing moves meanwhile.
- **Full screen:** while a window is in full screen, the windows left behind re-tile (a lone one
  centers), and everything returns exactly when it leaves. That's the same on every version; the
  README's "the rest of the Workspace stays put" is a little generous.
- **Split View** (Sonoma's Tile Window to Left of Screen): both windows come back tiled
  afterwards, but their order can swap. The same on every version.
- **Opening a folder** while Finder's only window is in another Workspace switches there, and the
  new window joins it, as ⌘-Tab does. The same on every version.
- **Screen Sharing.app** floats by design (`Tiler.floatingApps`), so a VM or remote Mac opened in
  it doesn't tile. Tyler noticed this; it's a product decision.
- LunchboxWM's own windows render in the macOS 14 style even on 26 and 27, because SwiftPM writes
  `sdk 14.0` into the binary. The system menus are drawn in the new style.

## Still owed

- Not tested on any version: multiple displays (the VMs have one), Picture in Picture, a real
  Sparkle update, and Gatekeeper/notarization (the Cirrus images turn Gatekeeper off).
