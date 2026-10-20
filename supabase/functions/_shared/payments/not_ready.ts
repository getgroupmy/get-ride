/**
 * Providers whose API could not be checked from here: their credentials are
 * kept (write-only, like every other), but nothing is charged through them
 * until an adapter is written from their documentation. The admin sees
 * "Charging not built yet" and the account can't take a payment.
 */
import { type Adapter, fieldsOnlyTest, PaymentError, type Verified } from "./types.ts";

function notReady(id: string, name: string, secretFields: string[], requiredPublic: string[], why: string): Adapter {
  return {
    id,
    name,
    ready: false,
    verified: false,
    notes: [why, "Credentials can be saved now; payments go through another account until this adapter is built."],
    requiredPublic,
    requiredSecrets: secretFields.slice(0, 1),
    secretFields,
    createCheckout() {
      return Promise.reject(new PaymentError("gateway_not_ready", `${name}: charging is not built yet`, 409));
    },
    verify(): Promise<Verified> {
      return Promise.resolve({ ok: false, reason: "gateway_not_ready" });
    },
    test(account) {
      const r = fieldsOnlyTest(this, account, `Credentials are kept, but charging through ${name} isn't built yet.`);
      return Promise.resolve(r);
    },
  };
}

export const adaptis = notReady(
  "adaptis",
  "ADAPTIS (iPay88 + eGHL)",
  ["merchantKey", "eghlPassword"],
  ["merchantCode"],
  "ADAPTIS's own API was not available to check. For iPay88 or eGHL payments now, add an iPay88 or eGHL account " +
    "with the same merchant credentials.",
);

export const payhalal = notReady(
  "payhalal",
  "PayHalal",
  ["secretKey"],
  ["merchantId", "appId"],
  "PayHalal's API documentation was not available to check its request and signature format.",
);

export const paydibs = notReady(
  "paydibs",
  "Paydibs",
  ["merchantPassword"],
  ["merchantId", "paymentUrl"],
  "Paydibs's API documentation (v3api-docs.paydibs.com) was not reachable to check its request and signature format.",
);
