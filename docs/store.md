# Selling LunchboxWM

How buying works, and the steps to switch it on. Everything in the repo is built and tested;
the steps below need your accounts, so they're yours to do.

## How it works

1. **Paid up front, no free trial** (since 2026-10-19). Anyone can download
   `download/LunchboxWM.dmg`, but without a license nothing tiles: the welcome window's setup and
   practice screen work, then LunchboxWM asks for a key, with Buy and Enter License
   (`Licensing.canTile`). The site sells first and links the download from the thank-you page.
2. **Buy:** the pricing card's **Buy LunchboxWM · $4.99** posts to `/api/checkout`, which opens
   Stripe's hosted checkout:
   - one LunchboxWM at $4.99 USD, with Stripe Tax adding sales tax or VAT;
   - the system requirements on the pay button;
   - a required Terms checkbox, which also records EU/UK consent to immediate delivery.

   A per-visit attempt id makes double clicks reuse one checkout.
3. **Get the license:** Stripe returns the buyer to `thanks.html`, and `/api/license` reads the
   paid session and shows the license, with **Activate LunchboxWM on this Mac** (a `lunchbox://` link),
   Download and Copy. The same order always gives the same key, so a refresh is harmless.
   The webhook emails it too, with an `activate.html` link (mail apps drop `lunchbox://`) and the
   consent record. It's sent once, even when Stripe retries.
4. **Activate:** the link, or LunchboxWM's menu → Enter License… → paste. Checked offline against the
   public key in `Sources/LunchboxWM/Licensing.swift`: no account, no server, works on all their Macs.
5. **Lost it:** `recover.html` emails every license for that address, to that address.
   Without `RESEND_API_KEY` it sends nothing, so the page and `/api/recover` tell the buyer to
   write to support instead.
6. **Refunds:** 14 days, no questions. Refund from the Stripe Dashboard and the rest is automatic:
   - the webhook puts the order on the revoked list (`/api/revoked`, as one-way hashes);
   - licensed copies check that list about once a week and switch the license off;
   - chargebacks go on the list too, and partial refunds don't;
   - the thank-you page and lost-license emails stop handing that license out.

   For support, gifts or press,
   `node scripts/license.mjs issue someone@example.com`.

The Developer ID certificate (Sentient Donut LLC, 8W7XL99F58, expires 2027-11-19) lives in its own
keychain, `~/Library/Keychains/lunchbox-signing.keychain-db`, whose password is in
`~/.config/sentient-donut/signing-keychain-password`; `scripts/release.sh` unlocks it, so codesign
never asks. Notarization uses the App Store Connect API key through the `lunchbox-notary` profile.

The signing key is at `~/.config/sentient-donut/tessel-license-signing.jwk` (internal disk, 600).
**Back it up in 1Password now.** Lose it and you can't issue keys that match shipped apps;
leak it and anyone can.

## Switching it on

1. **Domain:** the store lives at `https://lunchboxwm.com` (`wrangler.toml` and `Licensing.site`).
   Register it (it was still unregistered on 2026-10-18), add it to Cloudflare as a site so
   Cloudflare runs its DNS, and later attach it to the Pages project (step 5). LunchboxWM was called
   Tessel and sold from `tessel.sentientdonut.com` in testing; nothing points there any more.
2. **Apple** (so buyers can open the app):
   - In the Developer Program, create a **Developer ID Application** certificate (Account Holder
     only) and install it in this Mac's keychain.
   - Run `xcrun notarytool store-credentials lunchbox-notary --apple-id tyler@sentientdonut.com --team-id <TEAM>`,
     which asks for an app-specific password.
   - Then run `scripts/release.sh 1.0`. It builds, signs, notarizes and staples the app and the
     DMG into `site/download/LunchboxWM.dmg`.
3. **Stripe:**
   - Activate the account as Sentient Donut LLC.
   - Public details: support email `support@sentientdonut.com`; Terms, Privacy and Refund URLs
     on the store domain.
   - Add a product "LunchboxWM" with a **$4.99 one-time** price, tax behavior **exclusive** and tax
     code `txcd_10202000` (downloadable software, personal use). Put its `price_…` id in
     `wrangler.toml`.
   - **Stripe Tax:** turn it on and add your registrations. Texas taxes software. Selling to
     EU and UK consumers means VAT registration from the first sale there (EU non-Union OSS, UK
     VAT). Stripe Tax only charges tax where you're registered, so register before taking EU
     and UK sales, or block those countries in Radar until you do.
   - Payment methods: cards, Apple Pay, Link.
   - Turn on email receipts.
   - Create a **restricted key** (Checkout Sessions: write).
   - Add a webhook endpoint `https://<domain>/api/stripe-webhook` for
     `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `charge.refunded`
     and `charge.dispute.created`.
4. **Email:** create a Resend account, verify `sentientdonut.com` (DNS records), and make an API key.
5. **Cloudflare Pages:**
   - Create the project: `npx wrangler pages project create lunchbox`.
   - Create the KV namespace for revoked licenses: `npx wrangler kv namespace create REVOKED`,
     then paste its id into `wrangler.toml`.
   - Set the four secrets listed in `wrangler.toml`.
   - Deploy: `npx wrangler pages deploy`.
   - Add the custom domains `lunchboxwm.com` and `www.lunchboxwm.com` (Pages › Custom domains),
     with `www` redirecting to the bare domain.
6. **Test in Stripe test mode** first, with test keys and a test price:
   - buy with card 4242 4242 4242 4242;
   - check the thank-you page, the email and the activation link;
   - try a declined card (4000 0000 0000 0002) and "Lost license";
   - refund the order from the Dashboard.

   Then switch to live keys.

## Releases and auto-updates

LunchboxWM updates itself with [Sparkle](https://sparkle-project.org): it checks
`https://<domain>/appcast.xml` once a day, asks before installing, and accepts only updates signed
with LunchboxWM's update key.

- **The public key** is `SUPublicEDKey` in `Resources/Info.plist`.
- **The private key** is in this Mac's login Keychain (Sparkle's `generate_keys` put it there).
  Back it up to 1Password now:
  `Vendor/sparkle-bin/generate_keys -x lunchbox-update-key.txt`,
  store the file in 1Password, then delete it. Lose it and installed copies can never update again.

To ship version X:
1. Optionally write release notes to `build/release/notes.html`.
2. Run `scripts/release.sh X`. It builds, signs and notarizes, copies the DMG to
   `/Volumes/Master Storage/Projects/lunchbox/releases/`, regenerates `site/appcast.xml` (signed),
   and puts `LunchboxWM.dmg` and `LunchboxWM-X.dmg` in `site/download/`.
3. Deploy the site (`npx wrangler pages deploy`). Running copies pick the update up within a day,
   or straight away with Settings › Check for Updates….

## Tests

`swift test` covers the license format. `node --test store/test/*.test.mjs` covers
signing, checkout, the thank-you lookup, webhook signatures and retries, and recovery, against a
fake Stripe and Resend.

Not legal or tax advice: have the Terms, Privacy and Refund pages and your tax setup reviewed.
