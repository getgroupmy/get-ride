// ============================================================================
// payments — Supabase Edge Function
// ----------------------------------------------------------------------------
// Takes payments through the gateway accounts in Admin → Payment Gateways
// (migration 0252): opens a provider's hosted checkout for a payment intent,
// verifies the provider's webhooks and the payer's return, settles the
// intent (a paid GET.wallet top-up credits the wallet once), and tests an
// account's credentials for the admin. Gateway secrets are read here, with
// the service role, from Vault (payment_gateway_account) and never returned.
// Routes and rules: _shared/payments/handler.ts; one adapter per provider in
// _shared/payments/.
//
// Deploy (webhooks and the payer's browser carry no Supabase token, so the
// function checks every caller itself):
//   supabase functions deploy payments --no-verify-jwt
// Optional secret PAYMENTS_PUBLIC_URL: the address providers and browsers
// reach this function at, when it isn't <SUPABASE_URL>/functions/v1/payments.
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { callerCanEditHere, PAYMENT_GATEWAY_PAGES } from "../_shared/admin_page.ts";
import { handle, type IntentRow } from "../_shared/payments/handler.ts";

const url = Deno.env.get("SUPABASE_URL") ?? "";
const db = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});
const base = (Deno.env.get("PAYMENTS_PUBLIC_URL") ?? `${url}/functions/v1/payments`).replace(/\/+$/, "");

const INTENT_COLUMNS =
  "id, reference, user_id, purpose, purpose_ref, gateway_id, provider, test_mode, amount, currency, status, provider_ref, checkout_url, applied, failure";

async function one(q: PromiseLike<{ data: unknown; error: { message: string } | null }>): Promise<IntentRow | null> {
  const { data, error } = await q;
  if (error) throw new Error(error.message);
  return (data as IntentRow | null) ?? null;
}

Deno.serve((req) =>
  handle(req, {
    base,
    now: () => Date.now(),
    http: (u, init) => fetch(u, { ...init, signal: init?.signal ?? AbortSignal.timeout(20_000) }),
    log: (m) => console.error(m),
    db: {
      async rpc(fn, args) {
        const { data, error } = await db.rpc(fn, args);
        if (error) throw new Error(`${fn}: ${error.message}`);
        return data;
      },
      intentById: (id) => one(db.from("payment_intents").select(INTENT_COLUMNS).eq("id", id).maybeSingle()),
      intentByReference: (r) => one(db.from("payment_intents").select(INTENT_COLUMNS).eq("reference", r).maybeSingle()),
      intentByProviderRef: (p, r) =>
        one(
          db.from("payment_intents").select(INTENT_COLUMNS).eq("provider", p).eq("provider_ref", r)
            .order("created_at", { ascending: false }).limit(1).maybeSingle(),
        ),
      async customer(uid) {
        const { data } = await db.from("profiles").select("name, email, phone").eq("id", uid).maybeSingle();
        return {
          name: String(data?.name ?? "").trim(),
          email: String(data?.email ?? "").trim(),
          phone: String(data?.phone ?? "").trim(),
        };
      },
    },
    async user(authorization) {
      const token = /^Bearer\s+(.+)$/i.exec((authorization ?? "").trim())?.[1]?.trim();
      if (!token) return null;
      const { data, error } = await db.auth.getUser(token);
      return error || !data?.user ? null : { id: data.user.id };
    },
    canEditGateways: (authorization) => callerCanEditHere(authorization, PAYMENT_GATEWAY_PAGES).catch(() => false),
  })
);
