# Smoothness

How rearranging looks, measured: every window's frame every 2 ms while LunchboxWM moves windows around,
in test VMs, before and after the 2026-10-18 changes. The goal: every rearrangement is one
deliberate move, never a window stopping, starting again, or moving twice.

## How it's measured

- `scripts/windowlab/motion.swift` runs in the VM. It samples every window's frame (the window
  server's, what's on screen) every 2 ms and posts the case's trigger itself, so the clock starts
  at the exact moment of the key press, window or launch.
- `scripts/windowlab/smooth.py` runs on the Mac: it sets each case up over SSH, records it, and
  works out per case:
  - **Settled**: ms from the trigger until every window is within 2 points of where it ends.
  - **Motions**: separate movements a window makes (changes split by a pause of 60 ms or more;
    macOS's own grow-in of a new window doesn't count). The table shows the most of any window.
  - **Stops**: frames a window holds for 40 ms or more on the way, other than where it started
    and ended (a window waiting where its app put it counts).
  - **Spread**: how far apart the first and last window settle.
  - **Wobble**: points an edge travels against its own direction during a move (an edge that
    should hold still, shaking). Noisy: one bad frame in three runs moves the median a lot.
  - **Overlap**: ms with any two windows overlapping.
- Three runs per case, medians below. WindowLab windows (`scripts/windowlab`), except the restore
  case (TextEdit, quitting with its windows kept and launching again).
- `smooth.py --table BEFORE.json AFTER.json` prints this comparison from saved runs.

The cases: a window arriving in a 1-, 2-, 3- and 4-window layout; 5 windows 40 ms apart (an app
opening a set); 3 at once from an app answering slowly; TextEdit restoring its windows at launch
(5 on macOS 27; on 26 it restored 16, from earlier sessions); closing a window in 3 and in 4;
move left (into a stack); swap in a stack; grow and shrink; grow in 3; Tidy after two grows; Focus
on and off with 4; leaving and coming back to a Workspace of 6; a window keeping its shape
(Simulator), one that can't be resized, and one with a minimum width arriving beside another;
grow and an arrival with an app busy 60 ms of every 100 (Arc at times); grow and Focus with an app
taking 25 ms to draw (a browser).

## Results

Before (main, e707d5a) → after.

### macOS 27.0 (tessel-vm)

| Case | Settled (ms) | Motions, most of any window | Stops on the way | Spread (ms) | Wobble (pt) | Overlap (ms) |
|---|---|---|---|---|---|---|
| arrive_1 | 131 → 126 | 1 → 1 | 0 → 0 | 0 → 0 | 12 → 24 | 0 → 0 |
| arrive_2 | 236 → 238 | 1 → 1 | 0 → 0 | 110 → 110 | 84 → 56 | 180 → 177 |
| arrive_3 | 220 → 212 | 1 → 1 | 0 → 0 | 108 → 92 | 16 → 14 | 177 → 159 |
| arrive_4 | 213 → 212 | 1 → 1 | 0 → 0 | 109 → 91 | 26 → 636 | 181 → 154 |
| burst_5 | 426 → 293 | 2 → 2 | 1 → 1 | 213 → 20 | 1134 → 538 | 350 → 216 |
| burst_3_slow | 393 → 382 | 3 → 2 | 2 → 1 | 133 → 14 | 192 → 278 | 306 → 294 |
| restore_textedit_5 | 540 → 494 | 1 → 1 | 1 → 1 | 0 → 0 | 0 → 468 | 101 → 79 |
| close_3to2 | 240 → 202 | 1 → 1 | 0 → 0 | 0 → 0 | 0 → 0 | 0 → 0 |
| close_4to3 | 231 → 213 | 1 → 1 | 0 → 0 | 0 → 0 | 0 → 0 | 0 → 0 |
| move_left | 221 → 172 | 1 → 1 | 0 → 1 | 0 → 0 | 504 → 636 | 128 → 131 |
| swap_up | – → 181 | – → 1 | – → 0 | – → 0 | – → 0 | – → 150 |
| grow | 174 → 162 | 1 → 1 | 0 → 0 | 0 → 0 | 58 → 108 | 0 → 0 |
| shrink | 179 → 169 | 1 → 1 | 0 → 0 | 0 → 0 | 0 → 70 | 13 → 21 |
| grow_3 | 176 → 178 | 1 → 1 | 0 → 1 | 0 → 0 | 148 → 264 | 0 → 0 |
| tidy | 50 → 187 | 1 → 1 | 0 → 0 | 18 → 0 | 906 → 282 | 17 → 37 |
| focus_on | 193 → 185 | 1 → 1 | 0 → 0 | 181 → 161 | 60 → 130 | 0 → 0 |
| focus_off | 200 → 187 | 1 → 1 | 0 → 0 | 159 → 127 | 76 → 114 | 142 → 114 |
| space_away_6 | 68 → 11 | 1 → 1 | 0 → 0 | 57 → 0 | 0 → 0 | 0 → 0 |
| space_back_6 | 66 → 30 | 1 → 1 | 0 → 0 | 26 → 0 | 0 → 0 | 0 → 0 |
| fitted_aspect | 414 → 229 | 2 → 1 | 1 → 0 | 166 → 110 | 1064 → 148 | 243 → 113 |
| fitted_fixed | 235 → 212 | 1 → 1 | 0 → 0 | 129 → 107 | 0 → 10 | 0 → 27 |
| fitted_min | 385 → 236 | 2 → 1 | 1 → 0 | 148 → 94 | 104 → 92 | 192 → 172 |
| slow_grow | 290 → 181 | 3 → 2 | 2 → 1 | 0 → 0 | 102 → 46 | 0 → 0 |
| slow_arrive_3 | 358 → 282 | 3 → 2 | 2 → 1 | 200 → 126 | 12 → 0 | 278 → 204 |
| heavy_grow | 296 → 161 | 2 → 2 | 3 → 1 | 15 → 0 | 110 → 304 | 0 → 50 |
| heavy_focus_on | 251 → 133 | 1 → 1 | 0 → 0 | 243 → 98 | 286 → 336 | 0 → 0 |

### macOS 26.6.2 (tessel-tahoe)

| Case | Settled (ms) | Motions, most of any window | Stops on the way | Spread (ms) | Wobble (pt) | Overlap (ms) |
|---|---|---|---|---|---|---|
| arrive_1 | 139 → 143 | 1 → 1 | 0 → 0 | 0 → 0 | 26 → 20 | 0 → 0 |
| arrive_2 | 208 → 212 | 1 → 1 | 0 → 0 | 88 → 87 | 60 → 60 | 177 → 161 |
| arrive_3 | 227 → 203 | 1 → 1 | 0 → 0 | 105 → 88 | 20 → 4 | 176 → 158 |
| arrive_4 | 231 → 193 | 1 → 1 | 0 → 0 | 104 → 89 | 22 → 16 | 176 → 157 |
| burst_5 | 391 → 293 | 2 → 1 | 0 → 1 | 177 → 13 | 2154 → 186 | 292 → 214 |
| burst_3_slow | 375 → 358 | 2 → 3 | 1 → 2 | 104 → 0 | 158 → 230 | 297 → 283 |
| restore_textedit_5 | 1873 → 1640 | 1 → 1 | 3 → 4 | 343 → 441 | 1692 → 4518 | 384 → 277 |
| close_3to2 | 213 → 188 | 1 → 1 | 0 → 0 | 0 → 0 | 0 → 0 | 0 → 0 |
| close_4to3 | 217 → 194 | 1 → 1 | 0 → 0 | 0 → 0 | 0 → 0 | 0 → 0 |
| move_left | 191 → 190 | 1 → 1 | 0 → 1 | 0 → 0 | 288 → 484 | 146 → 154 |
| swap_up | 190 → 173 | 1 → 1 | 0 → 0 | 0 → 0 | 0 → 0 | 162 → 164 |
| grow | 172 → 164 | 1 → 1 | 0 → 0 | 0 → 0 | 76 → 68 | 0 → 0 |
| shrink | 177 → 169 | 1 → 1 | 0 → 0 | 0 → 0 | 68 → 70 | 0 → 25 |
| grow_3 | 171 → 165 | 1 → 1 | 0 → 0 | 0 → 0 | 178 → 192 | 0 → 0 |
| tidy | 42 → 184 | 1 → 1 | 0 → 0 | 18 → 0 | 606 → 236 | 28 → 39 |
| focus_on | 215 → 191 | 1 → 1 | 0 → 0 | 207 → 180 | 142 → 16 | 0 → 0 |
| focus_off | 187 → 180 | 1 → 1 | 0 → 0 | 183 → 124 | 0 → 124 | 163 → 111 |
| space_away_6 | 32 → 31 | 1 → 1 | 0 → 0 | 27 → 23 | 0 → 0 | 0 → 0 |
| space_back_6 | 45 → 49 | 1 → 1 | 0 → 0 | 30 → 18 | 0 → 0 | 0 → 0 |
| fitted_aspect | 379 → 208 | 2 → 1 | 1 → 0 | 164 → 88 | 1048 → 24 | 209 → 92 |
| fitted_fixed | 226 → 206 | 1 → 1 | 0 → 0 | 121 → 106 | 266 → 0 | 12 → 16 |
| fitted_min | 374 → 211 | 2 → 1 | 1 → 0 | 144 → 89 | 100 → 78 | 183 → 163 |
| slow_grow | 282 → 85 | 3 → 1 | 2 → 0 | 0 → 0 | 102 → 56 | 0 → 0 |
| slow_arrive_3 | 275 → 237 | 2 → 2 | 1 → 1 | 122 → 82 | 16 → 16 | 199 → 171 |
| heavy_grow | 315 → 144 | 2 → 2 | 2 → 2 | 100 → 0 | 74 → 70 | 40 → 0 |
| heavy_focus_on | 250 → 131 | 1 → 1 | 2 → 1 | 239 → 116 | 478 → 324 | 0 → 0 |

The swap case didn't build its stack in the first macOS 27 run (a harness bug, fixed before the
macOS 26 runs), so it has no before there.

## What changed

- **Bursts land together.** An app opening several windows at once reflowed the layout once per
  window, so earlier windows moved two or three times and the last ones landed up to 200 ms after
  the first. Windows made less than 120 ms apart now wait where their app put them and land
  together, in one move, as soon as the app stops (the wait adapts to its pace: 50 ms for an app
  that makes them all at once, up to 120 ms). The window that started the burst is usually placed
  before the burst is known, so it makes two moves.
- **Windows that can't fill a tile fit at once.** Simulator's shape or a minimum size used to be
  learned 0.15 s after the window went into its tile, and then it moved again. LunchboxWM now learns it
  from its first placement and sends the window straight to the frame it fits: one move, about
  170 ms sooner.
- **An app's windows move together.** Moves went through one queue per app, so a Workspace switch
  revealed or parked an app's windows one after another (up to 60 ms apart), and a slow app's far
  longer. Each window has its own queue now.
- **Slow and stalling apps snap.** A glide through an app that stalls stops and jumps (three
  motions for one grow). LunchboxWM judges each app by its slowest recent call, including reading which
  window has focus before the move, and snaps instead; a glide that stalls partway finishes at once.
- **Tidy glides.** It (and a dragged window let go, or one an app moved) used to snap, because a
  window without a target was treated as one whose size isn't known.
- **A snap moves, then fills its tile**, instead of swelling where the window was and then jumping.
  A window coming back from another Workspace still takes its size out of sight first.
- **Glides start a frame sooner**: the first frame sent used to repeat where the window already was.
- New windows still go straight into their tiles. From appearing to being in its tile (macOS's own
  grow-in aside), across both versions, after (before): a new TextEdit window 7-35 ms (6-33); an
  app's first window at launch 41-211 ms (99-149); the Open panel 33-82 ms, once 398 (65-84);
  Finder 40-171 ms (37-579: Finder takes a new size late while it loads the folder).

## What's left

- **Edges can still shake a little when a window both moves and resizes.** macOS gives no way to
  move and resize another app's window in one step (the "AXFrame" attribute isn't settable), and the
  size lands on screen a frame or two after the position, by a varying amount. Sending them in the
  other order, the position a frame late, or the position only once the size shows were all tried;
  none was reliably better. Animating a snapshot of the window over the real one (as yabai does)
  would remove it, but needs Screen Recording permission.
- **A new window overlaps its neighbors for about 160 ms** while they slide out from under it. That's
  by design (it goes straight into its tile, in front); the neighbors make room in one glide.
- **An app restoring many windows** (16 TextEdit windows) still waits about 300 ms before they move,
  while LunchboxWM reads every window of an app that's busy restoring them; they then move once each.
