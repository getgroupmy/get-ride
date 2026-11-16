// ============================================================================
// ai-route-proxy — Supabase Edge Function
// ----------------------------------------------------------------------------
// Server-side fare-AI route estimation. Mirrors the provider/key failover
// loop that used to run in the client (expo/utils/geminiRoute.ts), but reads
// the fare-AI configuration — including the SECRET provider API keys — with
// the service-role key. Since migration 0066 the `app_settings` row holding
// that configuration (key = 'fare_ai_provider') is no longer readable by
// anonymous clients, so this function is the only way riders get AI route
// estimates.
//
// Request body:
//   { "origin": { "latitude": n, "longitude": n },
//     "destination": { "latitude": n, "longitude": n },
//     "waypoints"?: [{ "latitude": n, "longitude": n }, ...] }   // stops, in order (≤ 5)
//
// Response:
//   { "ok": true, "estimate": RouteEstimate | null }
//   estimate = { distance_km, duration_min, summary?, provider,
//                toll_count?, toll_total?, tolls?, stops } — null when the service
//   is disabled, no keys are configured/available, or every key failed
//   (callers fall back to a routing engine, same contract as before).
//   `stops` is how many waypoints the estimate covers: a client sending
//   stops accepts the estimate only when it covers all of them, so a proxy
//   from before stops (which priced pickup → drop-off) is never mistaken
//   for one that priced the whole trip.
//
// Every attempt is logged to `fare_ai_responses` and per-key counters /
// cooldowns are updated via the `fare_ai_record_usage` RPC — identical to
// what the client used to record. A row for a tester account (Admin →
// Display Settings → Tester accounts, migration 0241) is marked is_test, from
// the verified caller id, so the admin's figures can leave it out. Only the
// label differs: the limit, the keys and the answer are the same.
//
// What the AI is asked comes from the config's `request` (Admin → Fare AI →
// Request & format; see _shared/fare_ai_request.ts); with none saved it is
// the original prompt, word for word.
//
// Test mode (admins only): { "test": true, origin, destination,
// "request"?: <draft request> } runs the draft against the first usable key
// and returns the prompt, the raw reply and the parsed estimate. Nothing is
// logged and no key counter or cooldown is touched.
//
// Callers: signed-in users only (the token is checked here, since the
// gateway's JWT check is off), at most ROUTE_ESTIMATES_PER_WINDOW estimates
// per ROUTE_ESTIMATE_WINDOW each (auth_rate_take). The test path is for
// admins only on top of that.
//
// Deploy:
//   supabase functions deploy ai-route-proxy --no-verify-jwt
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { callerCanEdit, FARE_AI_PAGES } from "../_shared/admin_page.ts";
import { rpcTestAccountLookup, testAccountCheck } from "../_shared/test_traffic.ts";
import {
  type CallResult,
  callProvider,
  DEFAULT_MODELS,
  type FareAIKey,
  type Provider,
} from "../_shared/ai_providers.ts";

import {
  buildPrompt,
  decideFareTrend,
  implausibleDistance,
  type FareAIRequest,
  type FareTrend,
  parseStops,
  parseTrafficExtras,
  resolveRequest,
  resolveTrendSettings,
  retryPolicyMs,
  templateProblem,
  type TrafficExtras,
} from "../_shared/fare_ai_request.ts";
import {
  anyArea,
  areaOf,
  askWazeServer,
  cleanServerUrl,
  APPLE_KIND,
  APPLE_PROVIDER,
  GMAP_KIND,
  GMAP_PROVIDER,
  restMs,
  type LatLng as WazeLatLng,
  orderServersFor,
  placeFromRegions,
  type RegionRow,
  routeServersOf,
  type RouteServerKind,
  WAZE_KIND,
  WAZE_PROVIDER,
  type WazeServer,
} from "../_shared/waze_route.ts";
import { chainOf, OSRM_PROVIDER, osrmEstimate } from "../_shared/fare_chain.ts";
import {
  appleBalanceApplies,
  appleBalanceOf,
  balanceApplies,
  balanceOf,
  type LiveFirst,
  liveFirstOf,
  orderForFirst,
  pickLiveFirst,
} from "../_shared/live_balance.ts";
import { nasRouteRequest, parseNasLink } from "../_shared/geo_nas.ts";
import {
  appTimingOf,
  deviceChain,
  deviceReportOf,
  fetchWithin,
  resumeSteps,
  type ServerTiming,
  serverTimingOf,
} from "../_shared/fare_timing.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "7200",
};

interface FareAIConfig {
  serviceEnabled?: boolean;
  provider?: Provider;
  retryAfterValue?: number;
  retryAfterUnit?: "minute" | "hour" | "day" | "month";
  models?: Partial<Record<Provider, string>>;
  keys?: Partial<Record<Provider, FareAIKey[]>>;
  request?: FareAIRequest;
  /** Fare trend arrows: { upPct, downPct } (see _shared/fare_ai_request.ts). */
  trend?: unknown;
  /** Where estimates come from: "waze" | "ai" | "none" (_shared/waze_route.ts). */
  source?: unknown;
  /** GET.route servers, tried in order when the source is "waze". */
  wazeServers?: unknown;
  /** Google Maps servers (the Traffic Scraper), for the "gmap" step. */
  gmapServers?: unknown;
  /** Apple Maps servers (GET.route Apple Maps), for the "apple" step. */
  appleServers?: unknown;
  /** When every Waze server fails: "ai" (default) or "none" (before chains). */
  wazeFallback?: unknown;
  /** The order estimates are asked in: "waze" | "gmap" | "apple" | "ai" | "osrm" (_shared/fare_chain.ts). */
  chain?: unknown;
  /** Waze / Google Maps balance: which of the two goes first (_shared/live_balance.ts). */
  liveBalance?: unknown;
  /** Time limits per step, in seconds (_shared/fare_timing.ts). */
  timing?: unknown;
}

interface LatLng {
  latitude: number;
  longitude: number;
}

interface TollBooth {
  id?: string;
  name?: string;
  charge: number;
  latitude?: number;
  longitude?: number;
}

interface RouteEstimate extends TrafficExtras {
  distance_km: number;
  duration_min: number;
  summary?: string;
  provider?: Provider | typeof WAZE_PROVIDER | typeof GMAP_PROVIDER | typeof APPLE_PROVIDER | typeof OSRM_PROVIDER | "apple_device";
  toll_count?: number;
  toll_total?: number;
  tolls?: TollBooth[];
  /** The arrows before the recommended fare; absent when undecided. */
  trend?: FareTrend;
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function parseEstimate(content: string): RouteEstimate | null {
  const cleaned = content.replace(/```json/gi, "").replace(/```/g, "").trim();
  const match = cleaned.match(/\{[\s\S]*\}/);
  if (!match) return null;
  try {
    const obj = JSON.parse(match[0]) as {
      distance_km?: number | string;
      duration_min?: number | string;
      summary?: string;
      toll_count?: number | string;
      toll_total?: number | string;
      tolls?: { name?: string; charge?: number | string; lat?: number | string; lng?: number | string }[];
    };

    const distanceKm = Number(obj.distance_km);
    const durationMin = Number(obj.duration_min);
    if (!Number.isFinite(distanceKm) || !Number.isFinite(durationMin)) return null;
    if (distanceKm <= 0 || durationMin <= 0) return null;

    const tolls: TollBooth[] = Array.isArray(obj.tolls)
      ? obj.tolls
        .map((t, i) => {
          const lat = Number(t.lat);
          const lng = Number(t.lng);
          const hasCoords = Number.isFinite(lat) && Number.isFinite(lng) && lat !== 0 && lng !== 0;
          return {
            id: `toll-${i}`,
            name: typeof t.name === "string" ? t.name : undefined,
            charge: Number(t.charge),
            latitude: hasCoords ? lat : undefined,
            longitude: hasCoords ? lng : undefined,
          };
        })
        .filter((t) => Number.isFinite(t.charge) && t.charge >= 0)
      : [];

    const parsedTollCount = Number(obj.toll_count);
    const tollCount = Number.isFinite(parsedTollCount)
      ? Math.max(0, Math.round(parsedTollCount))
      : tolls.length;

    const parsedTollTotal = Number(obj.toll_total);
    const tollTotal = Number.isFinite(parsedTollTotal)
      ? parseFloat(Math.max(0, parsedTollTotal).toFixed(2))
      : parseFloat(tolls.reduce((sum, t) => sum + t.charge, 0).toFixed(2));

    return {
      // Fare range and traffic, when asked for and sensible.
      ...parseTrafficExtras(obj as Record<string, unknown>),
      distance_km: parseFloat(distanceKm.toFixed(1)),
      duration_min: Math.ceil(durationMin),
      summary: typeof obj.summary === "string" ? obj.summary : undefined,
      toll_count: tollCount,
      toll_total: tollTotal,
      tolls,
    };
  } catch {
    return null;
  }
}

/** The standard route (OSRM, empty roads) the AI's time is compared with:
 * minutes and kilometres, or null when it can't be had in time. */
async function standardRoute(
  origin: LatLng,
  destination: LatLng,
  stops: LatLng[] = [],
): Promise<{ min: number; km: number } | null> {
  const base = Deno.env.get("OSRM_URL") ?? "https://router.project-osrm.org";
  const points = [origin, ...stops, destination].map((p) => `${p.longitude},${p.latitude}`).join(";");
  const url = `${base}/route/v1/driving/${points}?overview=false`;
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(8000) });
    if (!res.ok) return null;
    const data = await res.json();
    const r = data?.routes?.[0];
    const sec = Number(r?.duration), m = Number(r?.distance);
    if (!Number.isFinite(sec) || sec <= 0 || !Number.isFinite(m) || m <= 0) return null;
    return { min: Math.round((sec / 60) * 10) / 10, km: Math.round((m / 1000) * 10) / 10 };
  } catch {
    return null;
  }
}

// Per signed-in caller: a booking screen asks a handful of times while the
// rider edits the route; this many in the window is a script, not a rider.
const ROUTE_ESTIMATES_PER_WINDOW = 30;
const ROUTE_ESTIMATE_WINDOW = "10 minutes";

function isValidCoord(v: unknown): v is LatLng {
  const c = v as LatLng | null;
  return (
    !!c &&
    typeof c.latitude === "number" &&
    typeof c.longitude === "number" &&
    Number.isFinite(c.latitude) &&
    Number.isFinite(c.longitude) &&
    Math.abs(c.latitude) <= 90 &&
    Math.abs(c.longitude) <= 180
  );
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ ok: false, error: "POST only" }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) {
    return json({ ok: false, error: "Function is missing Supabase credentials" }, 500);
  }
  const admin = createClient(supabaseUrl, serviceKey);

  // Signed-in callers only, each held to a few estimates a minute: the
  // function spends the operator's AI provider keys. Both apps fall back
  // to their standard estimate when it refuses.
  const token = /^Bearer\s+(\S+)$/i.exec(req.headers.get("Authorization") ?? "")?.[1] ?? null;
  const { data: who } = token ? await admin.auth.getUser(token) : { data: { user: null } };
  const userId = who?.user?.id;
  if (!userId) {
    return json({ ok: false, error: "sign_in_required" }, 401);
  }
  let body: {
    origin?: unknown;
    destination?: unknown;
    waypoints?: unknown;
    test?: unknown;
    request?: unknown;
    server?: unknown;
    /** "ios_mapkit": an iPhone that asks Apple Maps itself (_shared/fare_timing.ts). */
    device?: unknown;
    /** The steps to go on with after Apple Maps on the phone missed. */
    resume?: unknown;
    /** The phone's Apple Maps answer, for the response log. */
    report?: unknown;
  };
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "Invalid JSON body" }, 400);
  }
  const { data: wait, error: rateErr } = await admin.rpc("auth_rate_take", {
    // A phone's report and its "go on after Apple Maps" have their own
    // buckets, so an iPhone fare doesn't spend two or three estimates.
    p_bucket: body.report ? "ai_route_report" : Array.isArray(body.resume) ? "ai_route_resume" : "ai_route",
    p_key: userId,
    p_limit: ROUTE_ESTIMATES_PER_WINDOW,
    p_window: ROUTE_ESTIMATE_WINDOW,
  });
  // Fails closed: when the limit can't be checked, no key is spent.
  if (rateErr || typeof wait !== "number") {
    console.error("ai-route-proxy: rate limit check failed", rateErr?.message ?? "no answer");
    return json({ ok: false, error: "unavailable" }, 503);
  }
  if (wait > 0) {
    return json({ ok: false, error: "rate_limited", retry_after: wait }, 429);
  }


  if (!isValidCoord(body.origin) || !isValidCoord(body.destination)) {
    return json({ ok: false, error: "origin/destination must be { latitude, longitude }" }, 400);
  }
  const origin = body.origin;
  const destination = body.destination;
  const stops = parseStops(body.waypoints);
  if (stops === null) {
    return json({ ok: false, error: "waypoints must be up to 5 { latitude, longitude }" }, 400);
  }


  const { data: settingsRow, error: settingsErr } = await admin
    .from("app_settings")
    .select("value")
    .eq("key", "fare_ai_provider")
    .maybeSingle();
  if (settingsErr) {
    console.error("ai-route-proxy: config read failed", settingsErr.message);
    return json({ ok: false, error: "config_unavailable" }, 500);
  }

  const config = (settingsRow?.value ?? {}) as FareAIConfig;
  if (body.test === "waze" || body.test === "gmap" || body.test === "apple") {
    const kind = body.test === "gmap" ? GMAP_KIND : body.test === "apple" ? APPLE_KIND : WAZE_KIND;
    return runWazeTest(req, supabaseUrl, body.server, config, origin, destination, stops, kind);
  }
  if (body.test === true) {
    const provider: Provider = config.provider ?? "gemini";
    const model = config.models?.[provider] ?? DEFAULT_MODELS[provider];
    return runTest(req, supabaseUrl, body.request, config, provider, model, aiKeysOf(config, provider), origin, destination, stops);
  }

  if (body.report) {
    return logDeviceReport(admin, userId, origin, destination, stops, body.report);
  }

  // The admin's order (Waze → Google Maps → AI → OSRM and the like): the first step with an
  // estimate answers. No step at all: the apps use their own fallback.
  let chain = chainOf(config as Record<string, unknown>);
  if (chain.length === 0) {
    return json({ ok: true, estimate: null, reason: "service_disabled" });
  }
  // An iPhone that asks Apple Maps itself (fare_timing.deviceApple): Apple
  // Maps' place in the order is handed to the phone.
  const onDevice = body.device === "ios_mapkit" && await deviceAppleOn(admin);
  if (onDevice) chain = deviceChain(chain);
  const resuming = Array.isArray(body.resume);
  if (resuming) chain = resumeSteps(chain, body.resume);
  // Waze / Google Maps / Apple Maps balance: a share of fares asks Google
  // Maps first, another share Apple Maps, the rest Waze (_shared/live_balance.ts).
  let liveFirst: LiveFirst | undefined;
  const gmapOn = !resuming && balanceApplies(chain), appleOn = !resuming && appleBalanceApplies(chain);
  if (gmapOn || appleOn) {
    const shares = await liveShares(admin, config, gmapOn, appleOn);
    chain = orderForFirst(chain, pickLiveFirst(shares.gmap, shares.apple, Math.random()));
    liveFirst = liveFirstOf(chain);
  }
  const ctx: StepContext = {
    admin,
    config,
    userId,
    origin,
    destination,
    stops,
    cooldownMs: retryPolicyMs(config.retryAfterValue ?? 1, config.retryAfterUnit ?? "hour"),
    // The empty-road route: what Waze's and the AI's times are compared with,
    // and the OSRM step's answer when the office NAS is off. Asked once.
    standardFuture: standardRoute(origin, destination, stops),
    // Test traffic (0241): a label for the log only. Any failure answers "real".
    testFuture: testAccountCheck(rpcTestAccountLookup((fn, args) => admin.rpc(fn, args)))(userId),
    liveFirst,
    timing: serverTimingOf(config as Record<string, unknown>),
  };
  let reason = "no_estimate";
  for (const [i, step] of chain.entries()) {
    if (step === "apple" && onDevice) {
      // The phone asks Apple Maps now; it comes back with these if it misses.
      return json({ ok: true, estimate: null, reason: "device_apple", remaining: chain.slice(i + 1) });
    }
    const r = step === "waze"
      ? await estimateFromRouteServers(ctx, WAZE_KIND)
      : step === "gmap"
      ? await estimateFromRouteServers(ctx, GMAP_KIND)
      : step === "apple"
      ? await estimateFromRouteServers(ctx, APPLE_KIND)
      : step === "ai"
      ? await estimateFromAi(ctx)
      : await estimateFromOsrm(ctx);
    if (r.estimate) return json({ ok: true, estimate: r.estimate });
    reason = r.reason;
  }
  return json({ ok: true, estimate: null, reason });
});

interface StepContext {
  // deno-lint-ignore no-explicit-any
  admin: any;
  config: FareAIConfig;
  userId: string;
  origin: LatLng;
  destination: LatLng;
  stops: LatLng[];
  cooldownMs: number;
  standardFuture: Promise<{ min: number; km: number } | null>;
  testFuture: Promise<boolean>;
  /** Which live-traffic step went first for this fare (balance), for the log. */
  liveFirst?: LiveFirst;
  /** The time limits per step (Admin › Fare AI › Time limits). */
  timing: ServerTiming;
}

/** Whether iPhones ask Apple Maps themselves (`fare_timing.deviceApple`,
 * on unless an admin turned it off). An unreadable setting: on. */
// deno-lint-ignore no-explicit-any
async function deviceAppleOn(admin: any): Promise<boolean> {
  const { data, error } = await admin.from("app_settings").select("value").eq("key", "fare_timing").maybeSingle();
  if (error) return true;
  return appTimingOf(data?.value).deviceApple;
}

/** Logs a phone's Apple Maps (MapKit) answer in the response log, as
 * "apple_device" (it touched no server and no key). */
async function logDeviceReport(
  // deno-lint-ignore no-explicit-any
  admin: any,
  userId: string,
  origin: LatLng,
  destination: LatLng,
  stops: LatLng[],
  raw: unknown,
): Promise<Response> {
  const r = deviceReportOf(raw);
  if (!r) return json({ ok: false, error: "report must be { success, distance_km, duration_min, latency_ms }" }, 400);
  const test = await testAccountCheck(rpcTestAccountLookup((fn, args) => admin.rpc(fn, args)))(userId);
  const standard = r.success ? await standardRoute(origin, destination, stops) : null;
  const { error } = await admin.from("fare_ai_responses").insert({
    provider: "apple_device",
    key_id: null,
    key_label: "iPhone (Apple Maps on the phone)",
    model: "MapKit",
    origin_lat: origin.latitude,
    origin_lng: origin.longitude,
    dest_lat: destination.latitude,
    dest_lng: destination.longitude,
    success: r.success,
    distance_km: r.distance_km,
    duration_min: r.duration_min,
    summary: r.success ? "Apple Maps on the iPhone" : null,
    error: r.error,
    latency_ms: r.latency_ms,
    extra: withStops(null, stops),
    standard_duration_min: standard?.min ?? null,
    standard_distance_km: standard?.km ?? null,
    ...(test ? { is_test: true } : {}),
  });
  if (error) console.error("ai-route-proxy: device report", error.message);
  return json({ ok: true });
}

/** The shares of fares (percent) that ask Google Maps, and Apple Maps,
 * first: the admin's fixed numbers, or in automatic mode the shares
 * waze-server-health last set (fare_live_balance, 0414 / 0416), kept inside
 * the admin's ranges. An unreadable automatic share falls back to the bottom
 * of its range. The row is read once, as `*`, so a database without 0416's
 * Apple column still gives the Google Maps share. */
async function liveShares(
  // deno-lint-ignore no-explicit-any
  admin: any,
  config: FareAIConfig,
  gmapOn: boolean,
  appleOn: boolean,
): Promise<{ gmap: number; apple: number }> {
  const g = balanceOf(config as Record<string, unknown>);
  const a = appleBalanceOf(config as Record<string, unknown>);
  const needRow = (gmapOn && g.mode === "auto") || (appleOn && a.mode === "auto");
  let row: Record<string, unknown> | null = null;
  if (needRow) {
    const { data, error } = await admin.from("fare_live_balance").select("*").maybeSingle();
    if (!error && data) row = data as Record<string, unknown>;
  }
  const auto = (v: unknown, lo: number, hi: number) => {
    const n = Number(v);
    return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : lo;
  };
  const gmap = !gmapOn ? 0 : g.mode !== "auto" ? g.gmapFirstPct : auto(row?.gmap_first_pct, g.minPct, g.maxPct);
  const apple = !appleOn ? 0 : a.mode !== "auto" ? a.firstPct : auto(row?.apple_first_pct, a.minPct, a.maxPct);
  return { gmap, apple };
}

type StepResult = { estimate: (RouteEstimate & { stops: number }) | null; reason: string };

/** The usable keys of the AI provider. */
function aiKeysOf(config: FareAIConfig, provider: Provider): FareAIKey[] {
  return (config.keys?.[provider] ?? []).filter(
    (k) => k && k.enabled !== false && typeof k.key === "string" && k.key.trim().length > 0,
  );
}

/** The ids among [ids] resting after a failure (fare_ai_key_states). */
async function coolingIds(ctx: StepContext, ids: string[]): Promise<Set<string>> {
  const { data: stateRows } = await ctx.admin
    .from("fare_ai_key_states")
    .select("key_id, disabled_until")
    .in("key_id", ids);
  const now = Date.now();
  return new Set(
    (stateRows ?? [])
      .filter((r: { disabled_until: string | null }) => {
        const until = r.disabled_until ? new Date(r.disabled_until).getTime() : NaN;
        return Number.isFinite(until) && until > now;
      })
      .map((r: { key_id: string }) => r.key_id),
  );
}

/** The AI provider, its keys in order, skipping keys cooling down after a
 * failure; every attempt logged and counted. */
async function estimateFromAi(ctx: StepContext): Promise<StepResult> {
  const { admin, config, origin, destination, stops } = ctx;
  const provider: Provider = config.provider ?? "gemini";
  const model = config.models?.[provider] ?? DEFAULT_MODELS[provider];
  const candidates = aiKeysOf(config, provider);
  if (candidates.length === 0) return { estimate: null, reason: "no_keys" };
  const cooling = await coolingIds(ctx, candidates.map((k) => k.id));
  const available = candidates.filter((k) => !cooling.has(k.id));
  if (available.length === 0) return { estimate: null, reason: "keys_cooling_down" };

  const request = resolveRequest(config.request);
  const prompt = buildPrompt(request, origin, destination, stops);
  const trendSettings = resolveTrendSettings(config.trend);

  for (const cand of available) {
    const started = Date.now();
    let result: CallResult;
    try {
      result = await callProvider(provider, prompt, cand.key, model, request, fetchWithin(ctx.timing.aiMs));
    } catch (e) {
      result = {
        content: null,
        httpStatus: null,
        error: e instanceof Error ? e.message : String(e),
      };
    }
    const latencyMs = Date.now() - started;

    const answered = result.content ? parseEstimate(result.content) : null;
    const standard = await ctx.standardFuture;
    // An answer whose distance can't be right (e.g. 15,420 km for a trip in
    // Malaysia) is not used. The key isn't broken, so it isn't rested, and
    // the other keys would be asked the same question: the fare goes on to
    // the next step.
    const implausible = answered ? implausibleDistance(answered.distance_km, standard?.km) : null;
    const parsed = implausible ? null : answered;
    const success = !!parsed;
    const errorMsg = success
      ? null
      : implausible ?? result.error ?? (result.content ? "Unparseable response" : "No response content");
    const disabledUntil = success || implausible ? null : new Date(Date.now() + ctx.cooldownMs).toISOString();
    if (parsed) {
      const trend = decideFareTrend(parsed.duration_min, standard?.min ?? null, parsed, trendSettings, request.includeFareRange);
      if (trend) parsed.trend = trend;
    }

    // Log the attempt + bump per-key counters (best-effort).
    await admin.from("fare_ai_responses").insert({
      provider,
      key_id: cand.id,
      key_label: cand.label,
      model,
      origin_lat: origin.latitude,
      origin_lng: origin.longitude,
      dest_lat: destination.latitude,
      dest_lng: destination.longitude,
      success,
      http_status: result.httpStatus,
      // A rejected answer's own numbers are kept, so the log shows what it said.
      distance_km: answered?.distance_km ?? null,
      duration_min: answered?.duration_min ?? null,
      summary: answered?.summary ?? null,
      toll_count: answered?.toll_count ?? null,
      toll_total: answered?.toll_total ?? null,
      tolls: answered?.tolls ?? null,
      error: errorMsg,
      latency_ms: latencyMs,
      raw_response: result.content ? result.content.substring(0, 4000) : null,
      extra: withStops(parsed ? extrasOf(parsed) : null, stops),
      standard_duration_min: standard?.min ?? null,
      standard_distance_km: standard?.km ?? null,
      // Only when true: a database before 0241 has no such column.
      ...((await ctx.testFuture) ? { is_test: true } : {}),
    });
    await admin.rpc("fare_ai_record_usage", {
      p_key_id: cand.id,
      p_provider: provider,
      p_success: success,
      p_disabled_until: disabledUntil,
      p_error: errorMsg,
    });

    if (success && parsed) {
      return { estimate: { ...parsed, provider, stops: stops.length }, reason: "ok" };
    }
    if (implausible) return { estimate: null, reason: "ai_distance_not_believable" };
  }
  return { estimate: null, reason: "all_keys_failed" };
}

/** OSRM, the last step: the office NAS when it is on and serves routes
 * (nas_maps_link, migration 0319), else the standard route (OSRM_URL). Road
 * distance and empty-road time, no traffic or tolls. Logged, never rested. */
async function estimateFromOsrm(ctx: StepContext): Promise<StepResult> {
  const { admin, origin, destination, stops } = ctx;
  const started = Date.now();
  let route: { km: number; min: number } | null = null;
  let label = "OSRM server";
  let error: string | null = null;
  try {
    const { data } = await admin.rpc("nas_maps_link", { p_lat: origin.latitude, p_lng: origin.longitude });
    const link = parseNasLink(data);
    if (link?.routes) {
      label = "Office NAS";
      const points = [origin, ...stops, destination].map((p) => [p.latitude, p.longitude] as [number, number]);
      const r = nasRouteRequest(link, points);
      const res = await fetch(r.url, { headers: r.headers, signal: AbortSignal.timeout(ctx.timing.osrmMs) });
      const body = res.ok ? await res.json() : null;
      const m = Number(body?.routes?.[0]?.distance), sec = Number(body?.routes?.[0]?.duration);
      if (m > 0 && sec > 0) route = { km: m / 1000, min: sec / 60 };
      else error = `Office NAS: ${res.ok ? "no route" : `HTTP ${res.status}`}`;
    }
  } catch (e) {
    error = `Office NAS: ${e instanceof Error ? e.message : String(e)}`;
  }
  if (!route) {
    const standard = await ctx.standardFuture;
    if (standard) {
      route = standard;
      label = "OSRM server";
    }
  }
  const estimate = osrmEstimate(route);
  await admin.from("fare_ai_responses").insert({
    provider: OSRM_PROVIDER,
    key_id: null,
    key_label: label,
    model: "OSRM",
    origin_lat: origin.latitude,
    origin_lng: origin.longitude,
    dest_lat: destination.latitude,
    dest_lng: destination.longitude,
    success: !!estimate,
    distance_km: estimate?.distance_km ?? null,
    duration_min: estimate?.duration_min ?? null,
    summary: estimate?.summary ?? null,
    error: estimate ? null : error ?? "No OSRM route",
    latency_ms: Date.now() - started,
    extra: withStops(null, stops),
    ...((await ctx.testFuture) ? { is_test: true } : {}),
  });
  return estimate
    ? { estimate: { ...estimate, provider: OSRM_PROVIDER, stops: stops.length }, reason: "ok" }
    : { estimate: null, reason: "no_osrm_route" };
}

/** Asks one kind of server that speaks GET.route's API (Waze: GET.route;
 * Google Maps: the Traffic Scraper), the pickup's area first (see
 * orderServersFor), skipping any cooling down after a failure, and logs
 * every attempt like an AI key's. The first answer wins. */
async function estimateFromRouteServers(ctx: StepContext, kind: RouteServerKind): Promise<StepResult> {
  const { admin, config, origin, destination, stops, cooldownMs } = ctx;
  const p = kind.provider;
  let servers = routeServersOf(config as Record<string, unknown>, kind);
  if (servers.length === 0) return { estimate: null, reason: `no_${p}_servers` };
  if (anyArea(servers)) {
    // The pickup's country / state / city / suburb, as commission rules see it.
    const { data: rows, error } = await admin.rpc("regions_at", {
      p_lat: origin.latitude,
      p_lng: origin.longitude,
    });
    if (error) console.error("ai-route-proxy: regions_at failed", error.message);
    servers = orderServersFor(servers, placeFromRegions((rows ?? []) as RegionRow[]));
  }
  const cooling = await coolingIds(ctx, servers.map((s) => s.id));
  const available = servers.filter((s) => !cooling.has(s.id));
  if (available.length === 0) return { estimate: null, reason: `${p}_servers_cooling_down` };

  const points: WazeLatLng[] = [origin, ...stops, destination];
  const trendSettings = resolveTrendSettings(config.trend);
  // One budget for the live-traffic steps together (Waze and Google Maps),
  // so the AI and OSRM still answer before the rider app stops waiting
  // (WAZE_TRIP_BUDGET_MS). The second one gets what the first left. A kind
  // with its own budget (Apple Maps: one HTTPS call, no browser) gets that.
  // Each kind has its own time (Admin › Fare AI › Time limits, fare_timing.ts),
  // every server of the kind included.
  const deadline = Date.now() +
    (kind.provider === "waze" ? ctx.timing.wazeMs : kind.provider === "gmap" ? ctx.timing.gmapMs : ctx.timing.appleMs);
  for (const server of available) {
    const left = deadline - Date.now();
    if (left < 300) return { estimate: null, reason: `${p}_out_of_time` };
    const started = Date.now();
    const result = await askWazeServer(server, points, fetch, left, kind.sourceName);
    const latencyMs = Date.now() - started;
    const parsed: RouteEstimate | null = result.estimate ? { ...result.estimate } : null;
    const standard = await ctx.standardFuture;
    if (parsed) {
      // The live time against the empty-road time: the same arrows an AI gets.
      const trend = decideFareTrend(parsed.duration_min, standard?.min ?? null, {}, trendSettings, false);
      if (trend) parsed.trend = trend;
    }
    const success = !!parsed;
    await admin.from("fare_ai_responses").insert({
      provider: p,
      key_id: server.id,
      key_label: server.label,
      model: kind.model,
      origin_lat: origin.latitude,
      origin_lng: origin.longitude,
      dest_lat: destination.latitude,
      dest_lng: destination.longitude,
      success,
      http_status: result.httpStatus,
      distance_km: parsed?.distance_km ?? null,
      duration_min: parsed?.duration_min ?? null,
      summary: parsed?.summary ?? null,
      toll_count: parsed?.toll_count ?? null,
      toll_total: parsed?.toll_total ?? null,
      tolls: parsed?.tolls ?? null,
      error: result.error,
      latency_ms: latencyMs,
      raw_response: result.raw ? result.raw.substring(0, 4000) : null,
      extra: withLiveFirst(withStops(parsed ? extrasOf(parsed) : null, stops), ctx.liveFirst),
      standard_duration_min: standard?.min ?? null,
      standard_distance_km: standard?.km ?? null,
      ...((await ctx.testFuture) ? { is_test: true } : {}),
    });
    await admin.rpc("fare_ai_record_usage", {
      p_key_id: server.id,
      p_provider: p,
      p_success: success,
      p_disabled_until: success ? null : new Date(Date.now() + restMs(cooldownMs, result.retryAfterSeconds)).toISOString(),
      p_error: result.error,
    });
    if (parsed) return { estimate: { ...parsed, provider: p, stops: stops.length }, reason: "ok" };
  }
  return { estimate: null, reason: `all_${p}_servers_failed` };
}

/** Admin "Test" on a Waze, Google Maps or Apple Maps server, saved or not: one trip,
 * nothing recorded. */
async function runWazeTest(
  req: Request,
  supabaseUrl: string,
  draft: unknown,
  config: FareAIConfig,
  origin: LatLng,
  destination: LatLng,
  stops: LatLng[],
  kind: RouteServerKind,
): Promise<Response> {
  // Edit access to Fare AI: the admin may name any server and key here.
  const canEdit = await callerCanEdit({
    url: supabaseUrl,
    anonKey: Deno.env.get("SUPABASE_ANON_KEY") ?? "",
    serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  }, req.headers.get("Authorization"), FARE_AI_PAGES).catch(() => false);
  if (canEdit !== true) return json({ ok: false, error: "admin_only" }, 403);

  const d = (draft && typeof draft === "object" ? draft : {}) as Record<string, unknown>;
  const url = cleanServerUrl(d.url);
  const key = typeof d.key === "string" ? d.key.trim() : "";
  if (!url) return json({ ok: false, error: "The server URL must start with https://" });
  if (!key) return json({ ok: false, error: "The server needs its key" });
  const server: WazeServer = {
    id: typeof d.id === "string" ? d.id : "test",
    label: typeof d.label === "string" && d.label.trim() ? d.label.trim() : kind.serverLabel,
    url,
    key,
    enabled: true,
    ...(areaOf(d.area) ? { area: areaOf(d.area)! } : {}),
  };
  const started = Date.now();
  // A test may wake a cold container (Chrome takes 20-40 s), so it waits longer than a rider.
  const result = await askWazeServer(server, [origin, ...stops, destination], fetch, 60_000, kind.sourceName);
  const standard = await standardRoute(origin, destination, stops);
  const estimate: RouteEstimate | null = result.estimate ? { ...result.estimate } : null;
  if (estimate) {
    const trend = decideFareTrend(estimate.duration_min, standard?.min ?? null, {}, resolveTrendSettings(config.trend), false);
    if (trend) estimate.trend = trend;
  }
  return json({
    ok: true,
    test: {
      provider: kind.provider,
      server: server.label,
      url: server.url,
      raw: result.raw ? result.raw.substring(0, 4000) : null,
      estimate,
      standard,
      http_status: result.httpStatus,
      error: result.error,
      latency_ms: Date.now() - started,
    },
  });
}

/** The fare-range, traffic and trend answers of an estimate (null when none). */
function extrasOf(e: RouteEstimate): Record<string, unknown> | null {
  const x: Record<string, unknown> = {};
  for (const k of [
    "current_duration_is_baseline",
    "current_duration_is_low",
    "current_duration_is_heavy",
    "traffic_congestion",
    "traffic_congestion_stretch_location_details",
    "trend",
  ] as const) {
    if (e[k] !== undefined) x[k] = e[k];
  }
  return Object.keys(x).length ? x : null;
}

/** The stops a logged attempt covered, beside its other extras. */
/** Notes which live-traffic step went first (the balance) on a Waze / Google Maps log row. */
function withLiveFirst(extra: Record<string, unknown> | null, liveFirst?: LiveFirst): Record<string, unknown> | null {
  return liveFirst ? { ...(extra ?? {}), live_first: liveFirst } : extra;
}

function withStops(extra: Record<string, unknown> | null, stops: LatLng[]): Record<string, unknown> | null {
  if (stops.length === 0) return extra;
  return { ...(extra ?? {}), stops: stops.map((s) => ({ lat: s.latitude, lng: s.longitude })) };
}

/** Admin "Test" on Request & format: one call with the draft, nothing recorded. */
async function runTest(
  req: Request,
  supabaseUrl: string,
  draft: unknown,
  config: FareAIConfig,
  provider: Provider,
  model: string,
  candidates: FareAIKey[],
  origin: LatLng,
  destination: LatLng,
  stops: LatLng[],
): Promise<Response> {
  // Edit access to Fare AI, not any admin: a test spends the provider key.
  const canEdit = await callerCanEdit({
    url: supabaseUrl,
    anonKey: Deno.env.get("SUPABASE_ANON_KEY") ?? "",
    serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  }, req.headers.get("Authorization"), FARE_AI_PAGES).catch(() => false);
  if (canEdit !== true) return json({ ok: false, error: "admin_only" }, 403);

  const raw = (draft ?? config.request) as FareAIRequest | undefined;
  if (raw && typeof raw.promptTemplate === "string") {
    const problem = templateProblem(raw.promptTemplate);
    if (problem) return json({ ok: false, error: problem });
  }
  const request = resolveRequest(raw);
  const prompt = buildPrompt(request, origin, destination, stops);
  const standardFuture = standardRoute(origin, destination, stops);
  const key = candidates[0];
  if (!key) {
    return json({ ok: true, test: { provider, model, prompt, system: request.systemInstruction, error: "No active key for this provider" } });
  }
  const started = Date.now();
  let result: CallResult;
  try {
    result = await callProvider(provider, prompt, key.key, model, request);
  } catch (e) {
    result = { content: null, httpStatus: null, error: e instanceof Error ? e.message : String(e) };
  }
  const estimate = result.content ? parseEstimate(result.content) : null;
  const standard = await standardFuture;
  if (estimate) {
    const trend = decideFareTrend(
      estimate.duration_min,
      standard?.min ?? null,
      estimate,
      resolveTrendSettings(config.trend),
      request.includeFareRange,
    );
    if (trend) estimate.trend = trend;
  }
  return json({
    ok: true,
    test: {
      provider,
      model,
      key_label: key.label,
      system: request.systemInstruction,
      prompt,
      raw: result.content ? result.content.substring(0, 4000) : null,
      estimate,
      http_status: result.httpStatus,
      error: estimate ? null : result.error ?? (result.content ? "Unparseable response" : "No response content"),
      latency_ms: Date.now() - started,
    },
  });
}
