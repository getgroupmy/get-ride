// ============================================================================
// nas-stats — Supabase Edge Function
// ----------------------------------------------------------------------------
// Admin -> Settings -> Office NAS -> Visitor stats (migration 0321): today's
// visitors, page views, install page views, top page and top source, read
// from Umami on the office NAS (deploy/nas-stats, https://stats.getride.my
// through a Cloudflare Tunnel) with the key in Admin -> API Keys -> Umami.
// When the NAS is off the answer is { state: "nas_off" } and nothing else is
// affected. Admins with the Office NAS page only (read is enough).
// See _shared/nas_stats.ts.
//
//   POST {} -> { state: "on", today: {...}, at } | { state: "nas_off" | "not_set" | "refused" | "paused", reason?, at }
//
// Deploy: supabase functions deploy nas-stats
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { readStats } from "../_shared/nas_stats.ts";

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

const url = Deno.env.get("SUPABASE_URL") ?? "";
const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const db = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});

/** Asks the database, as the caller, whether they may read the Office NAS page. */
async function allowed(authorization: string | null): Promise<boolean | null> {
  if (!/^Bearer\s+\S+/i.test((authorization ?? "").trim())) return null;
  const res = await fetch(`${url}/rest/v1/rpc/testdb_stats_admin_ok`, {
    method: "POST",
    headers: { apikey: anonKey, Authorization: authorization!, "Content-Type": "application/json" },
    body: JSON.stringify({ p_edit: false }),
  });
  if (res.status === 401) {
    await res.body?.cancel();
    return null;
  }
  if (!res.ok) {
    await res.body?.cancel();
    return false;
  }
  return (await res.json()) === true;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);

  const ok = await allowed(req.headers.get("Authorization")).catch(() => false);
  if (ok === null) return reply({ error: "not_signed_in" }, 401);
  if (!ok) return reply({ error: "admin_only" }, 403);

  try {
    return reply(await readStats({
      async settings() {
        const { data, error } = await db.from("app_settings").select("key, value").in("key", ["nas_stats", "api_providers"]);
        if (error) throw error;
        const by = Object.fromEntries((data ?? []).map((r) => [r.key, r.value]));
        return { stats: by.nas_stats ?? null, apiProviders: by.api_providers ?? null };
      },
      fetch: (u, init) => fetch(u, init),
      now: () => new Date(),
      async beat(status, detail) {
        const { error } = await db.from("nas_services").upsert({
          service: "stats",
          last_seen: status === "ok" ? new Date().toISOString() : undefined,
          status,
          detail,
        }, { onConflict: "service" });
        if (error) console.log("[nas-stats] beat:", error.message);
      },
    }));
  } catch (e) {
    console.log("[nas-stats]", (e as Error)?.message ?? e);
    return reply({ error: "unavailable" }, 503);
  }
});
