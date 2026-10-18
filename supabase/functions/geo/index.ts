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
// Google keys left empty in Admin → API Keys fall back to the function's own
// secrets (GOOGLE_MAP_API_KEY, GOOGLE_PLACES_API_KEY, GOOGLE_GEOCODING_API_KEY,
// GOOGLE_DIRECTIONS_API_KEY), synced from GitHub by sync-map-keys.yml.
//
// Place search, reverse, routes, distances, details and address checks need a
// signed-in user (they spend the keys); tiles and links don't.
//
// Deploy (the gateway checks for the project's key or a session):
//   supabase functions deploy geo
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import countries from "npm:world-countries@5.1.0";

import { fallbackKey, googleMapType } from "../_shared/geo.ts";
import { errorDetail, googleSessionBody, handleGeo, parseGoogleSession } from "../_shared/geo_handler.ts";
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

// Who a token belongs to, kept a minute per instance: a search asks often.
const callers = new Map<string, { uid: string | null; at: number }>();

async function callerOf(authorization: string | null): Promise<string | null> {
  const token = /^Bearer\s+(\S+)$/i.exec(authorization ?? "")?.[1];
  if (!token) return null;
  const known = callers.get(token);
  if (known && Date.now() - known.at < 60_000) return known.uid;
  const { data, error } = await db.auth.getUser(token);
  // Auth down is not remembered; a refused token (the anon key, an expired one) is, as nobody.
  if (error && (error.status ?? 500) >= 500) throw error;
  const uid = data?.user?.id ?? null;
  if (callers.size > 5000) callers.clear();
  callers.set(token, { uid, at: Date.now() });
  return uid;
}

async function call(req: { url: string; method?: string; headers?: Record<string, string>; body?: string }) {
  const res = await fetch(req.url, {
    method: req.method ?? "GET",
    headers: { Accept: "application/json", "User-Agent": "GET.ride (getride.my)", ...(req.headers ?? {}) },
    body: req.body,
    signal: AbortSignal.timeout(8000),
  });
  // The URL carries the key: only the host and Google's reason codes are ever reported.
  if (!res.ok) {
    const err = (await res.json().catch(() => null))?.error;
    const reasons = [err?.status, ...(err?.details ?? []).map((d: { reason?: string }) => d?.reason)]
      .filter((r): r is string => typeof r === "string" && /^[A-Z_]+$/.test(r));
    throw new Error(`${res.status} from ${new URL(req.url).host}${reasons.length ? ` (${reasons.join(", ")})` : ""}`);
  }
  return await res.json();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "GET") return new Response("Method not allowed", { status: 405, headers: corsHeaders });
  const params = new URL(req.url).searchParams;
  // A failed call, kept for Admin → Maps → Usage (the last 30 days).
  const logError = async (provider: string, kind: string, detail: string) => {
    await db.rpc("geo_log_error", {
      p_provider: provider,
      p_kind: kind,
      p_role: params.get("role"),
      p_device: params.get("device"),
      p_detail: detail,
    });
  };
  try {
    const answer = await handleGeo(params, clientIp(req.headers), {
      settings,
      call,
      take: async (bucket, limit) => {
        const { data, error } = await db.rpc("geo_take", { p_bucket: bucket, p_limit: limit });
        // Fails closed: a limit that can't be counted refuses.
        return !error && data === true;
      },
      caller: () => callerOf(req.headers.get("Authorization")),
      count: async (provider, kind, ok, cached, detail) => {
        await db.rpc("geo_count", { p_provider: provider, p_kind: kind, p_ok: ok, p_cached: cached });
        if (!ok && detail) await logError(provider, kind, detail).catch(() => {});
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
      googleSession: async (slot, key, region, look) => {
        // One session per look: "google:satellite:my", "google:satellite-hybrid:my" …
        const type = googleMapType(slot, look);
        const variant = type === "hybrid" || type === "terrain" ? `-${type}` : "";
        const kind = `google:${slot}${variant}:${region}`;
        const { data } = await db.from("map_tile_sessions").select("session, expires_at").eq("kind", kind)
          .maybeSingle();
        // Reused until a day before it expires (sessions last about two weeks).
        if (data && Date.parse(data.expires_at) - Date.now() > 86_400_000) return data.session;
        let answer: unknown;
        try {
          answer = await call({
            url: `https://tile.googleapis.com/v1/createSession?key=${encodeURIComponent(key)}`,
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(googleSessionBody(slot, region, "en-US", look)),
          });
        } catch (e) {
          // Google refused (API off, key restricted, billing): say why in the function's logs.
          console.error(`geo: Google ${slot} tile session refused:`, e instanceof Error ? e.message : "failed");
          await db.rpc("geo_count", { p_provider: "google", p_kind: "tiles", p_ok: false, p_cached: false });
          await logError("google", "tiles", `${slot} map: ${errorDetail(e)}`).catch(() => {});
          throw e;
        }
        const s = parseGoogleSession(answer);
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
      fallbackKey: (slot) => fallbackKey(slot, (name) => Deno.env.get(name)),
      redirect: async (url) => {
        const res = await fetch(url, {
          redirect: "manual",
          headers: { "User-Agent": "GET.ride (getride.my)" },
          signal: AbortSignal.timeout(8000),
        });
        await res.body?.cancel();
        return res.status >= 300 && res.status < 400 ? res.headers.get("location") : null;
      },
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
