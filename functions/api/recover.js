// POST /api/recover {email} : lost your license? We email every LunchboxWM license bought with
// that address, to that address only. The answer never says whether the email bought anything.
import { sessionsForEmail, isPaidLunchbox } from "../../store/lib/stripe.js";
import { licenseFor, sendLicenses } from "../../store/lib/fulfill.js";
import { normalizeEmail } from "../../store/lib/license.js";

const done = () => new Response(JSON.stringify({ status: "sent-if-found" }), { headers: { "Content-Type": "application/json" } });

export async function onRequestPost({ request, env }) {
  // The page posts JSON; without JavaScript the form posts itself, and gets a page back.
  const isForm = !(request.headers.get("Content-Type") || "").includes("application/json");
  const reply = (status, code) => isForm
    ? Response.redirect(`${env.SITE_URL}/recover.html?${code}`, 303)
    : new Response(JSON.stringify({ status }), { status: code === "sent" ? 200 : 400, headers: { "Content-Type": "application/json" } });
  let email;
  try {
    email = normalizeEmail(isForm ? (await request.formData()).get("email") : (await request.json()).email);
  } catch {
    return reply("bad-request", "bad");
  }
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) || email.length > 254) return reply("bad-email", "bad");
  const sessions = (await sessionsForEmail(env, email)).filter((s) => isPaidLunchbox(s, env));
  if (sessions.length) {
    const licenses = await Promise.all(sessions.map((s) => licenseFor(s, env)));
    // One recovery email per address per day, however often the form is sent.
    const day = new Date().toISOString().slice(0, 10);
    await sendLicenses(env, { to: email, licenses, idempotencyKey: `lunchbox-recover-${email}-${day}`, recovery: true });
  }
  return isForm ? reply("sent-if-found", "sent") : done();
}
