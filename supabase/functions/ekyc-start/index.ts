// ============================================================================
// ekyc-start — Supabase Edge Function
// ----------------------------------------------------------------------------
// GET eKYC (migration 0439): starts an identity check for the signed-in user
// on our eKYC server and returns the one-time page the app opens inside the
// app. The API key stays here (Admin → API Keys → GET eKYC → server); the
// app only ever sees the page's link. The result arrives at ekyc-webhook.
//
// Request:  POST { purpose: "rider_gate" | "first" } with the user's token.
// Response: 200 { url, session_id, expires_at }
//           400 bad_request · 401 not_signed_in · 403 ekyc_off
//           503 no_key · 502 unavailable
//
// Deploy: supabase functions deploy ekyc-start --no-verify-jwt (it checks the
// user's token itself, like the other functions; see supabase/config.toml)
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { createBody, EKYC_TIMEOUT_MS, type EkycPurpose, ekycServer } from "../_shared/ekyc.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "7200",
};

const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });

const db = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});

async function setting(key: string): Promise<unknown> {
  const { data, error } = await db.from("app_settings").select("value").eq("key", key).maybeSingle();
  if (error) throw error;
  return data?.value ?? null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply({ error: "bad_request" }, 405);

  const authorization = req.headers.get("Authorization");
  if (!authorization) return reply({ error: "not_signed_in" }, 401);
  const user = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: who, error: whoErr } = await user.auth.getUser();
  const uid = who?.user?.id;
  if (whoErr || !uid) return reply({ error: "not_signed_in" }, 401);

  const body = await req.json().catch(() => ({})) as Record<string, unknown>;
  const purpose = body.purpose;
  if (purpose !== "rider_gate" && purpose !== "first") return reply({ error: "bad_request" }, 400);

  const { data: inUse } = await db.rpc("ekyc_in_use", { p_purpose: purpose });
  if (inUse !== true) return reply({ error: "ekyc_off" }, 403);

  const server = ekycServer(await setting("api_providers"));
  if (!server) return reply({ error: "no_key" }, 503);
  const config = (await setting("ekyc") ?? {}) as Record<string, unknown>;

  let created: Record<string, unknown>;
  try {
    const res = await fetch(`${server.url}/v1/verifications`, {
      method: "POST",
      headers: { "X-API-Key": server.secret, "Content-Type": "application/json" },
      body: JSON.stringify(createBody(uid, purpose as EkycPurpose, config.test === true)),
      signal: AbortSignal.timeout(EKYC_TIMEOUT_MS),
    });
    created = await res.json().catch(() => ({}));
    if (!res.ok || typeof created.id !== "string" || typeof created.hosted_url !== "string") {
      console.error("ekyc-start: GET eKYC answered", res.status, created?.detail ?? "");
      return reply({ error: "unavailable" }, 502);
    }
  } catch (e) {
    console.error("ekyc-start: GET eKYC unreachable", String(e));
    return reply({ error: "unavailable" }, 502);
  }

  const { data: session, error } = await db.from("ekyc_sessions").insert({
    user_id: uid,
    purpose,
    verification_id: created.id,
    test: config.test === true,
  }).select("id").single();
  if (error || !session) return reply({ error: "unavailable" }, 502);

  return reply({ url: created.hosted_url, session_id: session.id, expires_at: created.hosted_url_expires_at ?? null });
});
