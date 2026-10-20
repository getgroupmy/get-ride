/**
 * Billplz (Malaysia): API v3 bills (https://www.billplz.com/api#v3-bills) and
 * X-Signature: every "key" + "value" pair of the callback (or of the
 * redirect's billplz[...] parameters, brackets removed: "billplzid",
 * "billplzpaid", "billplzpaid_at") except the signature itself, sorted
 * case-insensitively, joined with "|", HMAC-SHA256 hex with the account's
 * X Signature Key. Sandbox: www.billplz-sandbox.com.
 */
import { hmacSha256Hex, sameHex } from "./crypto.ts";
import {
  type Account,
  type Adapter,
  basic,
  formBody,
  type Incoming,
  jsonOrThrow,
  major,
  minor,
  msisdn,
  ok,
  type Outcome,
  pairs,
  pub,
  requireFields,
  secret,
  testFromStatus,
  type Verified,
} from "./types.ts";

const base = (a: Account) =>
  a.values.mode === "Sandbox" ? "https://www.billplz-sandbox.com/api" : "https://www.billplz.com/api";
const auth = (a: Account) => ({ Authorization: basic(secret(a, "apiKey"), "") });

/** The string Billplz signs, from the received pairs (signature left out). */
export function billplzSource(params: [string, string][]): string {
  return params
    .filter(([k]) => k !== "x_signature" && k !== "billplzx_signature")
    .map(([k, v]) => `${k}${v}`)
    .sort((a, b) => {
      const x = a.toLowerCase(), y = b.toLowerCase();
      return x < y ? -1 : x > y ? 1 : 0;
    })
    .join("|");
}

export async function billplzSignature(params: [string, string][], key: string): Promise<string> {
  return await hmacSha256Hex(key, billplzSource(params));
}

/** billplz[id]=… → billplzid=…; other query keys are not Billplz's. */
export function billplzRedirectPairs(query: URLSearchParams): [string, string][] {
  const out: [string, string][] = [];
  for (const [k, v] of query.entries()) {
    const m = /^billplz\[([^\]]*)\]$/.exec(k);
    if (m) out.push([`billplz${m[1]}`, v]);
  }
  return out;
}

function billOutcome(b: Record<string, unknown>): Outcome {
  const paid = String(b.paid) === "true";
  return {
    providerRef: b.id ? String(b.id) : undefined,
    reference: b.reference_1 ? String(b.reference_1) : undefined,
    status: paid ? "paid" : String(b.state) === "deleted" ? "cancelled" : "pending",
    amount: major(paid && b.paid_amount !== undefined ? b.paid_amount : b.amount),
    currency: "MYR",
  };
}

export const billplz: Adapter = {
  id: "billplz",
  name: "Billplz",
  ready: true,
  verified: true,
  notes: ["Without the X Signature Key, every callback is checked by asking Billplz for the bill."],
  requiredPublic: ["collectionId"],
  requiredSecrets: ["apiKey"],
  secretFields: ["apiKey", "xSignatureKey"],

  async createCheckout(account, input, http) {
    requireFields(this, account);
    const phone = msisdn(input.customer.phone);
    const res = await http(`${base(account)}/v3/bills`, {
      method: "POST",
      headers: { ...auth(account), "Content-Type": "application/x-www-form-urlencoded" },
      body: formBody({
        collection_id: pub(account, "billplz", "collectionId"),
        // Billplz needs an email or a mobile number.
        email: input.customer.email || undefined,
        mobile: phone || undefined,
        name: (input.customer.name || "GET.ride customer").slice(0, 255),
        amount: minor(input.amount),
        callback_url: input.webhookUrl,
        redirect_url: input.returnUrl,
        description: input.description.slice(0, 200),
        reference_1_label: "Reference",
        reference_1: input.reference,
      }),
    });
    const b = await jsonOrThrow(res, "Billplz bill");
    return { url: b.url, providerRef: b.id };
  },

  async verify(account, req: Incoming): Promise<Verified> {
    const redirect = billplzRedirectPairs(req.query);
    const params = redirect.length ? redirect : pairs(req.rawBody);
    const given = redirect.length
      ? req.query.get("billplz[x_signature]") ?? ""
      : new URLSearchParams(req.rawBody).get("x_signature") ?? "";
    const map = Object.fromEntries(redirect.length ? params.map(([k, v]) => [k.replace(/^billplz/, ""), v]) : params);
    if (!map.id) return { ok: false, reason: "no_bill" };
    const key = secret(account, "xSignatureKey");
    let lookupOnly = false;
    if (key) {
      if (!given || !sameHex(given, await billplzSignature(params, key))) return { ok: false, reason: "bad_signature" };
    } else {
      lookupOnly = true;
    }
    return { ok: true, outcomes: [billOutcome(map)], ack: ok(), lookupOnly };
  },

  async lookup(account, intent, http) {
    if (!intent.providerRef) return null;
    const res = await http(`${base(account)}/v3/bills/${encodeURIComponent(intent.providerRef)}`, {
      headers: auth(account),
    });
    return billOutcome(await jsonOrThrow(res, "Billplz bill"));
  },

  async test(account, http) {
    if (!secret(account, "apiKey")) return { result: "fail", title: "API key not set", detail: "Set the API secret key." };
    const id = pub(account, "billplz", "collectionId");
    if (!id) return { result: "fail", title: "Collection ID not set", detail: "Set the collection ID." };
    const res = await http(`${base(account)}/v3/collections/${encodeURIComponent(id)}`, { headers: auth(account) });
    if (res.status === 404) {
      await res.body?.cancel();
      return { result: "fail", title: "Collection not found", detail: `Billplz has no collection ${id} for this key.` };
    }
    return await testFromStatus(res, "Billplz accepted the API key and found the collection.");
  },
};
