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
// answer the same /health, so they are checked here too, in the same table,
// and so are the Apple Maps servers (GET.route Apple Maps, the "apple" step).
//
// With the Waze / Google Maps balance on "auto" (fare_ai_provider.liveBalance,
// _shared/live_balance.ts), it also sets the share of fares asking Google
// Maps first (fare_live_balance, 0414) from the last 15 minutes of
// fare_ai_responses and this run's health results. With Apple Maps' share on
// "auto" (liveBalance.apple) it sets that share too (apple_first_pct, 0416),
// against Waze, and keeps it low while Apple Maps refuses for its quota.
//
// Deployed --no-verify-jwt: it authenticates itself with the webhook secret.
//
// Deploy: supabase functions deploy waze-server-health --no-verify-jwt
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { chainOf } from "../_shared/fare_chain.ts";
import {
  appleBalanceApplies,
  appleBalanceOf,
  balanceApplies,
  balanceOf,
  median,
  nextAppleShare,
  nextAutoShare,
  type StepStats,
} from "../_shared/live_balance.ts";
import {
  APPLE_KIND,
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

interface Row {
  provider: string;
  success: boolean;
  latency_ms: number | null;
  http_status: number | null;
  is_test?: boolean | null;
}

/** The last 15 minutes of real (non-test) Waze, Google Maps and Apple Maps
 * lookups, read once for both automatic shares. */
async function recentRows(): Promise<Row[]> {
  const since = new Date(Date.now() - 15 * 60_000).toISOString();
  const { data: rows, error } = await db
    .from("fare_ai_responses")
    .select("provider, success, latency_ms, http_status, is_test")
    .in("provider", ["waze", "gmap", "apple"])
    .gte("created_at", since)
    .limit(5000);
  if (error) throw error;
  return ((rows ?? []) as Row[]).filter((r) => !r.is_test);
}

function statsOf(rows: Row[], health: { provider: string; state: string }[], provider: string): StepStats {
  const mine = rows.filter((r) => r.provider === provider);
  const kinds = health.filter((h) => h.provider === provider);
  return {
    attempts: mine.length,
    successes: mine.filter((r) => r.success).length,
    medianMs: median(mine.map((r) => Number(r.latency_ms))),
    offline: kinds.length > 0 && kinds.every((h) => h.state === "down"),
  };
}

/** The automatic Waze / Google Maps share: the last 15 minutes and this
 * run's health, through nextAutoShare, stored with its reason
 * (fare_live_balance_set, 0414). */
async function updateAutoBalance(config: Record<string, unknown>, rows: Row[], health: { provider: string; state: string }[]) {
  const { data: current } = await db.from("fare_live_balance").select("gmap_first_pct").maybeSingle();
  const decision = nextAutoShare(
    Number(current?.gmap_first_pct ?? 0),
    statsOf(rows, health, "waze"),
    statsOf(rows, health, "gmap"),
    balanceOf(config),
  );
  const { error: setErr } = await db.rpc("fare_live_balance_set", { p_pct: decision.pct, p_reason: decision.reason });
  if (setErr) throw setErr;
  return decision;
}

/** The automatic Apple Maps share, against Waze (nextAppleShare), stored
 * with its reason (fare_live_balance_set_apple, 0416). */
async function updateAppleBalance(config: Record<string, unknown>, rows: Row[], health: { provider: string; state: string }[]) {
  const { data: current } = await db.from("fare_live_balance").select("*").maybeSingle();
  const apple = {
    ...statsOf(rows, health, "apple"),
    quotaRefusals: rows.filter((r) => r.provider === "apple" && (r.http_status === 503 || r.http_status === 429)).length,
  };
  const decision = nextAppleShare(
    Number((current as Record<string, unknown> | null)?.apple_first_pct ?? 0),
    statsOf(rows, health, "waze"),
    apple,
    appleBalanceOf(config),
  );
  const { error: setErr } = await db.rpc("fare_live_balance_set_apple", { p_pct: decision.pct, p_reason: decision.reason });
  if (setErr) throw setErr;
  return decision;
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
    const servers = [WAZE_KIND, GMAP_KIND, APPLE_KIND]
      .filter((kind) => chain.includes(kind.provider))
      .flatMap((kind) => routeServersOf(config, kind).map((server) => ({ server, kind })));

    const { error: pruneErr } = await db.rpc("waze_server_health_prune", { p_keep: servers.map((s) => s.server.id) });
    if (pruneErr) console.log("[waze-server-health] prune:", pruneErr.message);
    if (servers.length === 0) return json({ servers: [] });

    // All at once: a slow server must not hold up the others' check.
    const results = await Promise.all(servers.map(check));

    let balance: unknown = null;
    let appleBalance: unknown = null;
    const gmapAuto = balanceApplies(chain) && balanceOf(config).mode === "auto";
    const appleAuto = appleBalanceApplies(chain) && appleBalanceOf(config).mode === "auto";
    if (gmapAuto || appleAuto) {
      const health = servers.map((s, i) => ({ provider: s.kind.provider, state: results[i].state }));
      const log = (what: string) => (e: unknown) => {
        console.log(`[waze-server-health] ${what}:`, e instanceof Error ? e.message : String(e));
        return null;
      };
      const rows = await recentRows().catch(log("recent lookups"));
      if (rows) {
        if (gmapAuto) balance = await updateAutoBalance(config, rows, health).catch(log("balance"));
        if (appleAuto) appleBalance = await updateAppleBalance(config, rows, health).catch(log("apple balance"));
      }
    }
    return json({ servers: results, balance, appleBalance });
  } catch (e) {
    console.log("[waze-server-health] error:", e instanceof Error ? e.message : String(e));
    return json({ error: "unavailable" }, 503);
  }
});
