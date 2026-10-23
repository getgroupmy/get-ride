// ============================================================================
// ai-report — Supabase Edge Function
// ----------------------------------------------------------------------------
// Admin -> Reports (migration 0280): what the admin typed, turned into a
// report plan by the AI service set in API Keys (the provider, model and
// keys of Admin -> Fare AI, app setting fare_ai_provider, read here with the
// service role and never returned). The AI gets the request and the
// caller's dataset catalogue (ai_report_catalogue(), read with the caller's
// own token: a sub-admin's has no personal fields they may not see), never
// any data; its plan is checked against that catalogue and the page runs it
// with ai_report_run, which checks it again. See _shared/ai_report_ask.ts.
//
//   GET               -> { ai: { ready }, email: { ready, key_set, from, sender_ok } }
//   POST { request }  -> { ok: true, plan } | { ok: false, error, reason }
//
// Callers: admins who may run reports, at most 30 requests in 10 minutes
// each (auth_rate_take). Each request is logged in admin_audit_log
// ('ai_report.ask').
//
// Deploy (the token is checked here):
//   supabase functions deploy ai-report --no-verify-jwt
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { type AIServiceConfig } from "../_shared/ai_providers.ts";
import { ASK_WINDOW, ASKS_PER_WINDOW, handleAsk } from "../_shared/ai_report_ask.ts";
import { type Catalogue } from "../_shared/ai_report_plan.ts";
import { apiKeyFrom, EMAIL_PROVIDER, RESEND_SERVICE } from "../_shared/email.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Max-Age": "7200",
};

const url = Deno.env.get("SUPABASE_URL") ?? "";
const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const reply = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
    });
  try {
    const input = req.method === "POST" ? await req.json().catch(() => null) : null;
    const answer = await handleAsk(req.method, req.headers.get("Authorization"), input, {
      async catalogue(authorization) {
        const asCaller = createClient(url, anonKey, {
          global: { headers: { Authorization: authorization } },
          auth: { persistSession: false, autoRefreshToken: false },
        });
        const { data, error } = await asCaller.rpc("ai_report_catalogue");
        if (error) {
          if (error.code === "42501") return "forbidden";
          if (error.code === "PGRST301" || /jwt/i.test(error.message)) return null;
          throw new Error(error.message);
        }
        return data as Catalogue;
      },
      async userId(authorization) {
        const token = /^Bearer\s+(\S+)$/i.exec(authorization)?.[1];
        if (!token) return null;
        const { data } = await admin.auth.getUser(token);
        return data?.user?.id ?? null;
      },
      async rateTake(uid) {
        const { data, error } = await admin.rpc("auth_rate_take", {
          p_bucket: "ai_report",
          p_key: uid,
          p_limit: ASKS_PER_WINDOW,
          p_window: ASK_WINDOW,
        });
        return error || typeof data !== "number" ? null : data;
      },
      async aiConfig() {
        const { data, error } = await admin.from("app_settings").select("value").eq("key", "fare_ai_provider").maybeSingle();
        if (error) throw new Error("config_unavailable");
        return (data?.value ?? null) as AIServiceConfig | null;
      },
      async coolingKeys(ids) {
        const { data } = await admin.from("fare_ai_key_states").select("key_id, disabled_until").in("key_id", ids);
        const now = Date.now();
        return new Set(
          (data ?? [])
            .filter((r: { disabled_until: string | null }) => !!r.disabled_until && new Date(r.disabled_until).getTime() > now)
            .map((r: { key_id: string }) => r.key_id),
        );
      },
      async email() {
        const [{ data: keys }, { data: settings }] = await Promise.all([
          admin.from("app_settings").select("value").eq("key", "api_providers").maybeSingle(),
          admin.from("ai_report_settings").select("email_from").maybeSingle(),
        ]);
        const keySet = !!apiKeyFrom(keys?.value ?? null, EMAIL_PROVIDER, RESEND_SERVICE) ||
          !!Deno.env.get("RESEND_API_KEY")?.trim();
        return { keySet, from: settings?.email_from ?? null };
      },
      async audit(uid, detail) {
        await admin.from("admin_audit_log").insert({ actor_id: uid, action: "ai_report.ask", detail });
      },
      now: () => new Date(),
    });
    return reply(answer.body, answer.status);
  } catch (e) {
    console.error("ai-report:", e instanceof Error ? e.message : "failed");
    return reply({ ok: false, error: "unavailable", reason: "Reports are unavailable for a moment. Try again." }, 503);
  }
});
