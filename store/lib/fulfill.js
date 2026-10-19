// Turning a paid Checkout Session into a license, and sending it.
import { issueLicense } from "./license.js";

/** The license for a paid session: same session, same key, every time. */
export function licenseFor(session, env) {
  return issueLicense(
    { email: session.customer_details?.email, order: session.id, issued: session.created },
    JSON.parse(env.LICENSE_PRIVATE_KEY),
  );
}

export function activateURL(env, license) {
  // Mail apps often drop custom schemes like lunchbox://, so the email links to a page
  // on the site that opens Lunchbox. The key rides in the fragment, which never reaches a server.
  return `${env.SITE_URL}/activate.html#${license}`;
}

/** Sends licenses by email through Resend. The idempotency key makes Stripe's webhook
 *  retries (and repeat recovery requests) send one email, not several. */
export async function sendLicenses(env, { to, licenses, idempotencyKey, recovery = false }) {
  if (!env.RESEND_API_KEY) return { skipped: "no RESEND_API_KEY" };
  const one = licenses.length === 1;
  const blocks = licenses.map((l) => `${l}\n\nActivate on this Mac: ${activateURL(env, l)}`).join("\n\n---\n\n");
  const text = [
    recovery ? "Here is your Lunchbox license, as asked." : "Thanks for buying Lunchbox!",
    "",
    one ? "Your license:" : "Your licenses:",
    "",
    blocks,
    "",
    "To activate: click the link above on the Mac where Lunchbox is installed, or open Lunchbox's menu bar icon, choose Enter License…, and paste the key.",
    `Download Lunchbox: ${env.SITE_URL}/download/Lunchbox.dmg`,
    "",
    "Your license covers you on all of your own Macs, and every future version of Lunchbox.",
    "Questions, or want a refund within 14 days? Just reply to this email.",
    "",
    recovery ? null : "At checkout you asked for Lunchbox to be delivered right away and acknowledged that this ends the EU/UK 14-day right to cancel. Our 14-day refund still applies.",
    "",
    "Sentient Donut LLC, 5900 Balcones Drive, Suite 100, Austin, Texas 78731, USA",
    `Terms: ${env.SITE_URL}/terms.html · Privacy: ${env.SITE_URL}/privacy.html`,
  ].filter((line) => line !== null).join("\n");
  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, "Content-Type": "application/json", "Idempotency-Key": idempotencyKey },
    body: JSON.stringify({
      from: env.EMAIL_FROM, to: [to], reply_to: env.SUPPORT_EMAIL,
      subject: recovery ? "Your Lunchbox license" : "Your Lunchbox license (and how to activate it)",
      text,
    }),
  });
  if (!response.ok) throw new Error(`Resend: ${response.status} ${await response.text()}`);
  return response.json();
}
