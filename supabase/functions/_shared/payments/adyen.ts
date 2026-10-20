// deno-lint-ignore-file no-explicit-any -- provider JSON is read field by field.
/**
 * Adyen: Pay by Link (Checkout API v71, POST /paymentLinks →
 * https://docs.adyen.com/unified-commerce/pay-by-link/create-payment-links/api)
 * and HMAC-signed standard webhooks
 * (https://docs.adyen.com/development-resources/webhooks/verify-hmac-signatures):
 * for each NotificationRequestItem, HMAC-SHA256 with the hex-decoded HMAC key
 * over pspReference:originalReference:merchantAccountCode:merchantReference:
 * value:currency:eventCode:success, base64, equal to
 * additionalData.hmacSignature. Adyen expects "[accepted]" back.
 * Test: checkout-test.adyen.com; live needs the account's live URL prefix.
 */
import { fromHex, hmacSha256Base64, safeEqual } from "./crypto.ts";
import {
  type Account,
  type Adapter,
  type Incoming,
  jsonOrThrow,
  major,
  minor,
  type Outcome,
  pub,
  requireFields,
  secret,
  testFromStatus,
  type Verified,
} from "./types.ts";

export function adyenBase(a: Account): string {
  if (a.values.mode === "Sandbox") return "https://checkout-test.adyen.com/v71";
  const prefix = pub(a, "adyen", "liveUrlPrefix");
  return `https://${prefix}-checkout-live.adyenpayments.com/checkout/v71`;
}
const headers = (a: Account) => ({ "X-API-Key": secret(a, "apiKey"), "Content-Type": "application/json" });

/** The string Adyen signs for one notification item. */
export function adyenSource(item: any): string {
  return [
    item?.pspReference ?? "",
    item?.originalReference ?? "",
    item?.merchantAccountCode ?? "",
    item?.merchantReference ?? "",
    item?.amount?.value ?? "",
    item?.amount?.currency ?? "",
    item?.eventCode ?? "",
    item?.success ?? "",
  ].join(":");
}

export async function adyenItemValid(item: any, hmacKeyHex: string): Promise<boolean> {
  const given = item?.additionalData?.hmacSignature;
  if (!given) return false;
  return safeEqual(given, await hmacSha256Base64(fromHex(hmacKeyHex), adyenSource(item)));
}

const linkStatus = (s: unknown): Outcome["status"] =>
  s === "completed" ? "paid" : s === "expired" ? "expired" : "pending";

export const adyen: Adapter = {
  id: "adyen",
  name: "Adyen",
  ready: true,
  verified: true,
  notes: [
    "Live mode needs the live URL prefix from the Customer Area (Developers → API URLs).",
    "An AUTHORISATION is taken as paid: keep automatic capture on (Adyen's default).",
    "Without the HMAC key, every webhook is checked by asking Adyen for the payment link.",
  ],
  requiredPublic: ["merchantAccount"],
  requiredSecrets: ["apiKey"],
  secretFields: ["apiKey", "hmacKey"],

  async createCheckout(account, input, http) {
    requireFields(this, account);
    if (account.values.mode !== "Sandbox" && !pub(account, "adyen", "liveUrlPrefix")) {
      throw new Error("Adyen live mode needs the live URL prefix");
    }
    const res = await http(`${adyenBase(account)}/paymentLinks`, {
      method: "POST",
      headers: { ...headers(account), "Idempotency-Key": `link-${input.reference}` },
      body: JSON.stringify({
        reference: input.reference,
        amount: { value: minor(input.amount), currency: input.currency },
        merchantAccount: pub(account, "adyen", "merchantAccount"),
        description: input.description,
        returnUrl: input.returnUrl,
        countryCode: "MY",
        shopperEmail: input.customer.email || undefined,
        reusable: false,
      }),
    });
    const l = await jsonOrThrow(res, "Adyen payment link");
    return { url: l.url, providerRef: l.id };
  },

  async verify(account, req: Incoming): Promise<Verified> {
    let body: any;
    try {
      body = JSON.parse(req.rawBody);
    } catch {
      return { ok: false, reason: "not_json" };
    }
    const key = secret(account, "hmacKey");
    const ack = { status: 200, body: "[accepted]", type: "text/plain" };
    const outcomes: Outcome[] = [];
    for (const wrap of body?.notificationItems ?? []) {
      const item = wrap?.NotificationRequestItem;
      if (!item) continue;
      if (key && !(await adyenItemValid(item, key))) return { ok: false, reason: "bad_signature" };
      if (item.eventCode !== "AUTHORISATION") continue;
      outcomes.push({
        reference: item.merchantReference,
        status: item.success === "true" ? "paid" : "pending",
        amount: major(item.amount?.value),
        currency: item.amount?.currency,
        event: "AUTHORISATION",
      });
    }
    return { ok: true, outcomes, ack, lookupOnly: !key };
  },

  async lookup(account, intent, http) {
    if (!intent.providerRef) return null;
    const res = await http(`${adyenBase(account)}/paymentLinks/${encodeURIComponent(intent.providerRef)}`, {
      headers: headers(account),
    });
    const l = await jsonOrThrow(res, "Adyen payment link");
    return {
      providerRef: l.id,
      reference: l.reference,
      status: linkStatus(l.status),
      amount: major(l.amount?.value),
      currency: l.amount?.currency,
    };
  },

  async test(account, http) {
    if (!secret(account, "apiKey") || !pub(account, "adyen", "merchantAccount")) {
      return { result: "fail", title: "Credentials missing", detail: "Set the merchant account and the API key." };
    }
    if (account.values.mode !== "Sandbox" && !pub(account, "adyen", "liveUrlPrefix")) {
      return { result: "fail", title: "Live URL prefix not set", detail: "Live mode needs the live URL prefix." };
    }
    const res = await http(`${adyenBase(account)}/paymentMethods`, {
      method: "POST",
      headers: headers(account),
      body: JSON.stringify({ merchantAccount: pub(account, "adyen", "merchantAccount") }),
    });
    return await testFromStatus(res, "Adyen accepted the API key for this merchant account.");
  },
};
