// ============================================================================
// provider-health — Supabase Edge Function (migration 0440)
// ----------------------------------------------------------------------------
// A scheduled health ping of the self-hosted servers an admin switched on in
// Admin → API Keys ("Monitor this server"): GET.eKYC, Umami/NAS, a custom
// OSRM/Overpass server — each behind a Cloudflare Tunnel, reached on demand, so
// one going down is otherwise unnoticed until a check fails.
//
// The database calls this every minute (provider_health_tick, pg_cron) with the
// Vault push_webhook_secret in x-push-secret. It reads the monitored providers
// from api_providers, pings each server's /health, and reports 'ok' / 'down'
// to provider_health_report, which alerts the API-Keys admins when a server has
// been down for 5 minutes, again every 6 hours while it stays down, and once
// when it comes back. provider_health_prune forgets servers switched off.
//
// "down" is connectivity only: a timeout, a refused connection or a 5xx (a
// Cloudflare 530 when the tunnel drops). A server that answers — a 401 or a
// 404 included — is up; a wrong key is the Test button's job.
//
// Deployed --no-verify-jwt (verify_jwt false): it authenticates itself with the
// webhook secret, like send-push and face-server-health.
//
// Deploy: supabase functions deploy provider-health --no-verify-jwt
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { healthState, type MonitorTarget, monitorTargets, PROVIDER_HEALTH_TIMEOUT_MS } from "../_shared/provider_health.ts";

const db = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});

async function setting(key: string): Promise<unknown> {
  const { data, error } = await db.from("app_settings").select("value").eq("key", key).maybeSingle();
  if (error) throw error;
  return data?.value ?? null;
}

async function ping(t: MonitorTarget): Promise<{ state: "ok" | "down"; detail: string | null }> {
  try {
    const res = await fetch(`${t.url}/health`, {
      method: "GET",
      headers: t.apiKey ? { "x-api-key": t.apiKey } : {},
      redirect: "manual",
      signal: AbortSignal.timeout(PROVIDER_HEALTH_TIMEOUT_MS),
    });
    await res.body?.cancel();
    const state = healthState({ status: res.status });
    return { state, detail: state === "down" ? `Health check: HTTP ${res.status}.` : null };
  } catch (e) {
    return {
      state: "down",
      detail: e instanceof Error && e.name === "TimeoutError"
        ? "Health check: no answer within 10 s."
        : "Health check: couldn't reach the server.",
    };
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response(JSON.stringify({ error: "Method not allowed" }), { status: 405 });

  // Only the database webhook may run this (it carries the Vault secret).
  const secret = (req.headers.get("x-push-secret") ?? "").trim();
  const ok = secret
    ? (await db.rpc("push_webhook_secret_ok", { p_secret: secret })).data === true
    : false;
  if (!ok) return new Response(JSON.stringify({ error: "not_authorized" }), { status: 403 });

  try {
    const targets = monitorTargets(await setting("api_providers"));
    // Forget servers no longer monitored, so a switched-off one never alerts.
    await db.rpc("provider_health_prune", { p_keep: targets.map((t) => t.id) });

    const results: Record<string, string> = {};
    for (const t of targets) {
      const { state, detail } = await ping(t);
      results[t.id] = state;
      const { error } = await db.rpc("provider_health_report", {
        p_provider_id: t.id,
        p_label: t.label,
        p_state: state,
        p_detail: detail,
      });
      if (error) console.log("[provider-health] report", t.id, error.message);
    }
    return new Response(JSON.stringify({ checked: targets.length, results }), { status: 200 });
  } catch (e) {
    console.log("[provider-health] error:", e instanceof Error ? e.message : String(e));
    return new Response(JSON.stringify({ error: "unavailable" }), { status: 503 });
  }
});
