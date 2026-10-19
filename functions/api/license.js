// GET /api/license?session_id=cs_… : the thank-you page asks for the license of the
// purchase it was sent back from. Works on refresh, and only for a paid LunchboxWM purchase.
import { getSession, isPaidLunchbox } from "../../store/lib/stripe.js";
import { licenseFor } from "../../store/lib/fulfill.js";

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });

export async function onRequestGet({ request, env }) {
  const id = new URL(request.url).searchParams.get("session_id");
  let session;
  try {
    session = await getSession(env, id);
  } catch {
    return json({ status: "error", message: "We couldn't reach the payment service. Refresh in a moment." }, 502);
  }
  if (!session) return json({ status: "unknown" }, 404);
  if (session.status === "complete" && session.payment_status === "unpaid") {
    // Some payment methods (bank debits) take a few days; the license is emailed when it clears.
    return json({ status: "processing", email: session.customer_details?.email });
  }
  if (!isPaidLunchbox(session, env)) return json({ status: "unknown" }, 404);
  const license = await licenseFor(session, env);
  return json({ status: "paid", email: session.customer_details?.email, license });
}
