import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { onRequestGet as licenseGet } from "../../functions/api/license.js";
import { onRequestPost as webhookPost } from "../../functions/api/stripe-webhook.js";
import { onRequestPost as recoverPost, onRequestGet as recoverGet } from "../../functions/api/recover.js";
import { verifyLicense, revocationHash } from "../lib/license.js";
import { onRequestGet as revokedGet } from "../../functions/api/revoked.js";

const fixture = JSON.parse(readFileSync(new URL("./fixture.json", import.meta.url), "utf8"));
const env = {
  STRIPE_SECRET_KEY: "sk_test_x", STRIPE_WEBHOOK_SECRET: "whsec_test", STRIPE_PRICE_ID: "price_lunchbox",
  LICENSE_PRIVATE_KEY: JSON.stringify(fixture.privateJwk), RESEND_API_KEY: "re_x",
  EMAIL_FROM: "LunchboxWM <support@example.com>", SUPPORT_EMAIL: "support@example.com", SITE_URL: "https://lunchbox.example",
};

const session = (over = {}) => ({
  id: "cs_test_abcdefghij1", status: "complete", payment_status: "paid", created: 1792000000,
  customer_details: { email: "Buyer@Example.com" },
  line_items: { data: [{ price: { id: "price_lunchbox" } }] },
  payment_intent: { id: "pi_buyer", latest_charge: { refunded: false, disputed: false } }, ...over,
});

let sessions, emails;
// A stand-in for the Cloudflare KV namespace that holds revoked orders.
const kv = () => {
  const store = new Map();
  return { store, async put(k, v) { store.set(k, v); },
    async list({ prefix }) { return { keys: [...store.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })), list_complete: true }; } };
};
beforeEach(() => {
  sessions = { cs_test_abcdefghij1: session() };
  emails = [];
  env.REVOKED = kv();
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(String(input instanceof Request ? input.url : input));
    if (url.hostname === "api.resend.com") {
      emails.push({ body: JSON.parse(init.body), key: init.headers["Idempotency-Key"] });
      return new Response(JSON.stringify({ id: "email_1" }));
    }
    if (url.pathname === "/v1/checkout/sessions" && url.searchParams.get("payment_intent")) {
      const pi = url.searchParams.get("payment_intent");
      return new Response(JSON.stringify({ data: Object.values(sessions).filter((s) => s.payment_intent?.id === pi) }));
    }
    if (url.pathname === "/v1/checkout/sessions") {
      const email = url.searchParams.get("customer_details[email]");
      const data = Object.values(sessions).filter((s) => s.customer_details.email.toLowerCase() === email);
      return new Response(JSON.stringify({ data }));
    }
    const id = url.pathname.split("/").pop();
    return sessions[id] ? new Response(JSON.stringify(sessions[id])) : new Response(JSON.stringify({ error: { message: "No such session" } }), { status: 404 });
  };
});

const get = (id) => licenseGet({ request: new Request(`https://lunchbox.example/api/license?session_id=${id}`), env });

test("thank-you page gets the license for a paid LunchboxWM purchase, the same on every refresh", async () => {
  const first = await (await get("cs_test_abcdefghij1")).json();
  const again = await (await get("cs_test_abcdefghij1")).json();
  assert.equal(first.status, "paid");
  assert.equal(first.license, again.license);
  assert.deepEqual(await verifyLicense(first.license, fixture.publicKey), { email: "buyer@example.com", order: "cs_test_abcdefghij1", issued: 1792000000 });
});

test("no license for a refunded or charged-back purchase", async () => {
  sessions.cs_test_abcdefghij1 = session({ payment_intent: { id: "pi_buyer", latest_charge: { refunded: true } } });
  assert.equal((await get("cs_test_abcdefghij1")).status, 404);
  sessions.cs_test_abcdefghij1 = session({ payment_intent: { id: "pi_buyer", latest_charge: { disputed: true } } });
  assert.equal((await get("cs_test_abcdefghij1")).status, 404);
  await recover("buyer@example.com");
  assert.equal(emails.length, 1);
  assert.doesNotMatch(emails[0].body.text, /lunchbox1\./);
});

test("full refunds and chargebacks go on the revoked list; partial refunds don't", async () => {
  const hash = await revocationHash("cs_test_abcdefghij1");
  assert.equal(await (await hook({ type: "charge.refunded", created: 1, data: { object: { payment_intent: "pi_buyer", refunded: false } } })).text(), "partial refund: license kept");
  assert.equal(env.REVOKED.store.size, 0);
  assert.equal(await (await hook({ type: "charge.refunded", created: 2, data: { object: { payment_intent: "pi_buyer", refunded: true } } })).text(), "revoked (refunded)");
  assert.equal(JSON.parse(env.REVOKED.store.get(`r:${hash}`)).order, "cs_test_abcdefghij1");
  env.REVOKED = kv();
  assert.equal(await (await hook({ type: "charge.dispute.created", created: 3, data: { object: { payment_intent: "pi_buyer" } } })).text(), "revoked (disputed)");
  const list = await (await revokedGet({ request: new Request("https://lunchbox.example/api/revoked"), env })).json();
  assert.deepEqual(list, { revoked: [hash] });
});

test("no license for an unpaid, foreign or made-up session", async () => {
  sessions.cs_test_abcdefghij1 = session({ payment_status: "unpaid" });
  assert.equal((await (await get("cs_test_abcdefghij1")).json()).status, "processing");
  sessions.cs_test_abcdefghij1 = session({ line_items: { data: [{ price: { id: "price_other" } }] } });
  assert.equal((await get("cs_test_abcdefghij1")).status, 404);
  assert.equal((await get("nonsense")).status, 404);
});

async function signed(body, secret = env.STRIPE_WEBHOOK_SECRET, t = Math.floor(Date.now() / 1000)) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${t}.${body}`)));
  return `t=${t},v1=${[...mac].map((b) => b.toString(16).padStart(2, "0")).join("")}`;
}

const hook = async (event, header) => {
  const body = JSON.stringify(event);
  const request = new Request("https://lunchbox.example/api/stripe-webhook", { method: "POST", body, headers: { "Stripe-Signature": header ?? (await signed(body)) } });
  return webhookPost({ request, env });
};

test("webhook emails the license once per purchase, even when Stripe retries", async () => {
  const event = { type: "checkout.session.completed", data: { object: { id: "cs_test_abcdefghij1" } } };
  assert.equal(await (await hook(event)).text(), "sent");
  await hook(event);
  assert.equal(emails.length, 2);
  assert.equal(emails[0].key, emails[1].key); // Resend drops the repeat
  assert.deepEqual(emails[0].body.to, ["Buyer@Example.com"]);
  assert.match(emails[0].body.text, /lunchbox1\./);
  assert.match(emails[0].body.text, /https:\/\/lunchbox\.example\/activate\.html#lunchbox1\./);
});

test("webhook refuses forged or stale calls and skips unpaid sessions", async () => {
  const event = { type: "checkout.session.completed", data: { object: { id: "cs_test_abcdefghij1" } } };
  assert.equal((await hook(event, await signed(JSON.stringify(event), "whsec_wrong"))).status, 400);
  assert.equal((await hook(event, await signed(JSON.stringify(event), env.STRIPE_WEBHOOK_SECRET, 1000))).status, 400);
  sessions.cs_test_abcdefghij1 = session({ payment_status: "unpaid" });
  assert.equal(await (await hook(event)).text(), "not a paid LunchboxWM purchase");
  assert.equal(emails.length, 0);
});

const recover = (email, e = env) => recoverPost({ request: new Request("https://lunchbox.example/api/recover", { method: "POST", body: JSON.stringify({ email }), headers: { "Content-Type": "application/json" } }), env: e });

test("lost license: emails the buyer's licenses, or a note that there are none, and answers the same either way", async () => {
  sessions.cs_test_second00001 = session({ id: "cs_test_second00001", created: 1792100000 });
  const found = await (await recover(" buyer@example.com ")).json();
  const missing = await (await recover("nobody@example.com")).json();
  assert.deepEqual(found, missing);
  assert.equal(emails.length, 2);
  assert.equal((emails[0].body.text.match(/^lunchbox1\./gm) || []).length, 2);
  assert.match(emails[0].key, /^lunchbox-recover-buyer@example\.com-\d{4}-\d{2}-\d{2}$/);
  assert.deepEqual(emails[1].body.to, ["nobody@example.com"]);
  assert.match(emails[1].body.text, /couldn't find a Lunchbox license/);
  assert.doesNotMatch(emails[1].body.text, /lunchbox1\./);
  assert.equal(emails[1].body.reply_to, "support@example.com");
  // Its own key, so buying later the same day still lets the license email through.
  assert.match(emails[1].key, /^lunchbox-recover-none-nobody@example\.com-\d{4}-\d{2}-\d{2}$/);
  assert.equal((await recover("not-an-email")).status, 400);
});

test("lost license without email set up says to write to support, not that an email is coming", async () => {
  const off = { ...env, RESEND_API_KEY: undefined };
  assert.deepEqual(await (await recoverGet({ env: off })).json(), { email: false });
  assert.deepEqual(await (await recoverGet({ env })).json(), { email: true });
  const r = await recover("buyer@example.com", off);
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { status: "write-to-support" });
  const form = await recoverPost({ request: new Request("https://lunchbox.example/api/recover", { method: "POST", body: new URLSearchParams({ email: "buyer@example.com" }), headers: { "Content-Type": "application/x-www-form-urlencoded" } }), env: off });
  assert.equal(form.headers.get("Location"), "https://lunchbox.example/recover.html?support");
  assert.equal(emails.length, 0);
  assert.equal((await recover("not-an-email", off)).status, 400);
});

import { onRequestPost as checkoutPost } from "../../functions/api/checkout.js";

test("checkout: one LunchboxWM, tax on, terms required, requirements shown; double clicks reuse the session", async () => {
  const calls = [];
  globalThis.fetch = async (input, init = {}) => {
    calls.push({ url: String(input), key: init.headers["Idempotency-Key"], body: new URLSearchParams(init.body) });
    return new Response(JSON.stringify({ id: "cs_test_new0000001", url: "https://checkout.stripe.com/c/pay/cs_test_new0000001" }));
  };
  const form = () => new Request("https://lunchbox.example/api/checkout", {
    method: "POST", body: new URLSearchParams({ attempt: "6f1c2b9e-7d3a-4e5f-9a10-1b2c3d4e5f60" }),
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
  });
  const first = await checkoutPost({ request: form(), env });
  await checkoutPost({ request: form(), env });
  assert.equal(first.status, 303);
  assert.equal(first.headers.get("Location"), "https://checkout.stripe.com/c/pay/cs_test_new0000001");
  assert.equal(calls[0].key, calls[1].key);
  const b = calls[0].body;
  assert.equal(b.get("line_items[0][price]"), "price_lunchbox");
  assert.equal(b.get("line_items[0][quantity]"), "1");
  assert.equal(b.get("automatic_tax[enabled]"), "true");
  assert.equal(b.get("consent_collection[terms_of_service]"), "required");
  assert.match(b.get("custom_text[submit][message]"), /Apple silicon/);
  assert.equal(b.get("success_url"), "https://lunchbox.example/thanks.html?session_id={CHECKOUT_SESSION_ID}");
});

test("checkout: if Stripe is down, the buyer lands back on pricing with a note, not an error page", async () => {
  globalThis.fetch = async () => new Response(JSON.stringify({ error: { message: "down" } }), { status: 500 });
  const r = await checkoutPost({ request: new Request("https://lunchbox.example/api/checkout", { method: "POST" }), env });
  assert.equal(r.status, 303);
  assert.equal(r.headers.get("Location"), "https://lunchbox.example/?checkout=unavailable#pricing");
});

test("lost license works as a plain form too", async () => {
  const r = await recoverPost({ request: new Request("https://lunchbox.example/api/recover", { method: "POST", body: new URLSearchParams({ email: "buyer@example.com" }), headers: { "Content-Type": "application/x-www-form-urlencoded" } }), env });
  assert.equal(r.status, 303);
  assert.equal(r.headers.get("Location"), "https://lunchbox.example/recover.html?sent");
  assert.equal(emails.length, 1);
});
