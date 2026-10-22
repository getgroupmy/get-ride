// ============================================================================
// freight-notify — Supabase Edge Function
// ----------------------------------------------------------------------------
// Sends a freight delivery's recipient its tracking link (migration 0267):
// the notices the database queued when the trip started, by SMS (queued on
// the outbound support-message gateway route, sms_outbox, as other app SMS)
// and/or WhatsApp (the Business Cloud API, with this function's secrets
// WHATSAPP_TOKEN and WHATSAPP_PHONE_NUMBER_ID), as Admin > Freight settings
// chose. Each notice is reported sent or failed (failed ones are tried up
// to three times). A courier delivery's notice (0268) also carries its
// confirmation code, which freight_notices_claim hands over only here.
//
//   POST { rideId? }   -> { sent, failed }
//
// Callers: the driver's or rider's app right after the trip starts (their
// own ride only), the database job every minute (x-push-secret, the push
// webhook's existing Vault secret), or the service role. See
// _shared/freight_notify.ts.
//
// Deploy (the job carries no user JWT; every caller is checked here):
//   supabase functions deploy freight-notify --no-verify-jwt
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { callerOf, type Notice, noticeText, rideIdOf, SHARE_BASE_DEFAULT, whatsappRequest } from "../_shared/freight_notify.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

const url = Deno.env.get("SUPABASE_URL") ?? "";
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply({ error: "POST only" }, 405);

  const { caller, bearer } = await callerOf(req, {
    serviceKey,
    secretOk: async (s) => {
      const { data } = await db.rpc("push_webhook_secret_ok", { p_secret: s });
      return data === true;
    },
  });
  if (!caller) return reply({ error: "Not allowed" }, 401);

  const body = await req.json().catch(() => ({}));
  const rideId = rideIdOf(body);
  if (caller === "user") {
    // A signed-in person asks only about a ride of their own.
    const { data: who } = await db.auth.getUser(bearer!);
    const uid = who?.user?.id;
    if (!uid || !rideId) return reply({ error: "Not allowed" }, 403);
    const { data: ok } = await db.rpc("freight_notice_caller_ok", { p_ride: rideId, p_user: uid });
    if (ok !== true) return reply({ error: "Not allowed" }, 403);
  }

  const { data: notices, error } = await db.rpc("freight_notices_claim", { p_ride: rideId });
  if (error) return reply({ error: error.message }, 500);

  const base = Deno.env.get("SHARE_BASE_URL") ?? SHARE_BASE_DEFAULT;
  const wa = { token: Deno.env.get("WHATSAPP_TOKEN"), phoneNumberId: Deno.env.get("WHATSAPP_PHONE_NUMBER_ID") };
  let sent = 0;
  let failed = 0;
  for (const n of (notices ?? []) as Notice[]) {
    const text = noticeText(n, base);
    let problem: string | null = null;
    try {
      if (n.channel === "sms") {
        const { error: e } = await db.from("sms_outbox").insert({
          channel: "support_message",
          to_phone: n.to_phone,
          body: text,
          created_by: null,
        });
        if (e) problem = e.message;
      } else {
        const r = whatsappRequest(n, text, wa);
        if (!r) {
          problem = "WhatsApp isn't set up for this function.";
        } else {
          const res = await fetch(r.url, r.init);
          if (!res.ok) problem = `WhatsApp answered ${res.status}`;
          await res.body?.cancel();
        }
      }
    } catch (e) {
      problem = String(e).slice(0, 200);
    }
    await db.rpc("freight_notice_report", { p_id: n.id, p_ok: problem === null, p_error: problem });
    problem === null ? sent++ : failed++;
  }
  return reply({ sent, failed });
});
