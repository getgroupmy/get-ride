// ============================================================================
// waze-server-health — Supabase Edge Function (migration 0411)
// ----------------------------------------------------------------------------
// A scheduled health ping of the GET.route Waze servers (containers on the
// office NAS behind a Cloudflare Tunnel) that Admin → Fare AI provider lists
// when fares come from Waze. The database calls this every minute
// (waze_server_health_tick, pg_cron) with the Vault push_webhook_secret in
// x-push-secret. For each enabled server it GETs {url}/health with the key:
// GET.route answers whether its latest Waze call worked, so the check spends
// no Waze call. Each result goes to waze_server_health_report, which tells the
// Fare AI admins when a server has been down for 5 minutes and when it is
// back (the SMS gateway alert, 0178, as the face server has it, 0347).
// Servers that were removed or switched off, or all of them when Waze is not
// in the fare order, are dropped quietly (waze_server_health_prune).
//
// The Google Maps servers (the Traffic Scraper, the fare order's "gmap" step)
// answer the same /health, so they are checked here too, in the same table.
//
// Deployed --no-verify-jwt: it authenticates itself with the webhook secret.
//
// Deploy: supabase functions deploy waze-server-health --no-verify-jwt
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { chainOf } from "../_shared/fare_chain.ts";
import {
  GMAP_KIND,
  healthVerdict,
  routeServersOf,
  type RouteServerKind,
  WAZE_HEALTH_TIMEOUT_MS,
  WAZE_KIND,
  type WazeServer,
} from "../_shared/waze_route.ts";

const db = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

async function check({ server, kind }: { server: WazeServer; kind: RouteServerKind }) {
  let status: number | null = null;
  let body: unknown = null;
  let failure: string | undefined;
  try {
    const res = await fetch(`${server.url}/health`, {
      headers: { "X-Route-Key": server.key, accept: "application/json" },
      signal: AbortSignal.timeout(WAZE_HEALTH_TIMEOUT_MS),
    });
    status = res.status;
    body = await res.json().catch(() => null);
  } catch (e) {
    failure = e instanceof Error && e.name === "TimeoutError"
      ? `Health check: no answer within ${WAZE_HEALTH_TIMEOUT_MS / 1000} s.`
      : "Health check: couldn't reach the server.";
  }
  const verdict = healthVerdict(status, body, failure, kind.sourceName);
  const { error } = await db.rpc("waze_server_health_report", {
    p_server_id: server.id,
    p_label: server.label,
    p_state: verdict.state,
    p_detail: verdict.detail,
  });
  if (error) console.log("[waze-server-health] report:", error.message);
  return { id: server.id, ...verdict };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  // Only the database webhook may run this (it carries the Vault secret).
  const secret = (req.headers.get("x-push-secret") ?? "").trim();
  const ok = secret ? (await db.rpc("push_webhook_secret_ok", { p_secret: secret })).data === true : false;
  if (!ok) return json({ error: "not_authorized" }, 403);

  try {
    const { data, error } = await db.from("app_settings").select("value").eq("key", "fare_ai_provider").maybeSingle();
    if (error) throw error;
    const config = (data?.value ?? {}) as Record<string, unknown>;
    // Each kind's servers, while its step is in the fare order.
    const chain = chainOf(config);
    const servers = [WAZE_KIND, GMAP_KIND]
      .filter((kind) => chain.includes(kind.provider))
      .flatMap((kind) => routeServersOf(config, kind).map((server) => ({ server, kind })));

    const { error: pruneErr } = await db.rpc("waze_server_health_prune", { p_keep: servers.map((s) => s.server.id) });
    if (pruneErr) console.log("[waze-server-health] prune:", pruneErr.message);
    if (servers.length === 0) return json({ servers: [] });

    // All at once: a slow server must not hold up the others' check.
    const results = await Promise.all(servers.map(check));
    return json({ servers: results });
  } catch (e) {
    console.log("[waze-server-health] error:", e instanceof Error ? e.message : String(e));
    return json({ error: "unavailable" }, 503);
  }
});
