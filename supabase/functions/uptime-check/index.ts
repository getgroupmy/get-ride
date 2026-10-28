// ============================================================================
// uptime-check — Supabase Edge Function
// ----------------------------------------------------------------------------
// The uptime monitor's cloud half (migration 0318). pg_cron runs
// uptime_cron every minute; when a round is due (Admin -> Settings -> Office
// NAS -> Uptime, "check from the cloud every …") it records what the
// database can tell by itself (gateway phones, the office NAS, last night's
// backup) and posts { action: "check" } here: this checks the web addresses
// and the database, records them (uptime_record), and sends the waiting
// alerts on Telegram and by email. { action: "flush" } only sends. So a dead
// NAS, or a dead office line, is still reported.
//
// GET ?ping=1 answers { ok: true }: the "Server functions" target.
//
// Callers: the database (x-push-secret, checked by push_webhook_secret_ok)
// or the service role. Telegram: the bot token in Admin -> API Keys ->
// Telegram -> Bot. Email: Resend (Admin -> API Keys -> Email -> Resend, or
// the function secret RESEND_API_KEY).
//
// Deploy: supabase functions deploy uptime-check --no-verify-jwt
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { apiKeyFrom, emailProvider } from "../_shared/email.ts";
import { handleUptime } from "../_shared/uptime.ts";

const projectUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const db = createClient(projectUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });

async function apiProviders(): Promise<unknown> {
  const { data } = await db.from("app_settings").select("value").eq("key", "api_providers").maybeSingle();
  return data?.value ?? null;
}

Deno.serve(async (req) => {
  try {
    return await handleUptime(req, {
      projectUrl,
      async callerOk(r) {
        const bearer = (r.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
        if (serviceKey && bearer === serviceKey) return true;
        const secret = r.headers.get("x-push-secret");
        if (!secret) return false;
        const { data, error } = await db.rpc("push_webhook_secret_ok", { p_secret: secret });
        if (error) console.log("[uptime-check] secret check:", error.message);
        return data === true;
      },
      async rpc(name, args) {
        const { data, error } = await db.rpc(name, args);
        if (error) throw error;
        return data;
      },
      async ping() {
        const { error } = await db.rpc("uptime_ping");
        if (error) throw error;
      },
      async telegramToken() {
        return apiKeyFrom(await apiProviders(), "telegram", "bot") ?? (Deno.env.get("TELEGRAM_BOT_TOKEN")?.trim() || null);
      },
      async email() {
        return emailProvider(await apiProviders(), (n) => Deno.env.get(n));
      },
    });
  } catch (e) {
    console.log("[uptime-check]", (e as Error)?.message ?? e);
    return new Response(JSON.stringify({ error: "unavailable" }), { status: 503, headers: { "Content-Type": "application/json" } });
  }
});
