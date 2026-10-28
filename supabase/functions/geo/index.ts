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
// provider for the admin page, and limited per caller address. Calls from a
// tester account (Admin → Display Settings → Tester accounts, migration 0241)
// are counted apart, as test traffic, from the verified caller; they are
// limited and answered like any other. See
// _shared/geo_handler.ts for the requests and answers.
//
// Google keys left empty in Admin → API Keys fall back to the function's own
// secrets (GOOGLE_MAP_API_KEY, GOOGLE_PLACES_API_KEY, GOOGLE_GEOCODING_API_KEY,
// GOOGLE_DIRECTIONS_API_KEY), synced from GitHub by sync-map-keys.yml.
//
// The office NAS (migration 0319, _shared/geo_nas.ts) is the provider "nas":
// asked through its Cloudflare Tunnel with the secret header it gave when it
// checked in (nas_maps_link), waiting its own timeout (1.5 s by default), so
// the app moves on to the next provider quickly when the NAS is slow or off.
//
// Place search, reverse, routes, distances, details and address checks need a
// signed-in user (they spend the keys); tiles and links don't.
//
// The app POSTs its parameters as a JSON body to the bare function URL, so
// a browser asks the CORS preflight once and keeps it (Access-Control-Max-Age);
// a GET with a query string still works.
//
// Deploy (the gateway checks for the project's key or a session):
//   supabase functions deploy geo
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import countries from "npm:world-countries@5.1.0";

import { fallbackKey, googleMapType, tokenCacheKey } from "../_shared/geo.ts";
import {
  errorDetail,
  geoParams,
  googleSessionBody,
  handleGeo,
  parseGoogleSession,
  isMissingFunction,
  rateTakers,
  RefusedSessions,
} from "../_shared/geo_handler.ts";
import { type NasLink, parseNasLink } from "../_shared/geo_nas.ts";
import { clientIp } from "../_shared/pin_login.ts";
import { rpcTestAccountLookup, testAccountCheck } from "../_shared/test_traffic.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Max-Age": "7200",
};

const db = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});

// Work that goes on after the answer is sent (a count, an error kept, a
// settings refresh): kept alive by the runtime where it can, else left to
// finish alone. Never rejects.
function background(p: Promise<unknown>) {
  const settled = p.catch((e) => console.error("geo: background:", e instanceof Error ? e.message : "failed"));
  (globalThis as { EdgeRuntime?: { waitUntil?(p: Promise<unknown>): void } }).EdgeRuntime?.waitUntil?.(settled);
}

// The settings change rarely: read at most every 30 s per instance, and
// then in the background while the one held answers (PERF-73). Only a cold
// instance, or one that held them over a minute, waits for the read; an
// Admin change shows within 30-60 s.
let settingsAt = 0;
let settingsCache: { config: unknown; apiProviders: unknown } | null = null;
let settingsRead: Promise<{ config: unknown; apiProviders: unknown }> | null = null;

function readSettings() {
  // One read at a time, however many requests find them stale.
  settingsRead ??= (async () => {
    const { data, error } = await db.from("app_settings").select("key, value").in("key", ["map_config", "api_providers"]);
    if (error) throw error;
    const by = Object.fromEntries((data ?? []).map((r) => [r.key, r.value]));
    settingsCache = { config: by.map_config ?? null, apiProviders: by.api_providers ?? null };
    settingsAt = Date.now();
    return settingsCache;
  })().finally(() => {
    settingsRead = null;
  });
  return settingsRead;
}

async function settings() {
  const age = Date.now() - settingsAt;
  if (!settingsCache || age >= 60_000) return await readSettings();
  if (age >= 30_000) background(readSettings());
  return settingsCache;
}

// Google tile sessions refused in the last 10 minutes, per instance: profiles
// asked meanwhile fall back at once instead of waiting on Google to refuse again.
const refusedSessions = new RefusedSessions();

const iso3By = new Map(
  (countries as unknown as { cca2: string; cca3: string }[]).map((c) => [c.cca2.toLowerCase(), c.cca3]),
);

// Who a token belongs to, kept a minute per instance: a search asks often.
// Keyed by the token's hash, so the cache never holds a usable token.
const callers = new Map<string, { uid: string | null; at: number }>();

async function callerOf(authorization: string | null): Promise<string | null> {
  const token = /^Bearer\s+(\S+)$/i.exec(authorization ?? "")?.[1];
  if (!token) return null;
  const key = await tokenCacheKey(token);
  const known = callers.get(key);
  if (known && Date.now() - known.at < 60_000) return known.uid;
  const { data, error } = await db.auth.getUser(token);
  // Auth down is not remembered; a refused token (the anon key, an expired one) is, as nobody.
  if (error && (error.status ?? 500) >= 500) throw error;
  const uid = data?.user?.id ?? null;
  if (callers.size > 5000) callers.clear();
  callers.set(key, { uid, at: Date.now() });
  return uid;
}

// The two rate limits in one round trip (geo_take2, migration 0235), or two
// geo_take calls until that migration is run.
const limits = rateTakers((fn, args) => db.rpc(fn, args));

// Test traffic (0241): whether the caller is a listed tester, kept a minute
// per id. Only labels the usage count; a failure counts the call as real.
const isTestAccount = testAccountCheck(rpcTestAccountLookup((fn, args) => db.rpc(fn, args)));

async function isTestCaller(authorization: string | null): Promise<boolean> {
  try {
    return await isTestAccount(await callerOf(authorization));
  } catch {
    return false;
  }
}

// Counts one call through geo_usage_daily; a tester's apart (0241).
async function countCall(provider: string, kind: string, ok: boolean, cached: boolean, authorization: string | null) {
  if (await isTestCaller(authorization)) {
    await db.rpc("geo_count", { p_provider: provider, p_kind: kind, p_ok: ok, p_cached: cached, p_test: true });
  } else {
    await db.rpc("geo_count", { p_provider: provider, p_kind: kind, p_ok: ok, p_cached: cached });
  }
}

async function call(req: { url: string; method?: string; headers?: Record<string, string>; body?: string; timeoutMs?: number }) {
  const res = await fetch(req.url, {
    method: req.method ?? "GET",
    headers: { Accept: "application/json", "User-Agent": "GET.ride (getride.my)", ...(req.headers ?? {}) },
    body: req.body,
    signal: AbortSignal.timeout(req.timeoutMs ?? 8000),
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

// The office NAS (0319) where a point is, kept 30 s per ~1 km cell per
// instance: it checks in every minute, and a NAS gone quiet should stop being
// offered within a minute or so. Without the migration, there is no NAS.
const nasLinks = new Map<string, { at: number; link: NasLink | null }>();

async function nasLink(point: [number, number] | null): Promise<NasLink | null> {
  const cell = point ? `${point[0].toFixed(2)},${point[1].toFixed(2)}` : "-";
  const known = nasLinks.get(cell);
  if (known && Date.now() - known.at < 30_000) return known.link;
  const { data, error } = await db.rpc("nas_maps_link", { p_lat: point?.[0] ?? null, p_lng: point?.[1] ?? null });
  if (error && !isMissingFunction(error)) throw error;
  const link = error ? null : parseNasLink(data);
  if (nasLinks.size > 2000) nasLinks.clear();
  nasLinks.set(cell, { at: Date.now(), link });
  return link;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "GET" && req.method !== "POST") {
    return new Response("Method not allowed", { status: 405, headers: corsHeaders });
  }
  const params = await geoParams(req);
  if (!params) {
    return new Response(JSON.stringify({ error: "Give the parameters as a JSON object." }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
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
      // Both fail closed: a limit that can't be counted refuses.
      take: limits.take,
      takePair: limits.takePair,
      caller: () => callerOf(req.headers.get("Authorization")),
      // Not awaited by the handler: it finishes in the background.
      count: async (provider, kind, ok, cached, detail) => {
        await countCall(provider, kind, ok, cached, req.headers.get("Authorization"));
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
          background((async () => {
            await countCall("google", "tiles", false, false, req.headers.get("Authorization"));
            await logError("google", "tiles", `${slot} map: ${errorDetail(e)}`);
          })());
          throw e;
        }
        const s = parseGoogleSession(answer);
        if (!s) return null;
        await db.from("map_tile_sessions").upsert({
          kind,
          session: s.session,
          expires_at: new Date(s.expiresAt).toISOString(),
        });
        background((async () => {
          await countCall("google", "tiles", true, false, req.headers.get("Authorization"));
        })());
        return s.session;
      },
      nas: nasLink,
      nasCount: async (kind, ok, ms, timedOut) => {
        await db.rpc("nas_maps_count", { p_kind: kind, p_ok: ok, p_ms: Math.round(ms), p_timed_out: timedOut });
      },
      iso3: (cc) => iso3By.get(cc.toLowerCase()) ?? null,
      fallbackKey: (slot) => fallbackKey(slot, (name) => Deno.env.get(name)),
      refusedSessions,
      background,
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
