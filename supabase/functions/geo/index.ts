// ============================================================================
// geo — Supabase Edge Function
// ----------------------------------------------------------------------------
// Admin → Settings → Maps (migration 0200): the map tiles a rider or partner
// gets on their kind of device, and place search, reverse geocoding and
// routing through the providers that need a key (Google, Mapbox, HERE,
// TomTom, LocationIQ, MapTiler). The keys stay here, read from Admin → API
// Keys; only tile keys go to the device, since a map has to send them.
// OpenStreetMap's Nominatim and OSRM are called by the device itself.
//
// Answers are cached (except Google's, whose terms forbid it), counted per
// provider for the admin page, and limited per caller address. See
// _shared/geo_handler.ts for the requests and answers.
//
// Deploy (the gateway checks for the project's key or a session):
//   supabase functions deploy geo
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import countries from "npm:world-countries@5.1.0";

import { googleSessionBody, handleGeo, parseGoogleSession } from "../_shared/geo_handler.ts";
import { clientIp } from "../_shared/pin_login.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};

const db = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});

// The settings change rarely: read at most every 30 s per instance.
let settingsAt = 0;
let settingsCache: { config: unknown; apiProviders: unknown } = { config: null, apiProviders: null };

async function settings() {
  if (Date.now() - settingsAt < 30_000) return settingsCache;
  const { data, error } = await db.from("app_settings").select("key, value").in("key", ["map_config", "api_providers"]);
  if (error) throw error;
  const by = Object.fromEntries((data ?? []).map((r) => [r.key, r.value]));
  settingsCache = { config: by.map_config ?? null, apiProviders: by.api_providers ?? null };
  settingsAt = Date.now();
  return settingsCache;
}

const iso3By = new Map(
  (countries as unknown as { cca2: string; cca3: string }[]).map((c) => [c.cca2.toLowerCase(), c.cca3]),
);

async function call(req: { url: string; method?: string; headers?: Record<string, string>; body?: string }) {
  const res = await fetch(req.url, {
    method: req.method ?? "GET",
    headers: { Accept: "application/json", "User-Agent": "GET.ride (getride.my)", ...(req.headers ?? {}) },
    body: req.body,
    signal: AbortSignal.timeout(8000),
  });
  // The URL carries the key: only the host is ever reported.
  if (!res.ok) throw new Error(`${res.status} from ${new URL(req.url).host}`);
  return await res.json();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "GET") return new Response("Method not allowed", { status: 405, headers: corsHeaders });
  try {
    const answer = await handleGeo(new URL(req.url).searchParams, clientIp(req.headers), {
      settings,
      call,
      take: async (bucket, limit) => {
        const { data, error } = await db.rpc("geo_take", { p_bucket: bucket, p_limit: limit });
        return error ? true : data === true;
      },
      count: async (provider, kind, ok, cached) => {
        await db.rpc("geo_count", { p_provider: provider, p_kind: kind, p_ok: ok, p_cached: cached });
      },
      cacheGet: async (key) => {
        const { data } = await db.from("geo_cache").select("value").eq("key", key)
          .gt("expires_at", new Date().toISOString()).maybeSingle();
        return data?.value ?? null;
      },
      cachePut: async (key, value, seconds) => {
        await db.from("geo_cache").upsert({
          key,
          value,
          expires_at: new Date(Date.now() + seconds * 1000).toISOString(),
        });
      },
      googleSession: async (slot, key, region) => {
        const kind = `google:${slot}:${region}`;
        const { data } = await db.from("map_tile_sessions").select("session, expires_at").eq("kind", kind)
          .maybeSingle();
        // Reused until a day before it expires (sessions last about two weeks).
        if (data && Date.parse(data.expires_at) - Date.now() > 86_400_000) return data.session;
        const s = parseGoogleSession(
          await call({
            url: `https://tile.googleapis.com/v1/createSession?key=${encodeURIComponent(key)}`,
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(googleSessionBody(slot, region)),
          }),
        );
        if (!s) return null;
        await db.from("map_tile_sessions").upsert({
          kind,
          session: s.session,
          expires_at: new Date(s.expiresAt).toISOString(),
        });
        await db.rpc("geo_count", { p_provider: "google", p_kind: "tiles", p_ok: true, p_cached: false });
        return s.session;
      },
      iso3: (cc) => iso3By.get(cc.toLowerCase()) ?? null,
    });
    return new Response(JSON.stringify(answer.body), {
      status: answer.status,
      headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
    });
  } catch (e) {
    console.error("geo:", e instanceof Error ? e.message : "failed");
    return new Response(JSON.stringify({ error: "unavailable" }), {
      status: 503,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
