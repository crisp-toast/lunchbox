# Selling Tessel

How buying works, and the steps to switch it on. Everything in the repo is built and tested;
the steps below need your accounts, so they're yours to do.

## How it works

1. **Try:** anyone downloads `download/Tessel.dmg`. Every feature works for **7 days of use**
   (a day counts only when Tessel tiles a window or runs a shortcut). Then tiling pauses, windows
   stay put, and Tessel offers Buy and Enter License.
2. **Buy:** the pricing card's **Buy Tessel · $9.99** posts to `/api/checkout`, which opens
   Stripe's hosted checkout:
   - one Tessel at $9.99 USD, with Stripe Tax adding sales tax or VAT;
   - the system requirements on the pay button;
   - a required Terms checkbox, which also records EU/UK consent to immediate delivery.

   A per-visit attempt id makes double clicks reuse one checkout.
3. **Get the license:** Stripe returns the buyer to `thanks.html`, and `/api/license` reads the
   paid session and shows the license, with **Activate Tessel on this Mac** (a `tessel://` link),
   Download and Copy. The same order always gives the same key, so a refresh is harmless.
   The webhook emails it too, with an `activate.html` link (mail apps drop `tessel://`) and the
   consent record. It's sent once, even when Stripe retries.
4. **Activate:** the link, or Tessel's menu → Enter License… → paste. Checked offline against the
   public key in `Sources/Tessel/Licensing.swift`: no account, no server, works on all their Macs.
5. **Lost it:** `recover.html` emails every license for that address, to that address.
6. **Refunds:** 30 days, no questions, from the Stripe Dashboard. For support, gifts or press,
   `node scripts/license.mjs issue someone@example.com`.

The signing key is at `~/.config/sentient-donut/tessel-license-signing.jwk` (internal disk, 600).
**Back it up in 1Password now.** Lose it and you can't issue keys that match shipped apps;
leak it and anyone can.

## Switching it on

1. **Domain:** pick where the store lives. It's `https://tessel.sentientdonut.com` in
   `wrangler.toml` and `Licensing.site`. Change both if it's different.
2. **Apple** (so buyers can open the app):
   - In the Developer Program, create a **Developer ID Application** certificate (Account Holder
     only) and install it in this Mac's keychain.
   - Run `xcrun notarytool store-credentials tessel-notary --apple-id tyler@sentientdonut.com --team-id <TEAM>`,
     which asks for an app-specific password.
   - Then run `scripts/release.sh 1.0`. It builds, signs, notarizes and staples the app and the
     DMG into `site/download/Tessel.dmg`.
3. **Stripe:**
   - Activate the account as Sentient Donut LLC.
   - Public details: support email `support@sentientdonut.com`; Terms, Privacy and Refund URLs
     on the store domain.
   - Add a product "Tessel" with a **$9.99 one-time** price, tax behavior **exclusive** and tax
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
     `checkout.session.completed` and `checkout.session.async_payment_succeeded`.
4. **Email:** create a Resend account, verify `sentientdonut.com` (DNS records), and make an API key.
5. **Cloudflare Pages:**
   - Create the project: `npx wrangler pages project create tessel`.
   - Set the four secrets listed in `wrangler.toml`.
   - Deploy: `npx wrangler pages deploy`.
   - Add the custom domain.
6. **Test in Stripe test mode** first, with test keys and a test price:
   - buy with card 4242 4242 4242 4242;
   - check the thank-you page, the email and the activation link;
   - try a declined card (4000 0000 0000 0002) and "Lost license";
   - refund the order from the Dashboard.

   Then switch to live keys.

## Tests

`swift test` covers the license format and trial. `node --test store/test/*.test.mjs` covers
signing, checkout, the thank-you lookup, webhook signatures and retries, and recovery, against a
fake Stripe and Resend.

Not legal or tax advice: have the Terms, Privacy and Refund pages and your tax setup reviewed.
