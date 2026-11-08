import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { issueLicense, verifyLicense } from "../lib/license.js";

const fixture = JSON.parse(readFileSync(new URL("./fixture.json", import.meta.url), "utf8"));

test("issuing is deterministic, so every place shows the same key", async () => {
  const again = await issueLicense({ email: "Buyer@Example.com ", order: fixture.order, issued: fixture.issued }, fixture.privateJwk);
  assert.equal(again, fixture.license);
});

test("verify accepts its own keys and rejects tampering", async () => {
  assert.deepEqual(await verifyLicense(fixture.license, fixture.publicKey), { email: fixture.email, order: fixture.order, issued: fixture.issued });
  const broken = fixture.license.slice(0, 20) + (fixture.license[20] === "A" ? "B" : "A") + fixture.license.slice(21);
  assert.equal(await verifyLicense(broken, fixture.publicKey), null);
  assert.equal(await verifyLicense("garbage", fixture.publicKey), null);
});

test("refuses to sign without an email or order", async () => {
  await assert.rejects(issueLicense({ email: "", order: "cs_1", issued: 1 }, fixture.privateJwk));
  await assert.rejects(issueLicense({ email: "a@b.c", order: "", issued: 1 }, fixture.privateJwk));
});
