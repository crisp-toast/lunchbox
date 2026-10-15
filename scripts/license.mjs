#!/usr/bin/env node
// Issue or check Tessel licenses by hand (support, press, gifts), with the real signing key.
//   node scripts/license.mjs issue <email> [order]   order defaults to manual-<date>
//   node scripts/license.mjs check <key>
//   node scripts/license.mjs revoke <order>         prints the command that switches a license off
// The key lives at ~/.config/sentient-donut/tessel-license-signing.jwk (or $TESSEL_LICENSE_KEY).
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { issueLicense, verifyLicense, revocationHash } from "../store/lib/license.js";

const PUBLIC_KEY = "qLQZTRdDyv019zqGNELstTUJa3rmQXnLNk5eoYgM1nU=";
const [command, arg, order] = process.argv.slice(2);
if (command === "issue" && arg) {
  const path = process.env.TESSEL_LICENSE_KEY || `${homedir()}/.config/sentient-donut/tessel-license-signing.jwk`;
  const jwk = JSON.parse(readFileSync(path, "utf8"));
  const key = await issueLicense({ email: arg, order: order || `manual-${new Date().toISOString().slice(0, 10)}`, issued: Date.now() / 1000 }, jwk);
  console.log(key);
} else if (command === "check" && arg) {
  const fields = await verifyLicense(arg, PUBLIC_KEY);
  console.log(fields ? JSON.stringify(fields) : "NOT VALID");
  process.exit(fields ? 0 : 1);
} else if (command === "revoke" && arg) {
  // For a key shared in public, say. Refunds and chargebacks are revoked automatically.
  const hash = await revocationHash(arg);
  console.log(`npx wrangler kv key put --binding REVOKED "r:${hash}" '{"order":"${arg}","reason":"manual"}' --remote`);
} else {
  console.error("usage: license.mjs issue <email> [order] | check <key> | revoke <order>");
  process.exit(64);
}
