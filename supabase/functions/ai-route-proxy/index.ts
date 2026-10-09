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
// what the client used to record.
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
// Deploy:
//   supabase functions deploy ai-route-proxy --no-verify-jwt
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import {
  buildPrompt,
  decideFareTrend,
  type FareAIRequest,
  type FareTrend,
  parseStops,
  parseTrafficExtras,
  type ResolvedRequest,
  resolveRequest,
  resolveTrendSettings,
  retryPolicyMs,
  templateProblem,
  type TrafficExtras,
} from "../_shared/fare_ai_request.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type Provider =
  | "gemini"
  | "grok"
  | "chatgpt"
  | "groq"
  | "claude"
  | "perplexity"
  | "mistral"
  | "deepseek"
  | "cohere"
  | "together"
  | "openrouter"
  | "fireworks";

interface FareAIKey {
  id: string;
  label: string;
  key: string;
  enabled: boolean;
}

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
  provider?: Provider;
  toll_count?: number;
  toll_total?: number;
  tolls?: TollBooth[];
  /** The arrows before the recommended fare; absent when undecided. */
  trend?: FareTrend;
}

interface CallResult {
  content: string | null;
  httpStatus: number | null;
  error: string | null;
}

const DEFAULT_MODELS: Record<Provider, string> = {
  gemini: "gemini-2.5-flash",
  grok: "grok-3",
  chatgpt: "gpt-4o-mini",
  groq: "llama-3.3-70b-versatile",
  claude: "claude-3-5-haiku-latest",
  perplexity: "sonar",
  mistral: "mistral-small-latest",
  deepseek: "deepseek-chat",
  cohere: "command-r",
  together: "meta-llama/Llama-3.3-70B-Instruct-Turbo",
  openrouter: "openai/gpt-4o-mini",
  fireworks: "accounts/fireworks/models/llama-v3p3-70b-instruct",
};

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function callOpenAICompatible(
  endpoint: string,
  apiKey: string,
  model: string,
  prompt: string,
  label: string,
  req: ResolvedRequest,
): Promise<CallResult> {
  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model,
      temperature: req.temperature,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: req.systemInstruction },
        { role: "user", content: prompt },
      ],
    }),
  });
  if (!response.ok) {
    const errText = await response.text();
    return {
      content: null,
      httpStatus: response.status,
      error: `${label} HTTP ${response.status}: ${errText.substring(0, 200)}`,
    };
  }
  const data = await response.json();
  const content: string | undefined = data?.choices?.[0]?.message?.content;
  return {
    content: content ?? null,
    httpStatus: response.status,
    error: content ? null : "Empty content",
  };
}

async function callGemini(prompt: string, apiKey: string, model: string, req: ResolvedRequest): Promise<CallResult> {
  const endpoint =
    `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`;
  const response = await fetch(endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: req.systemInstruction }] },
      contents: [{ role: "user", parts: [{ text: prompt }] }],
      generationConfig: { temperature: req.temperature, responseMimeType: "application/json" },
    }),
  });
  if (!response.ok) {
    const errText = await response.text();
    return {
      content: null,
      httpStatus: response.status,
      error: `HTTP ${response.status}: ${errText.substring(0, 200)}`,
    };
  }
  const data = await response.json();
  const content: string | undefined = data?.candidates?.[0]?.content?.parts?.[0]?.text;
  return {
    content: content ?? null,
    httpStatus: response.status,
    error: content ? null : "Empty content",
  };
}

async function callAnthropic(prompt: string, apiKey: string, model: string, req: ResolvedRequest): Promise<CallResult> {
  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model,
      // Claude requires a cap; the others use their own limit.
      max_tokens: req.maxTokens,
      temperature: req.temperature,
      system: req.systemInstruction,
      messages: [{ role: "user", content: prompt }],
    }),
  });
  if (!response.ok) {
    const errText = await response.text();
    return {
      content: null,
      httpStatus: response.status,
      error: `Claude HTTP ${response.status}: ${errText.substring(0, 200)}`,
    };
  }
  const data = await response.json();
  const content: string | undefined = data?.content?.[0]?.text;
  return {
    content: content ?? null,
    httpStatus: response.status,
    error: content ? null : "Empty content",
  };
}

function callProvider(
  provider: Provider,
  prompt: string,
  apiKey: string,
  model: string,
  req: ResolvedRequest,
): Promise<CallResult> {
  switch (provider) {
    case "grok":
      return callOpenAICompatible("https://api.x.ai/v1/chat/completions", apiKey, model, prompt, "Grok", req);
    case "chatgpt":
      return callOpenAICompatible("https://api.openai.com/v1/chat/completions", apiKey, model, prompt, "ChatGPT", req);
    case "groq":
      return callOpenAICompatible("https://api.groq.com/openai/v1/chat/completions", apiKey, model, prompt, "Groq", req);
    case "perplexity":
      return callOpenAICompatible("https://api.perplexity.ai/chat/completions", apiKey, model, prompt, "Perplexity", req);
    case "mistral":
      return callOpenAICompatible("https://api.mistral.ai/v1/chat/completions", apiKey, model, prompt, "Mistral", req);
    case "deepseek":
      return callOpenAICompatible("https://api.deepseek.com/chat/completions", apiKey, model, prompt, "DeepSeek", req);
    case "cohere":
      return callOpenAICompatible("https://api.cohere.ai/compatibility/v1/chat/completions", apiKey, model, prompt, "Cohere", req);
    case "together":
      return callOpenAICompatible("https://api.together.xyz/v1/chat/completions", apiKey, model, prompt, "Together AI", req);
    case "openrouter":
      return callOpenAICompatible("https://openrouter.ai/api/v1/chat/completions", apiKey, model, prompt, "OpenRouter", req);
    case "fireworks":
      return callOpenAICompatible("https://api.fireworks.ai/inference/v1/chat/completions", apiKey, model, prompt, "Fireworks", req);
    case "claude":
      return callAnthropic(prompt, apiKey, model, req);
    case "gemini":
    default:
      return callGemini(prompt, apiKey, model, req);
  }
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

  let body: { origin?: unknown; destination?: unknown; waypoints?: unknown; test?: unknown; request?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "Invalid JSON body" }, 400);
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

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) {
    return json({ ok: false, error: "Function is missing Supabase credentials" }, 500);
  }
  const admin = createClient(supabaseUrl, serviceKey);

  const { data: settingsRow, error: settingsErr } = await admin
    .from("app_settings")
    .select("value")
    .eq("key", "fare_ai_provider")
    .maybeSingle();
  if (settingsErr) {
    return json({ ok: false, error: `Config read failed: ${settingsErr.message}` }, 500);
  }

  const config = (settingsRow?.value ?? {}) as FareAIConfig;
  if (config.serviceEnabled === false && body.test !== true) {
    return json({ ok: true, estimate: null, reason: "service_disabled" });
  }

  const provider: Provider = config.provider ?? "gemini";
  const model = config.models?.[provider] ?? DEFAULT_MODELS[provider];
  const candidates = (config.keys?.[provider] ?? []).filter(
    (k) => k && k.enabled !== false && typeof k.key === "string" && k.key.trim().length > 0,
  );
  if (body.test === true) {
    return runTest(req, supabaseUrl, body.request, config, provider, model, candidates, origin, destination, stops);
  }
  if (candidates.length === 0) {
    return json({ ok: true, estimate: null, reason: "no_keys" });
  }

  // Skip keys that are cooling down after recent failures.
  const ids = candidates.map((k) => k.id);
  const { data: stateRows } = await admin
    .from("fare_ai_key_states")
    .select("key_id, disabled_until")
    .in("key_id", ids);
  const now = Date.now();
  const cooling = new Set(
    (stateRows ?? [])
      .filter((r: { key_id: string; disabled_until: string | null }) => {
        if (!r.disabled_until) return false;
        const until = new Date(r.disabled_until).getTime();
        return Number.isFinite(until) && until > now;
      })
      .map((r: { key_id: string }) => r.key_id),
  );
  const available = candidates.filter((k) => !cooling.has(k.id));
  if (available.length === 0) {
    return json({ ok: true, estimate: null, reason: "keys_cooling_down" });
  }

  const request = resolveRequest(config.request);
  const prompt = buildPrompt(request, origin, destination, stops);
  const trendSettings = resolveTrendSettings(config.trend);
  // Alongside the AI: the AI usually takes longer, so this is in by then.
  const standardFuture = standardRoute(origin, destination, stops);
  const cooldownMs = retryPolicyMs(config.retryAfterValue ?? 1, config.retryAfterUnit ?? "hour");

  for (const cand of available) {
    const started = Date.now();
    let result: CallResult;
    try {
      result = await callProvider(provider, prompt, cand.key, model, request);
    } catch (e) {
      result = {
        content: null,
        httpStatus: null,
        error: e instanceof Error ? e.message : String(e),
      };
    }
    const latencyMs = Date.now() - started;

    const parsed = result.content ? parseEstimate(result.content) : null;
    const success = !!parsed;
    const errorMsg = success
      ? null
      : result.error ?? (result.content ? "Unparseable response" : "No response content");
    const disabledUntil = success ? null : new Date(Date.now() + cooldownMs).toISOString();
    const standard = await standardFuture;
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
      distance_km: parsed?.distance_km ?? null,
      duration_min: parsed?.duration_min ?? null,
      summary: parsed?.summary ?? null,
      toll_count: parsed?.toll_count ?? null,
      toll_total: parsed?.toll_total ?? null,
      tolls: parsed?.tolls ?? null,
      error: errorMsg,
      latency_ms: latencyMs,
      raw_response: result.content ? result.content.substring(0, 4000) : null,
      extra: withStops(parsed ? extrasOf(parsed) : null, stops),
      standard_duration_min: standard?.min ?? null,
      standard_distance_km: standard?.km ?? null,
    });
    await admin.rpc("fare_ai_record_usage", {
      p_key_id: cand.id,
      p_provider: provider,
      p_success: success,
      p_disabled_until: disabledUntil,
      p_error: errorMsg,
    });

    if (success && parsed) {
      return json({ ok: true, estimate: { ...parsed, provider, stops: stops.length } });
    }
  }

  return json({ ok: true, estimate: null, reason: "all_keys_failed" });
});

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
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!anonKey) return json({ ok: false, error: "Function is missing the anon key" }, 500);
  const caller = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: isAdmin } = await caller.rpc("caller_is_admin");
  if (isAdmin !== true) return json({ ok: false, error: "admin_only" }, 403);

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
