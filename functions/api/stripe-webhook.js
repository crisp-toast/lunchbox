// POST /api/stripe-webhook : Stripe tells us a purchase is paid; we email the license.
// Listen for checkout.session.completed and checkout.session.async_payment_succeeded.
import { getSession, isPaidTessel, verifyWebhook } from "../../store/lib/stripe.js";
import { licenseFor, sendLicenses } from "../../store/lib/fulfill.js";

export async function onRequestPost({ request, env }) {
  const raw = await request.text();
  if (!(await verifyWebhook(raw, request.headers.get("Stripe-Signature"), env.STRIPE_WEBHOOK_SECRET))) {
    return new Response("bad signature", { status: 400 });
  }
  const event = JSON.parse(raw);
  if (!["checkout.session.completed", "checkout.session.async_payment_succeeded"].includes(event.type)) {
    return new Response("ignored");
  }
  // Re-read the session from Stripe (with line items) rather than trusting the payload alone.
  const session = await getSession(env, event.data?.object?.id);
  if (!isPaidTessel(session, env)) return new Response("not a paid Tessel purchase");
  const license = await licenseFor(session, env);
  await sendLicenses(env, { to: session.customer_details.email, licenses: [license], idempotencyKey: `tessel-license-${session.id}` });
  return new Response("sent");
}
