#!/usr/bin/env node
// Issue or check Tessel licenses by hand (support, press, gifts), with the real signing key.
//   node scripts/license.mjs issue <email> [order]   order defaults to manual-<date>
//   node scripts/license.mjs check <key>
// The key lives at ~/.config/sentient-donut/tessel-license-signing.jwk (or $TESSEL_LICENSE_KEY).
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { issueLicense, verifyLicense } from "../store/lib/license.js";

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
} else {
  console.error("usage: license.mjs issue <email> [order] | check <key>");
  process.exit(64);
}
