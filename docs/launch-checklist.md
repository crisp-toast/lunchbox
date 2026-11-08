# Launch checklist

What's left before LunchboxWM can be sold, as of 2026-10-16. Everything has been built and tested
on the Mac mini only (M4, macOS 27 beta, an LG 5K and a 4K display). The selling steps are
spelled out in [store.md](store.md); this list puts them in order with the testing that's still owed.

## What came from other window managers

Researched AeroSpace, yabai, Amethyst, Rectangle, Stage Manager and niri (Linux), and their
issue trackers, for what goes wrong for their users. What LunchboxWM does about it:

| Problem in other tiling window managers | What LunchboxWM does now |
|---|---|
| Dragging a file to a window you can't see: corner-parking managers (AeroSpace) have nothing, and macOS's own tricks only work with Spaces | In Focus, holding a dragged file over a Shelf card ends Focus so it can be dropped in that window. macOS Show Desktop (F11, or the trackpad spread) works with LunchboxWM, so files can go to the desktop |
| Dialogs and alerts get tiled like windows and squashed | Dialogs, alerts and sheets float, centered on their window's display |
| Leaving native fullscreen scrambles the layout (a LunchboxWM bug you found, also common in AeroSpace and yabai) | The window returns to its tile, and nothing else moves |
| Native tabs (Finder, Terminal, Safari) count as separate windows, a top AeroSpace and yabai complaint | All tabs of a window share one tile |
| A crash leaves windows stuck in the corner where other Workspaces are parked (AeroSpace) | LunchboxWM relaunches itself within about a second with the same layout, and windows macOS pushes back on screen get parked again |
| Sleep, lid and monitor changes scramble layouts, the most common AeroSpace complaint | Each display's layout is remembered and comes back when it does, after a 1-second settle |
| macOS 27 pulling parked windows back on screen (AeroSpace reports) | Watched for an hour with none seen; stray windows would be re-parked anyway |
| One hung app freezes the whole window manager | LunchboxWM talks to each app on its own thread (already built) |
| Focus jumps to the wrong window | Focus goes through the window server, the way yabai and AeroSpace do it |
| No updates for apps sold outside the App Store | Sparkle auto-updates, signed with LunchboxWM's own key, the same as Rectangle and Amethyst |
| Shortcuts that steal keys apps need | LunchboxWM's shortcuts use left ⌘ only, so right ⌘ stays with your apps |
| Mouse users left out | Drag a split edge to resize, drop a window on another to swap them, or on another display to move it (already built) |

Also changed for you, not from research: Finder windows no longer open in Focus, and "Float
Focused Window" now enters real Focus.

## Known gaps (not built)

- **Per-app rules** ("always float this app", "always open Mail in Workspace 2"). People expect
  them, but launch can go without.
- **Non-US keyboards.** Shortcuts follow US key positions, so Dvorak and AZERTY users press
  different keys from the ones the Cheat Sheet shows.
- **Battery.** Windows parked in other Workspaces keep drawing (a video in a parked browser still
  plays), which a laptop feels more than a Mac mini.

## The list

### Test

1. **MacBook, built-in screen only.** Install from the DMG and go through onboarding. Then check:
   - tiling at the smaller size;
   - the notch: is LunchboxWM's menu bar icon and Workspace number visible, or hidden behind the
     notch when an app has a lot of menus?
   - every shortcut on the laptop keyboard, including F11 Show Desktop (which may need fn).
2. **MacBook trackpad gestures.** Check that each leaves the layout alone afterward:
   Mission Control (three fingers up), App Exposé, Show Desktop (spread), swiping between
   fullscreen apps, and Launchpad/Apps.
3. **MacBook with an external display.** Plug and unplug it, and close the lid with it plugged in
   (clamshell) and open it again. Layouts on both screens should come back.
4. **Sleep and wake.** Sleep for a few minutes and for overnight, on the MacBook and the Mac mini,
   with windows in all three Workspaces. Nothing should move or get lost.
5. **Battery drain.** A day on battery with a video playing in a parked Workspace compared to
   one with LunchboxWM off. If the difference is large, LunchboxWM should pause parked windows' rendering
   or the site should mention it.
6. **Older macOS.** Tested in VMs on 2026-10-16: macOS 14, 15 and 26 pass, so the site's "macOS 14
   or later" stands. Two bugs turned up, both fixed: macOS window tiling leaving a window over its
   neighbour (found on 15), and focus jumping to another window when a dialog closed (found on 26).
   Details in [macos-compatibility.md](macos-compatibility.md).
7. **Picture-in-picture.** A PiP video should float above the tiles and stay on every Workspace.
8. **A fresh Mac account.** First launch, granting Accessibility, the 7-day trial, and what happens
   when it ends. To end it early:
   `defaults write com.sentientdonut.lunchbox trialStarted -date "2026-01-01 00:00:00 +0000"`,
   then relaunch LunchboxWM. `defaults delete com.sentientdonut.lunchbox trialStarted` undoes it.
9. **A real update.** Release 1.0, install it, release 1.0.1, and let Sparkle update it. Check that
   Accessibility permission survives (it should, with the Developer ID signature).

### Set up and ship

10. **Back up both private keys to 1Password**, then double-check you can read them back:
    - the license signing key, `~/.config/sentient-donut/tessel-license-signing.jwk`;
    - the Sparkle update key in the login Keychain (`generate_keys -x`, see store.md).

    Losing either means existing customers can't be served or updated.
11. **Domain.** Register `lunchboxwm.com` (unregistered on 2026-10-18) and add it to Cloudflare.
    The app, store and site already use it (`wrangler.toml`, `Licensing.site`).
12. **Apple.** Create the Developer ID Application certificate, store the notarytool profile, and run
    `scripts/release.sh 1.0`.
13. **Stripe.** In this order:
    - activate the account as Sentient Donut LLC;
    - add the $4.99 product (tax code `txcd_10202000`);
    - turn on Stripe Tax with a Texas registration;
    - either register for EU and UK VAT, or block those countries until you do;
    - create the restricted key and the webhook for its 4 events;
    - turn on receipts.
14. **Email.** Verify `sentientdonut.com` in Resend, and make sure `support@sentientdonut.com`
    actually receives mail.
15. **Cloudflare.** Create the Pages project and the `REVOKED` KV namespace, set the 4 secrets,
    deploy, and add the custom domain.
16. **End-to-end in Stripe test mode.** Buy with 4242…, then check:
    - the thank-you page, the email and the activation link on another Mac;
    - a declined card;
    - Lost License;
    - a refund, which should switch the license off within a week. To skip the wait, clear
      it with `defaults delete com.sentientdonut.lunchbox revocationChecked` and relaunch LunchboxWM.
17. **Legal review** of the Terms, Privacy and Refunds pages, and your sales tax setup.
18. **Remove the Apple logo** from the site's download and buy buttons.
19. **Switch Stripe to live keys**, make one real purchase yourself, and refund it.
20. **Go public.** Point the site at the real domain (it's a private preview today). The GitHub
    repo is public, under the MIT License.
