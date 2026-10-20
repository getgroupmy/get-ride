// deno-lint-ignore-file no-explicit-any -- provider JSON is read field by field.
/**
 * 2C2P: PGW v4.3 redirect API. Requests and answers are JWTs (HS256) signed
 * with the merchant's secret key, sent as {"payload": "<jwt>"}:
 *   * POST /payment/4.3/paymentToken {merchantID, invoiceNo, description,
 *     amount, currencyCode, frontendReturnUrl, backendReturnUrl} → payload
 *     with webPaymentUrl, paymentToken and respCode "0000";
 *   * the backend notification is a signed {"payload"} with invoiceNo and
 *     respCode ("0000" = paid);
 *   * POST /payment/4.3/paymentInquiry {merchantID, invoiceNo, locale}.
 * Sandbox: sandbox-pgw.2c2p.com.
 */
import { fromBase64Url, hmacSha256, safeEqual, toBase64Url, utf8 } from "./crypto.ts";
import {
  type Account,
  type Adapter,
  type Http,
  type Incoming,
  jsonOrThrow,
  num,
  type Outcome,
  PaymentError,
  pub,
  requireFields,
  secret,
  type Verified,
} from "./types.ts";

const base = (a: Account) =>
  a.values.mode === "Sandbox" ? "https://sandbox-pgw.2c2p.com/payment/4.3" : "https://pgw.2c2p.com/payment/4.3";

export async function signJwt(payload: unknown, key: string): Promise<string> {
  const head = toBase64Url(utf8(JSON.stringify({ alg: "HS256", typ: "JWT" })));
  const body = toBase64Url(utf8(JSON.stringify(payload)));
  const sig = toBase64Url(await hmacSha256(key, `${head}.${body}`));
  return `${head}.${body}.${sig}`;
}

/** The JWT's claims when its HS256 signature is the key's, else null. */
export async function readJwt(jwt: string, key: string): Promise<any | null> {
  const parts = String(jwt ?? "").split(".");
  if (parts.length !== 3) return null;
  const expected = toBase64Url(await hmacSha256(key, `${parts[0]}.${parts[1]}`));
  if (!safeEqual(expected, parts[2])) return null;
  try {
    const head = JSON.parse(new TextDecoder().decode(fromBase64Url(parts[0])));
    if (head?.alg !== "HS256") return null;
    return JSON.parse(new TextDecoder().decode(fromBase64Url(parts[1])));
  } catch {
    return null;
  }
}

async function call(a: Account, path: string, claims: Record<string, unknown>, http: Http): Promise<any> {
  const key = secret(a, "secretKey");
  const res = await http(`${base(a)}/${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ payload: await signJwt({ merchantID: pub(a, "2c2p", "merchantId"), ...claims }, key) }),
  });
  const body = await jsonOrThrow(res, `2C2P ${path}`);
  if (typeof body?.payload !== "string") {
    // Errors come back unsigned: {respCode, respDesc}.
    throw new PaymentError("provider_error", `2C2P ${path}: ${body?.respCode ?? ""} ${body?.respDesc ?? ""}`.trim(), 502);
  }
  const claimsBack = await readJwt(body.payload, key);
  if (!claimsBack) throw new PaymentError("provider_error", `2C2P ${path}: answer not signed with this key`, 502);
  return claimsBack;
}

const outcomeOf = (c: any): Outcome => ({
  reference: c?.invoiceNo,
  providerRef: c?.tranRef ?? undefined,
  status: c?.respCode === "0000" ? "paid" : "pending",
  amount: num(c?.amount),
  currency: c?.currencyCode,
});

export const twoc2p: Adapter = {
  id: "2c2p",
  name: "2C2P",
  ready: true,
  verified: false,
  notes: [
    "Not confirmed against 2C2P's own documentation (not reachable from here): the v4.3 hosts, the claim names and " +
    "that respCode 0000 alone means paid are as 2C2P's published SDKs use them. Make a sandbox payment before going live.",
    "Only respCode 0000 is taken as paid; every other code leaves the payment pending.",
  ],
  requiredPublic: ["merchantId"],
  requiredSecrets: ["secretKey"],
  secretFields: ["secretKey"],

  async createCheckout(account, input, http) {
    requireFields(this, account);
    const c = await call(account, "paymentToken", {
      invoiceNo: input.reference,
      description: input.description.slice(0, 250),
      amount: Number(input.amount.toFixed(2)),
      currencyCode: input.currency,
      frontendReturnUrl: input.returnUrl,
      backendReturnUrl: input.webhookUrl,
    }, http);
    if (c?.respCode !== "0000" || !c?.webPaymentUrl) {
      throw new PaymentError("provider_error", `2C2P paymentToken: ${c?.respCode ?? ""} ${c?.respDesc ?? ""}`, 502);
    }
    return { url: c.webPaymentUrl, providerRef: c.paymentToken };
  },

  async verify(account, req: Incoming): Promise<Verified> {
    let jwt = "";
    try {
      jwt = JSON.parse(req.rawBody)?.payload ?? "";
    } catch {
      // The payer's browser posts paymentResponse (not signed): only a lookup decides.
      const resp = new URLSearchParams(req.rawBody).get("paymentResponse");
      if (resp) {
        try {
          const c = JSON.parse(new TextDecoder().decode(fromBase64Url(resp)));
          return { ok: true, outcomes: [{ ...outcomeOf(c), status: "pending" }], lookupOnly: true };
        } catch { /* fall through */ }
      }
      return { ok: false, reason: "no_payload" };
    }
    const c = await readJwt(jwt, secret(account, "secretKey"));
    if (!c) return { ok: false, reason: "bad_signature" };
    return { ok: true, outcomes: [outcomeOf(c)] };
  },

  async lookup(account, intent, http) {
    const c = await call(account, "paymentInquiry", { invoiceNo: intent.reference, locale: "en" }, http);
    return outcomeOf(c);
  },

  async test(account, http) {
    if (!pub(account, "2c2p", "merchantId") || !secret(account, "secretKey")) {
      return { result: "fail", title: "Credentials missing", detail: "Set the merchant ID and the secret key." };
    }
    try {
      const c = await call(account, "paymentInquiry", { invoiceNo: "GRTEST000000000000", locale: "en" }, http);
      return {
        result: "ok",
        title: "Connected",
        detail: `2C2P answered, signed with this key (${c?.respCode ?? "no code"} ${c?.respDesc ?? ""}).`.trim(),
      };
    } catch (e) {
      return { result: "fail", title: "Not accepted", detail: (e as Error).message };
    }
  },
};
