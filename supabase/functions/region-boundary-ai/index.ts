// region-boundary-ai — Supabase Edge Function
// ----------------------------------------------------------------------------
// Admin → Regions → Boundary editor: a third "Fetch boundary" source beside
// OpenStreetMap and a typed bounding box. The admin asks the AI for a region's
// outline and gets back a `BoundaryShape` they can review and edit before
// saving, the same shape OSM produces.
//
// The provider, model and keys are whatever Admin → Fare AI / API Keys has
// switched on (app setting `fare_ai_provider`), read here with the service
// role via `_shared/ai_providers.ts` and never returned — so this uses Gemini
// by default and follows the admin's choice when they switch. The question and
// the parsing are pure in `_shared/region_boundary_ai.ts`.
//
//   POST { query }  -> { ok: true, boundary, provider } | { ok: false, error, reason }
//
// Callers: admins, at most 30 requests an hour each (auth_rate_take). Each is
// logged in admin_audit_log ('region_boundary.ai').
//
// Deploy (the token is checked here):
//   supabase functions deploy region-boundary-ai --no-verify-jwt
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import {
  type AIServiceConfig,
  callProvider,
  jsonObjectIn,
  serviceOf,
} from "../_shared/ai_providers.ts";
import { BOUNDARY_SYSTEM, buildBoundaryPrompt, normalizeAiBoundary } from "../_shared/region_boundary_ai.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "7200",
};

const REQUESTS_PER_HOUR = 30;

function bearerToken(header: string | null): string | null {
  const m = header?.match(/^Bearer\s+(.+)$/i);
  return m ? m[1].trim() : null;
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, error: "method", reason: "POST only" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) return json({ ok: false, error: "missing_credentials" }, 500);
  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const token = bearerToken(req.headers.get("Authorization"));
  const { data: who } = token ? await admin.auth.getUser(token) : { data: { user: null } };
  const uid = who?.user?.id;
  if (!uid) return json({ ok: false, error: "sign_in", reason: "Please sign in." }, 401);

  // Geography is admin-only (the editor lives in the admin panel).
  const { data: adm } = await admin.from("admin_access").select("profile_id").eq("profile_id", uid).limit(1).maybeSingle();
  if (!adm) return json({ ok: false, error: "not_allowed", reason: "Admins only." }, 403);

  const { data: wait, error: rateErr } = await admin.rpc("auth_rate_take", {
    p_bucket: "region_boundary_ai",
    p_key: uid,
    p_limit: REQUESTS_PER_HOUR,
    p_window: "1 hour",
  });
  if (rateErr || typeof wait !== "number") return json({ ok: false, error: "unavailable" }, 503);
  if (wait > 0) return json({ ok: false, error: "rate_limited", retry_after: wait, reason: "Too many requests. Try again shortly." }, 429);

  let body: { query?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "bad_json" }, 400);
  }
  const query = `${body.query ?? ""}`.trim();
  if (query.length < 2 || query.length > 160) {
    return json({ ok: false, error: "query_required", reason: "Give the region's name." }, 400);
  }

  const { data: cfgRow, error: cfgErr } = await admin.from("app_settings").select("value").eq("key", "fare_ai_provider").maybeSingle();
  if (cfgErr) return json({ ok: false, error: "config_unavailable" }, 503);
  const { provider, model, keys } = serviceOf((cfgRow?.value ?? null) as AIServiceConfig | null);
  if (keys.length === 0) return json({ ok: false, error: "no_keys", reason: "No AI key is set up in API Keys." }, 503);

  const prompt = buildBoundaryPrompt(query);
  const ask = { systemInstruction: BOUNDARY_SYSTEM, temperature: 0, maxTokens: 4096 };

  let lastError: string | null = null;
  for (const k of keys) {
    const res = await callProvider(provider, prompt, k.key, model, ask);
    if (res.content == null) {
      lastError = res.error;
      continue;
    }
    const shape = normalizeAiBoundary(jsonObjectIn(res.content));
    if (shape) {
      await admin.from("admin_audit_log").insert({
        actor_id: uid,
        action: "region_boundary.ai",
        detail: { query, provider, points: shape.polygons.reduce((n, r) => n + r.length, 0) },
      });
      return json({ ok: true, boundary: shape, provider });
    }
    lastError = "no_polygon";
  }

  console.log(`[region-boundary-ai] no usable boundary for "${query}" via ${provider}: ${lastError ?? "unknown"}`);
  return json({ ok: false, error: "no_result", reason: "The AI didn't return a usable outline. Try a more specific name." }, 200);
});
