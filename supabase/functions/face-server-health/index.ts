// ============================================================================
// face-server-health — Supabase Edge Function (migration 0347)
// ----------------------------------------------------------------------------
// A scheduled health ping of the self-hosted face match server (the NAS,
// deploy/face-server, behind a Cloudflare Tunnel). The database calls this
// every minute (face_server_health_tick, pg_cron) with the Vault
// push_webhook_secret in x-push-secret; it reads the face server key from
// Admin → API Keys, pings {url}/health, and reports 'ok' / 'down' / 'disabled'
// to face_server_health_report, which alerts the admins when it has been down
// for 5 minutes and when it comes back (the same idea as the SMS gateway
// alert, 0178).
//
// Deployed --no-verify-jwt (verify_jwt false): it authenticates itself with
// the webhook secret, like send-push.
//
// Deploy: supabase functions deploy face-server-health --no-verify-jwt
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { faceServerKey, FACE_SERVER_TIMEOUT_MS, healthRequest } from "../_shared/face_server.ts";

const db = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});

async function setting(key: string): Promise<unknown> {
  const { data, error } = await db.from("app_settings").select("value").eq("key", key).maybeSingle();
  if (error) throw error;
  return data?.value ?? null;
}

async function report(state: "ok" | "down" | "disabled", detail: string | null) {
  const { error } = await db.rpc("face_server_health_report", { p_state: state, p_detail: detail });
  if (error) console.log("[face-server-health] report:", error.message);
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
    const server = faceServerKey(await setting("api_providers"));
    if (!server) {
      await report("disabled", null);
      return new Response(JSON.stringify({ state: "disabled" }), { status: 200 });
    }

    const r = healthRequest(server);
    let state: "ok" | "down" = "down";
    let detail: string | null = null;
    try {
      const res = await fetch(r.url, {
        method: r.method,
        headers: r.headers,
        signal: AbortSignal.timeout(FACE_SERVER_TIMEOUT_MS),
      });
      if (res.ok) {
        const body = await res.json().catch(() => null);
        if ((body as { status?: unknown } | null)?.status === "ok") {
          state = "ok";
        } else {
          detail = "Health check: the server answered but not with status ok.";
        }
      } else {
        detail = res.status === 401 || res.status === 403
          ? "Health check: the key was refused."
          : `Health check: HTTP ${res.status}.`;
      }
    } catch (e) {
      detail = e instanceof Error && e.name === "TimeoutError"
        ? "Health check: no answer within 15 s."
        : "Health check: couldn't reach the server.";
    }

    await report(state, detail);
    return new Response(JSON.stringify({ state, detail }), { status: 200 });
  } catch (e) {
    console.log("[face-server-health] error:", e instanceof Error ? e.message : String(e));
    return new Response(JSON.stringify({ error: "unavailable" }), { status: 503 });
  }
});
