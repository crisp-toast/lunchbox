// POST /api/stripe-webhook : Stripe tells us what happened to a purchase.
// Listen for checkout.session.completed and checkout.session.async_payment_succeeded (paid:
// email the license), and charge.refunded and charge.dispute.created (refunded or charged
// back: the license goes on the revoked list, and LunchboxWM switches it off within a week).
import { getSession, isPaidLunchbox, sessionIdForPayment, verifyWebhook } from "../../store/lib/stripe.js";
import { licenseFor, sendLicenses } from "../../store/lib/fulfill.js";
import { revocationHash } from "../../store/lib/license.js";

export async function onRequestPost({ request, env }) {
  const raw = await request.text();
  if (!(await verifyWebhook(raw, request.headers.get("Stripe-Signature"), env.STRIPE_WEBHOOK_SECRET))) {
    return new Response("bad signature", { status: 400 });
  }
  const event = JSON.parse(raw);
  const object = event.data?.object || {};

  if (event.type === "charge.refunded" || event.type === "charge.dispute.created") {
    // A partial refund (a goodwill discount, say) leaves the license alone.
    if (event.type === "charge.refunded" && !object.refunded) return new Response("partial refund: license kept");
    const order = await sessionIdForPayment(env, object.payment_intent);
    if (!order) return new Response("not a checkout payment");
    if (!env.REVOKED) return new Response("no REVOKED store bound", { status: 500 });
    const reason = event.type === "charge.refunded" ? "refunded" : "disputed";
    await env.REVOKED.put(`r:${await revocationHash(order)}`, JSON.stringify({ order, reason, at: event.created }));
    return new Response(`revoked (${reason})`);
  }

  if (!["checkout.session.completed", "checkout.session.async_payment_succeeded"].includes(event.type)) {
    return new Response("ignored");
  }
  // Re-read the session from Stripe (with line items) rather than trusting the payload alone.
  const session = await getSession(env, object.id);
  if (!isPaidLunchbox(session, env)) return new Response("not a paid LunchboxWM purchase");
  const license = await licenseFor(session, env);
  await sendLicenses(env, { to: session.customer_details.email, licenses: [license], idempotencyKey: `lunchbox-license-${session.id}` });
  return new Response("sent");
}
