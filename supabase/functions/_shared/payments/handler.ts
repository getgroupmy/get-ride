/**
 * The `payments` edge function, without its network and database: routes
 * a request, calls the provider's adapter and settles payment intents
 * through the 0252 functions (service role). index.ts wires the real ones;
 * handler_test.ts stands fakes in.
 *
 *   POST /payments/checkout  {purpose, amount, idempotency_key}   signed-in user
 *        → {id, reference, status, amount, currency, provider, test_mode,
 *           checkout_url | form, close_on}
 *   POST /payments/status    {id}                                  the payer or a gateway admin
 *        → {id, reference, status, applied, amount, currency}
 *   GET  /payments/providers                                       gateway admin
 *   POST /payments/test      {gateway_id, checkout?}               gateway admin (edit)
 *        → {result, title, detail, checkout_url?, form?}
 *   POST /payments/dispatch-link {request_id}                      the stand's operator (0251)
 *        → {url, reference, amount, status, test_mode}: a stand order's
 *          payment link, put on the order and texted to the customer
 *   *    /payments/webhook/<provider>/<gateway id>                 the provider
 *   *    /payments/return/<intent id>[?cancel=1]                   the payer's browser
 *   *    /payments/back/<provider>/<gateway id>                    the payer's browser (dashboard-set return)
 *
 * Nothing here ever returns a secret. Pages for the payer's browser are
 * plain text: Supabase serves no HTML from a function's own address.
 */
import { ADAPTERS, providerInfo } from "./registry.ts";
import {
  type Account,
  type Adapter,
  type Checkout,
  type Customer,
  type Http,
  type Incoming,
  type Outcome,
  PaymentError,
} from "./types.ts";

export interface IntentRow {
  id: string;
  reference: string;
  user_id: string | null;
  purpose: string;
  purpose_ref: string | null;
  gateway_id: string | null;
  provider: string;
  test_mode: boolean;
  amount: number | string;
  currency: string;
  status: string;
  provider_ref: string | null;
  checkout_url: string | null;
  applied: string | null;
  failure: string | null;
}

export interface Db {
  /** A 0252 function, with the service role. Throws an Error whose message is the SQL error. */
  // deno-lint-ignore no-explicit-any
  rpc(fn: string, args: Record<string, unknown>): Promise<any>;
  intentById(id: string): Promise<IntentRow | null>;
  intentByReference(reference: string): Promise<IntentRow | null>;
  intentByProviderRef(provider: string, providerRef: string): Promise<IntentRow | null>;
  customer(uid: string): Promise<Customer>;
}

export interface Deps {
  db: Db;
  http: Http;
  /** Milliseconds since the epoch. */
  now(): number;
  /** This function's public address, e.g. https://<ref>.supabase.co/functions/v1/payments */
  base: string;
  /** The signed-in user the Authorization header names, or null. */
  user(authorization: string | null): Promise<{ id: string } | null>;
  /** May the caller ask for this stand order's payment link (payment_dispatch_link_allowed, as them). */
  mayLinkOrder(authorization: string | null, requestId: string): Promise<boolean>;
  /** Edit access to Admin → Payment Gateways (null: not signed in). */
  canEditGateways(authorization: string | null): Promise<boolean | null>;
  log?(message: string): void;
}

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Max-Age": "7200",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });

const text = (body: string, status = 200, type = "text/plain; charset=utf-8") =>
  new Response(body, { status, headers: { "Content-Type": type, "Cache-Control": "no-store" } });

/** Purposes a payer can start from the app. 'dispatch' and 'ride_card' have hooks only (see 0252). */
export const OPEN_PURPOSES = ["wallet_topup"];

/** SQL refusals the app is told by name. */
const KNOWN_ERRORS: Record<string, number> = {
  invalid_amount: 400,
  unknown_purpose: 400,
  idempotency_key_reused: 409,
  no_gateway: 409,
  too_many_payments: 429,
};

function sqlError(e: unknown): Response {
  const msg = e instanceof Error ? e.message : String(e);
  for (const [code, status] of Object.entries(KNOWN_ERRORS)) {
    if (msg.includes(code)) return json({ error: code }, status);
  }
  throw e;
}

/** The function's route: what follows ".../payments/". */
export function routeOf(url: URL): string[] {
  const parts = url.pathname.split("/").filter(Boolean);
  const at = parts.lastIndexOf("payments");
  return at >= 0 ? parts.slice(at + 1) : parts;
}

const amountOf = (i: IntentRow) => Number(i.amount);

const summary = (i: IntentRow) => ({
  id: i.id,
  reference: i.reference,
  status: i.status,
  applied: i.applied,
  amount: amountOf(i),
  currency: i.currency,
  provider: i.provider,
  test_mode: i.test_mode,
});

export function urlsFor(base: string, intent: { id: string; provider: string; gateway_id: string | null }) {
  return {
    returnUrl: `${base}/return/${intent.id}`,
    cancelUrl: `${base}/return/${intent.id}?cancel=1`,
    webhookUrl: `${base}/webhook/${intent.provider}/${intent.gateway_id}`,
  };
}

/** The addresses an admin pastes at the provider for one account. */
export const gatewayUrls = (base: string, provider: string, gatewayId: string) => ({
  webhook: `${base}/webhook/${provider}/${gatewayId}`,
  back: `${base}/back/${provider}/${gatewayId}`,
});

const describe = (i: IntentRow): string =>
  i.purpose === "wallet_topup"
    ? `GET.wallet top up ${i.reference}`
    : i.purpose === "test"
    ? `GET.ride test payment ${i.reference}`
    : `GET.ride payment ${i.reference}`;

function clientIp(req: Request): string {
  const fwd = req.headers.get("x-forwarded-for") ?? "";
  return fwd.split(",")[0]?.trim() || req.headers.get("cf-connecting-ip") || "";
}

async function accountFor(deps: Deps, gatewayId: string | null): Promise<Account | null> {
  if (!gatewayId) return null;
  const a = await deps.db.rpc("payment_gateway_account", { p_gateway: gatewayId });
  return a && typeof a === "object" && a.id ? (a as Account) : null;
}

async function openCheckout(
  deps: Deps,
  adapter: Adapter,
  account: Account,
  intent: IntentRow,
  req: Request,
  given?: { customer: Customer; description: string },
): Promise<Checkout> {
  const customer = given?.customer ??
    (intent.user_id ? await deps.db.customer(intent.user_id) : { name: "", email: "", phone: "" });
  return await adapter.createCheckout(account, {
    reference: intent.reference,
    amount: amountOf(intent),
    currency: intent.currency,
    description: given?.description ?? describe(intent),
    customer,
    ...urlsFor(deps.base, intent),
    testMode: intent.test_mode,
    ip: clientIp(req),
  }, deps.http);
}

/** Stores the hosted page (a form is rebuilt each time: nothing to store). */
async function checkoutReply(deps: Deps, intent: IntentRow, checkout: Checkout) {
  if ("url" in checkout) {
    await deps.db.rpc("payment_intent_set_checkout", {
      p_id: intent.id,
      p_provider_ref: checkout.providerRef ?? null,
      p_url: checkout.url,
    });
    return { checkout_url: checkout.url };
  }
  if (checkout.providerRef) {
    await deps.db.rpc("payment_intent_set_checkout", { p_id: intent.id, p_provider_ref: checkout.providerRef, p_url: null });
  }
  return { form: checkout.form };
}

/**
 * What one verified callback (or lookup) means for its intent. Returns the
 * settled intent, or null when nothing was settled (unknown, another
 * account's, or not confirmed).
 */
export async function applyOutcome(
  deps: Deps,
  adapter: Adapter,
  account: Account,
  outcome: Outcome,
  opts: { lookupOnly?: boolean; intent?: IntentRow | null; via: string },
): Promise<IntentRow | null> {
  const db = deps.db;
  let intent = opts.intent ?? null;
  if (!intent && outcome.reference) intent = await db.intentByReference(outcome.reference);
  if (!intent && outcome.providerRef) intent = await db.intentByProviderRef(adapter.id, outcome.providerRef);
  if (!intent || intent.provider !== adapter.id || intent.gateway_id !== account.id) {
    deps.log?.(`payments: ${adapter.id} ${opts.via}: no intent for ${outcome.reference ?? outcome.providerRef ?? "?"}`);
    return null;
  }
  if (outcome.reference && outcome.reference !== intent.reference) return null;
  if (intent.status === "paid") return intent;

  let final: Outcome = outcome;
  let via = opts.via;
  const mustLook = opts.lookupOnly || (outcome.status === "paid" && adapter.confirmPaid === true);
  if (mustLook) {
    if (!adapter.lookup) {
      deps.log?.(`payments: ${adapter.id} ${opts.via}: unsigned and no lookup, ignored`);
      return null;
    }
    const looked = await adapter.lookup(account, {
      reference: intent.reference,
      providerRef: outcome.providerRef ?? intent.provider_ref,
      amount: amountOf(intent),
      currency: intent.currency,
    }, deps.http);
    if (!looked) return null;
    if (looked.reference && looked.reference !== intent.reference) return null;
    if (outcome.status === "paid" && !opts.lookupOnly && looked.status !== "paid") {
      deps.log?.(`payments: ${adapter.id} ${intent.reference}: signed paid, lookup says ${looked.status}; left pending`);
      return null;
    }
    final = { ...looked, providerRef: looked.providerRef ?? outcome.providerRef, event: outcome.event };
    via = `${opts.via}+lookup`;
  }
  return await db.rpc("payment_intent_settle", {
    p_reference: intent.reference,
    p_provider: intent.provider,
    p_status: final.status,
    p_provider_ref: final.providerRef ?? null,
    p_amount: final.amount ?? null,
    p_currency: final.currency ?? null,
    p_callback: {
      via,
      event: final.event ?? null,
      status: final.status,
      provider_ref: final.providerRef ?? null,
      amount: final.amount ?? null,
      currency: final.currency ?? null,
    },
  });
}

async function incomingOf(req: Request, url: URL, deps: Deps): Promise<Incoming> {
  return {
    method: req.method,
    headers: req.headers,
    query: url.searchParams,
    rawBody: req.method === "GET" ? "" : await req.text(),
    now: Math.floor(deps.now() / 1000),
  };
}

const payerPage = (i: IntentRow | null): string => {
  const head = "GET.ride payment";
  if (!i) return `${head}\n\nThis payment was not found.`;
  const amount = `${i.currency} ${amountOf(i).toFixed(2)}`;
  switch (i.status) {
    case "paid":
      return `${head}\n\nPayment received: ${amount} (${i.reference}).\nYou can close this page and go back to GET.ride.`;
    case "pending":
      return `${head}\n\nWe're waiting for the payment to be confirmed (${i.reference}).\nGo back to GET.ride: it updates by itself.`;
    case "cancelled":
      return `${head}\n\nThe payment was cancelled. Nothing was charged.\nYou can close this page and go back to GET.ride.`;
    default:
      return `${head}\n\nThe payment did not go through (${i.status}).\nYou can close this page and go back to GET.ride.`;
  }
};

// ---- Routes ----------------------------------------------------------------------------------------

async function checkout(req: Request, deps: Deps): Promise<Response> {
  const user = await deps.user(req.headers.get("Authorization"));
  if (!user) return json({ error: "not_signed_in" }, 401);
  const body = await req.json().catch(() => null) as Record<string, unknown> | null;
  const purpose = String(body?.purpose ?? "");
  if (!OPEN_PURPOSES.includes(purpose)) return json({ error: "purpose_not_open" }, 409);
  const amount = Number(body?.amount);
  if (!Number.isFinite(amount)) return json({ error: "invalid_amount" }, 400);
  const key = typeof body?.idempotency_key === "string" ? body.idempotency_key : null;

  let intent: IntentRow;
  try {
    intent = await deps.db.rpc("payment_intent_create", {
      p_user: user.id,
      p_purpose: purpose,
      p_amount: amount,
      p_idempotency_key: key,
    });
  } catch (e) {
    return sqlError(e);
  }
  const closeOn = [`${deps.base}/return/`, `${deps.base}/back/`];
  if (intent.status !== "pending") return json({ ...summary(intent), close_on: closeOn });
  if (intent.checkout_url) return json({ ...summary(intent), checkout_url: intent.checkout_url, close_on: closeOn });

  const account = await accountFor(deps, intent.gateway_id);
  const adapter = ADAPTERS[intent.provider];
  if (!account || !account.active || !adapter?.ready) return json({ error: "gateway_not_ready" }, 409);
  try {
    const c = await openCheckout(deps, adapter, account, intent, req);
    return json({ ...summary(intent), ...(await checkoutReply(deps, intent, c)), close_on: closeOn });
  } catch (e) {
    if (e instanceof PaymentError) {
      deps.log?.(`payments: checkout ${intent.reference}: ${e.message}`);
      return json({ error: e.code }, e.status === 400 ? 502 : e.status);
    }
    throw e;
  }
}

async function status(req: Request, deps: Deps): Promise<Response> {
  const auth = req.headers.get("Authorization");
  const user = await deps.user(auth);
  if (!user) return json({ error: "not_signed_in" }, 401);
  const body = await req.json().catch(() => null) as Record<string, unknown> | null;
  const id = String(body?.id ?? "");
  let intent = /^[0-9a-f-]{36}$/i.test(id) ? await deps.db.intentById(id) : null;
  if (!intent) return json({ error: "not_found" }, 404);
  if (intent.user_id !== user.id && (await deps.canEditGateways(auth)) !== true) return json({ error: "not_found" }, 404);
  if (intent.status === "pending") {
    const adapter = ADAPTERS[intent.provider];
    const account = await accountFor(deps, intent.gateway_id);
    if (adapter?.lookup && account) {
      try {
        const looked = await adapter.lookup(account, {
          reference: intent.reference,
          providerRef: intent.provider_ref,
          amount: amountOf(intent),
          currency: intent.currency,
        }, deps.http);
        if (looked && looked.status !== "pending") {
          intent = (await applyOutcome(deps, adapter, account, looked, { intent, via: "status", lookupOnly: false })) ??
            intent;
        }
      } catch (e) {
        deps.log?.(`payments: status ${intent.reference}: ${(e as Error).message}`);
      }
    }
  }
  return json(summary(intent));
}

async function test(req: Request, deps: Deps): Promise<Response> {
  const auth = req.headers.get("Authorization");
  const can = await deps.canEditGateways(auth);
  if (can === null) return json({ error: "not_signed_in" }, 401);
  if (can !== true) return json({ error: "admin_only" }, 403);
  const body = await req.json().catch(() => null) as Record<string, unknown> | null;
  const account = await accountFor(deps, String(body?.gateway_id ?? "") || null);
  if (!account) return json({ error: "not_found" }, 404);
  const adapter = ADAPTERS[String(account.values.providerId ?? "")];
  if (!adapter) return json({ result: "fail", title: "Unknown provider", detail: String(account.values.providerId ?? "") });
  let result;
  try {
    result = await adapter.test(account, deps.http);
  } catch (e) {
    result = { result: "fail", title: "Could not reach the provider", detail: (e as Error).message };
  }
  if (body?.checkout !== true || !adapter.ready || result.result === "fail") return json(result);
  // An RM 1.00 checkout the admin can open, to see the provider accept the account.
  const user = await deps.user(auth);
  try {
    const intent: IntentRow = await deps.db.rpc("payment_intent_create", {
      p_user: user!.id,
      p_purpose: "test",
      p_amount: 1,
      p_idempotency_key: null,
      p_purpose_ref: null,
      p_gateway: account.id,
    });
    const c = await openCheckout(deps, adapter, account, intent, req);
    return json({ ...result, reference: intent.reference, ...(await checkoutReply(deps, intent, c)) });
  } catch (e) {
    return json({ ...result, result: "fail", title: "Checkout refused", detail: (e as Error).message });
  }
}

/** Refusals of payment_dispatch_intent the console shows in words. */
const DISPATCH_ERRORS = ["no_gateway", "fare_unknown", "already_paid", "not_pay_link", "order_closed", "unknown_order"];

async function dispatchLink(req: Request, deps: Deps): Promise<Response> {
  const auth = req.headers.get("Authorization");
  const user = await deps.user(auth);
  if (!user) return json({ error: "not_signed_in" }, 401);
  const body = await req.json().catch(() => null) as Record<string, unknown> | null;
  const id = String(body?.request_id ?? "");
  if (!/^[0-9a-f-]{36}$/i.test(id)) return json({ error: "unknown_order" }, 404);
  if (!(await deps.mayLinkOrder(auth, id))) return json({ error: "not_authorized" }, 403);
  // deno-lint-ignore no-explicit-any
  let a: any;
  try {
    a = await deps.db.rpc("payment_dispatch_intent", { p_request: id });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    const code = DISPATCH_ERRORS.find((c) => msg.includes(c));
    if (code) return json({ error: code }, 409);
    throw e;
  }
  const intent = a as IntentRow;
  let url = intent.checkout_url;
  if (!url) {
    const account = await accountFor(deps, intent.gateway_id);
    const adapter = ADAPTERS[intent.provider];
    if (!account || !account.active || !adapter?.ready) return json({ error: "gateway_not_ready" }, 409);
    let c: Checkout;
    try {
      c = await openCheckout(deps, adapter, account, intent, req, {
        customer: {
          name: String(a.customer?.name ?? ""),
          phone: String(a.customer?.phone ?? ""),
          email: String(a.customer?.email ?? ""),
        },
        description: `GET.ride ${a.stand_name ?? "stand"} ticket ${a.ticket_no ?? intent.reference}`,
      });
    } catch (e) {
      if (e instanceof PaymentError) {
        deps.log?.(`payments: dispatch link ${intent.reference}: ${e.message}`);
        return json({ error: e.code }, e.status === 400 ? 502 : e.status);
      }
      throw e;
    }
    // A form-posted page (iPay88) has no address to text.
    if (!("url" in c)) return json({ error: "gateway_needs_form" }, 409);
    await deps.db.rpc("payment_intent_set_checkout", { p_id: intent.id, p_provider_ref: c.providerRef ?? null, p_url: c.url });
    url = c.url;
  }
  // On the order, and (again) to the customer's phone.
  await deps.db.rpc("payment_dispatch_link_set", { p_request: id, p_url: url, p_actor: user.id });
  return json({ url, reference: intent.reference, amount: amountOf(intent), status: intent.status, test_mode: intent.test_mode });
}

async function webhook(req: Request, url: URL, deps: Deps, provider: string, gatewayId: string, page: boolean) {
  const adapter = ADAPTERS[provider];
  const account = /^[0-9a-f-]{36}$/i.test(gatewayId) ? await accountFor(deps, gatewayId) : null;
  if (!adapter || !account || account.values.providerId !== provider) {
    return page ? text(payerPage(null), 404) : text("not found", 404);
  }
  const incoming = await incomingOf(req, url, deps);
  const v = await adapter.verify(account, incoming, deps.http);
  if (!v.ok) {
    deps.log?.(`payments: ${provider} ${page ? "back" : "webhook"} refused: ${v.reason}`);
    return page ? text(payerPage(null), 400) : text("invalid", 400);
  }
  let last: IntentRow | null = null;
  for (const o of v.outcomes) {
    last = (await applyOutcome(deps, adapter, account, o, { lookupOnly: v.lookupOnly, via: page ? "back" : "webhook" })) ??
      last;
  }
  if (page) return text(payerPage(last));
  const ack = v.ack ?? { status: 200, body: "OK", type: "text/plain" };
  return text(ack.body, ack.status ?? 200, ack.type ?? "text/plain");
}

async function payerReturn(req: Request, url: URL, deps: Deps, id: string): Promise<Response> {
  let intent = /^[0-9a-f-]{36}$/i.test(id) ? await deps.db.intentById(id) : null;
  if (!intent) return text(payerPage(null), 404);
  if (intent.status !== "pending") return text(payerPage(intent));
  const adapter = ADAPTERS[intent.provider];
  const account = await accountFor(deps, intent.gateway_id);
  if (!adapter || !account) return text(payerPage(intent));
  const incoming = await incomingOf(req, url, deps);
  if (url.searchParams.get("cancel") === "1") {
    // Asked again first: a payment may have gone through just before.
    if (adapter.lookup) {
      try {
        intent = (await applyOutcome(deps, adapter, account, { status: "pending" }, {
          intent,
          lookupOnly: true,
          via: "return",
        })) ?? intent;
      } catch { /* the cancel stands */ }
    }
    if (intent.status === "pending") {
      intent = await deps.db.rpc("payment_intent_settle", {
        p_reference: intent.reference,
        p_provider: intent.provider,
        p_status: "cancelled",
        p_callback: { via: "return", event: "cancel", status: "cancelled" },
      });
    }
    return text(payerPage(intent));
  }
  try {
    const v = incoming.rawBody || [...url.searchParams.keys()].length
      ? await adapter.verify(account, incoming, deps.http)
      : null;
    if (v?.ok && v.outcomes.length) {
      for (const o of v.outcomes) {
        intent = (await applyOutcome(deps, adapter, account, o, { intent, lookupOnly: v.lookupOnly, via: "return" })) ??
          intent;
      }
    } else if (adapter.lookup) {
      intent = (await applyOutcome(deps, adapter, account, { status: "pending" }, {
        intent,
        lookupOnly: true,
        via: "return",
      })) ?? intent;
    }
  } catch (e) {
    deps.log?.(`payments: return ${intent.reference}: ${(e as Error).message}`);
  }
  return text(payerPage(intent));
}

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const url = new URL(req.url);
  const [route, a, b] = routeOf(url);
  try {
    switch (route) {
      case "checkout":
        return req.method === "POST" ? await checkout(req, deps) : json({ error: "method_not_allowed" }, 405);
      case "status":
        return req.method === "POST" ? await status(req, deps) : json({ error: "method_not_allowed" }, 405);
      case "test":
        return req.method === "POST" ? await test(req, deps) : json({ error: "method_not_allowed" }, 405);
      case "dispatch-link":
        return req.method === "POST" ? await dispatchLink(req, deps) : json({ error: "method_not_allowed" }, 405);
      case "providers": {
        const can = await deps.canEditGateways(req.headers.get("Authorization"));
        if (can === null) return json({ error: "not_signed_in" }, 401);
        return json({ providers: providerInfo(), base: deps.base });
      }
      case "webhook":
        return await webhook(req, url, deps, a ?? "", b ?? "", false);
      case "back":
        return await webhook(req, url, deps, a ?? "", b ?? "", true);
      case "return":
        return await payerReturn(req, url, deps, a ?? "");
      default:
        return json({ error: "not_found" }, 404);
    }
  } catch (e) {
    deps.log?.(`payments: ${route}: ${e instanceof Error ? e.message : "failed"}`);
    // A provider retries on an error, which is what an unreachable database needs.
    return json({ error: "unavailable" }, 503);
  }
}
