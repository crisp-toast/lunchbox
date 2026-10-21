// POST /api/checkout : the Buy buttons. Opens Stripe's hosted checkout for one LunchboxWM license.
// A plain form post works without JavaScript; the page adds an attempt id so a double click
// (or a resubmitted form) reuses the same Checkout Session instead of opening two.

const REQUIREMENTS =
  "Lunchbox runs on Macs with Apple silicon (M1 or later) and macOS 14 Sonoma or later. " +
  "This is a one-time purchase in US dollars: no subscription. Not sure it fits? You have 14 days to ask for a refund.";

export async function onRequestPost({ request, env }) {
  let attempt = "";
  const type = request.headers.get("Content-Type") || "";
  if (type.includes("application/x-www-form-urlencoded") || type.includes("multipart/form-data")) {
    attempt = String((await request.formData()).get("attempt") || "");
  } else if (type.includes("application/json")) {
    attempt = String((await request.json().catch(() => ({}))).attempt || "");
  }
  if (!/^[A-Za-z0-9-]{16,64}$/.test(attempt)) attempt = crypto.randomUUID();

  const site = env.SITE_URL;
  const params = new URLSearchParams({
    mode: "payment",
    "line_items[0][price]": env.STRIPE_PRICE_ID,
    "line_items[0][quantity]": "1",
    // Stripe Tax adds sales tax or VAT where you're registered; STRIPE_TAX = "off" until it's set up.
    "automatic_tax[enabled]": env.STRIPE_TAX === "off" ? "false" : "true",
    customer_creation: "always",
    allow_promotion_codes: "true",
    "consent_collection[terms_of_service]": "required",
    "custom_text[terms_of_service_acceptance][message]":
      `I agree to the [Terms of Sale and License](${site}/terms.html). I want Lunchbox delivered right away, ` +
      `and I understand that this ends the EU/UK right to cancel; the [14-day refund](${site}/refunds.html) still applies.`,
    "custom_text[submit][message]": REQUIREMENTS,
    "payment_intent_data[description]": "Lunchbox license",
    "payment_intent_data[statement_descriptor_suffix]": "LUNCHBOXWM",
    success_url: `${site}/thanks.html?session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${site}/#pricing`,
  });

  const response = await fetch("https://api.stripe.com/v1/checkout/sessions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.STRIPE_SECRET_KEY}`,
      "Content-Type": "application/x-www-form-urlencoded",
      "Idempotency-Key": `lunchbox-checkout-${attempt}`,
    },
    body: params,
  });
  const session = await response.json();
  if (!response.ok || !session.url) {
    const back = `${site}/?checkout=unavailable#pricing`;
    return type.includes("application/json")
      ? new Response(JSON.stringify({ error: "checkout-unavailable" }), { status: 502, headers: { "Content-Type": "application/json" } })
      : Response.redirect(back, 303);
  }
  return type.includes("application/json")
    ? new Response(JSON.stringify({ url: session.url }), { headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } })
    : Response.redirect(session.url, 303);
}
