// The few Stripe calls the store makes, over plain fetch (no SDK, so it runs on Workers as is).

const API = "https://api.stripe.com/v1";

async function stripe(env, path, params = {}) {
  const url = new URL(API + path);
  for (const [k, v] of Object.entries(params)) {
    for (const value of [].concat(v)) url.searchParams.append(k, value);
  }
  const response = await fetch(url, { headers: { Authorization: `Bearer ${env.STRIPE_SECRET_KEY}` } });
  const body = await response.json();
  if (!response.ok) throw new Error(`Stripe ${path}: ${response.status} ${body?.error?.message || ""}`);
  return body;
}

/** A Checkout Session with its line items, or null if the id isn't one. */
export async function getSession(env, id) {
  if (!/^cs_(test|live)_[A-Za-z0-9]{10,}$/.test(String(id || ""))) return null;
  return stripe(env, `/checkout/sessions/${id}`, { "expand[]": ["line_items", "payment_intent.latest_charge"] });
}

/** Completed Checkout Sessions paid with this email, newest first. */
export async function sessionsForEmail(env, email) {
  const list = await stripe(env, "/checkout/sessions", {
    "customer_details[email]": email, status: "complete", limit: "20",
    "expand[]": ["data.line_items", "data.payment_intent.latest_charge"],
  });
  return list.data || [];
}

/** The Checkout Session a payment belongs to (for refunds and disputes, which name only the payment). */
export async function sessionIdForPayment(env, paymentIntent) {
  if (!paymentIntent) return null;
  const list = await stripe(env, "/checkout/sessions", { payment_intent: paymentIntent, limit: "1" });
  return list.data?.[0]?.id || null;
}

/** Whether a session bought LunchboxWM and is paid for: not still processing, not refunded or
 *  disputed, not someone else's product. */
export function isPaidLunchbox(session, env) {
  if (!session || session.status !== "complete") return false;
  if (!["paid", "no_payment_required"].includes(session.payment_status)) return false;
  const charge = session.payment_intent?.latest_charge;
  if (charge && (charge.refunded || charge.disputed)) return false;
  const items = session.line_items?.data || [];
  return items.some((item) => item.price?.id === env.STRIPE_PRICE_ID);
}

/** Checks the Stripe-Signature header (HMAC-SHA256 of "<timestamp>.<raw body>"),
 *  rejecting anything older than five minutes. */
export async function verifyWebhook(rawBody, header, secret, now = Date.now()) {
  const parts = Object.fromEntries(String(header || "").split(",").map((kv) => kv.split("=")));
  const timestamp = Number(parts.t);
  const signatures = String(header || "").split(",").filter((kv) => kv.startsWith("v1=")).map((kv) => kv.slice(3));
  if (!timestamp || !signatures.length || Math.abs(now / 1000 - timestamp) > 300) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${timestamp}.${rawBody}`)));
  const expected = [...mac].map((b) => b.toString(16).padStart(2, "0")).join("");
  return signatures.some((sig) => sig.length === expected.length && timingSafeEqual(sig, expected));
}

function timingSafeEqual(a, b) {
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
