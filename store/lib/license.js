// Tessel license keys: `tessel1.<payload>.<signature>`, Ed25519 over compact JSON.
// The app checks them offline with the matching public key (Sources/TesselCore/License.swift).
// Runs in Cloudflare Workers and in Node 20+ (both have WebCrypto Ed25519).

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export const PREFIX = "tessel1";
export const PRODUCT = "tessel";

function toBase64URL(bytes) {
  let s = "";
  for (const b of new Uint8Array(bytes)) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromBase64URL(text) {
  const s = text.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(text.length / 4) * 4, "=");
  return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
}

export function normalizeEmail(email) {
  return String(email || "").trim().toLowerCase();
}

/** Signs a license. Same order, email and time in, same key out (Ed25519 is deterministic),
 *  so the thank-you page, the email and a later lookup all show the identical key. */
export async function issueLicense({ email, order, issued }, privateJwk) {
  const e = normalizeEmail(email);
  if (!e || !order || !Number.isFinite(issued)) throw new Error("license needs email, order and issued");
  const payload = encoder.encode(JSON.stringify({ p: PRODUCT, e, o: order, t: Math.floor(issued) }));
  const key = await crypto.subtle.importKey("jwk", privateJwk, { name: "Ed25519" }, false, ["sign"]);
  const signature = await crypto.subtle.sign({ name: "Ed25519" }, key, payload);
  return `${PREFIX}.${toBase64URL(payload)}.${toBase64URL(signature)}`;
}

/** Checks a key against the public key (raw 32 bytes, base64). Returns its fields, or null. */
export async function verifyLicense(text, publicKeyBase64) {
  const parts = String(text).replace(/\s+/g, "").split(".");
  if (parts.length !== 3 || parts[0] !== PREFIX) return null;
  try {
    const payload = fromBase64URL(parts[1]);
    const raw = Uint8Array.from(atob(publicKeyBase64), (c) => c.charCodeAt(0));
    const key = await crypto.subtle.importKey("raw", raw, { name: "Ed25519" }, false, ["verify"]);
    if (!(await crypto.subtle.verify({ name: "Ed25519" }, key, fromBase64URL(parts[2]), payload))) return null;
    const fields = JSON.parse(decoder.decode(payload));
    return fields.p === PRODUCT ? { email: fields.e, order: fields.o, issued: fields.t } : null;
  } catch {
    return null;
  }
}
