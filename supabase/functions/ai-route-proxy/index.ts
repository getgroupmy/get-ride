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
//     "destination": { "latitude": n, "longitude": n } }
//
// Response:
//   { "ok": true, "estimate": RouteEstimate | null }
//   estimate = { distance_km, duration_min, summary?, provider,
//                toll_count?, toll_total?, tolls? } — null when the service
//   is disabled, no keys are configured/available, or every key failed
//   (callers fall back to a routing engine, same contract as before).
//
// Every attempt is logged to `fare_ai_responses` and per-key counters /
// cooldowns are updated via the `fare_ai_record_usage` RPC — identical to
// what the client used to record.
//
// Deploy:
//   supabase functions deploy ai-route-proxy --no-verify-jwt
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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
  retryAfterUnit?: "hour" | "day" | "month";
  models?: Partial<Record<Provider, string>>;
  keys?: Partial<Record<Provider, FareAIKey[]>>;
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

interface RouteEstimate {
  distance_km: number;
  duration_min: number;
  summary?: string;
  provider?: Provider;
  toll_count?: number;
  toll_total?: number;
  tolls?: TollBooth[];
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

const SYSTEM_INSTRUCTION =
  "You return only valid JSON. Never wrap the JSON in markdown fences.";

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function buildPrompt(origin: LatLng, destination: LatLng): string {
  const originStr = `${origin.latitude},${origin.longitude}`;
  const destStr = `${destination.latitude},${destination.longitude}`;
  const userQuery = `${originStr} to ${destStr} realtime minute and distance with traffic`;
  return (
    `You are a driving route estimator with access to real-time traffic and toll road data. ` +
    `For the trip "${userQuery}", estimate the total driving distance, the ` +
    `current driving time including live traffic, and the toll booths/plazas along the route ` +
    `with their individual charges in local currency. ` +
    `Respond with ONLY a compact JSON object, no markdown, no extra text, of the form: ` +
    `{"distance_km": <number>, "duration_min": <number>, "summary": "<short text>", ` +
    `"toll_count": <integer>, "toll_total": <number>, "tolls": [{"name": "<booth name>", "charge": <number>, "lat": <number>, "lng": <number>}]}. ` +
    `distance_km is total kilometres (number). duration_min is total minutes with traffic (integer). ` +
    `toll_count is the number of toll booths/plazas on the route (integer, 0 if none). ` +
    `toll_total is the sum of all toll charges (number, 0 if none). ` +
    `tolls is an array of each real toll booth/plaza that physically exists on this route, in travel order, ` +
    `each with its name, charge, and exact geographic coordinates (lat and lng as decimal degrees) of the booth location. ` +
    `Use real, known toll plaza coordinates; do not invent coordinates. Empty array if none.`
  );
}

function retryPolicyMs(value: number, unit: string): number {
  const v = Number.isFinite(value) && value > 0 ? value : 1;
  const hour = 60 * 60 * 1000;
  switch (unit) {
    case "month":
      return v * 30 * 24 * hour;
    case "day":
      return v * 24 * hour;
    default:
      return v * hour;
  }
}

async function callOpenAICompatible(
  endpoint: string,
  apiKey: string,
  model: string,
  prompt: string,
  label: string,
): Promise<CallResult> {
  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model,
      temperature: 0,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: SYSTEM_INSTRUCTION },
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

async function callGemini(prompt: string, apiKey: string, model: string): Promise<CallResult> {
  const endpoint =
    `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`;
  const response = await fetch(endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: SYSTEM_INSTRUCTION }] },
      contents: [{ role: "user", parts: [{ text: prompt }] }],
      generationConfig: { temperature: 0, responseMimeType: "application/json" },
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

async function callAnthropic(prompt: string, apiKey: string, model: string): Promise<CallResult> {
  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model,
      max_tokens: 256,
      temperature: 0,
      system: SYSTEM_INSTRUCTION,
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
): Promise<CallResult> {
  switch (provider) {
    case "grok":
      return callOpenAICompatible("https://api.x.ai/v1/chat/completions", apiKey, model, prompt, "Grok");
    case "chatgpt":
      return callOpenAICompatible("https://api.openai.com/v1/chat/completions", apiKey, model, prompt, "ChatGPT");
    case "groq":
      return callOpenAICompatible("https://api.groq.com/openai/v1/chat/completions", apiKey, model, prompt, "Groq");
    case "perplexity":
      return callOpenAICompatible("https://api.perplexity.ai/chat/completions", apiKey, model, prompt, "Perplexity");
    case "mistral":
      return callOpenAICompatible("https://api.mistral.ai/v1/chat/completions", apiKey, model, prompt, "Mistral");
    case "deepseek":
      return callOpenAICompatible("https://api.deepseek.com/chat/completions", apiKey, model, prompt, "DeepSeek");
    case "cohere":
      return callOpenAICompatible("https://api.cohere.ai/compatibility/v1/chat/completions", apiKey, model, prompt, "Cohere");
    case "together":
      return callOpenAICompatible("https://api.together.xyz/v1/chat/completions", apiKey, model, prompt, "Together AI");
    case "openrouter":
      return callOpenAICompatible("https://openrouter.ai/api/v1/chat/completions", apiKey, model, prompt, "OpenRouter");
    case "fireworks":
      return callOpenAICompatible("https://api.fireworks.ai/inference/v1/chat/completions", apiKey, model, prompt, "Fireworks");
    case "claude":
      return callAnthropic(prompt, apiKey, model);
    case "gemini":
    default:
      return callGemini(prompt, apiKey, model);
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

  let body: { origin?: unknown; destination?: unknown };
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
  if (config.serviceEnabled === false) {
    return json({ ok: true, estimate: null, reason: "service_disabled" });
  }

  const provider: Provider = config.provider ?? "gemini";
  const model = config.models?.[provider] ?? DEFAULT_MODELS[provider];
  const candidates = (config.keys?.[provider] ?? []).filter(
    (k) => k && k.enabled !== false && typeof k.key === "string" && k.key.trim().length > 0,
  );
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

  const prompt = buildPrompt(origin, destination);
  const cooldownMs = retryPolicyMs(config.retryAfterValue ?? 1, config.retryAfterUnit ?? "hour");

  for (const cand of available) {
    const started = Date.now();
    let result: CallResult;
    try {
      result = await callProvider(provider, prompt, cand.key, model);
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
    });
    await admin.rpc("fare_ai_record_usage", {
      p_key_id: cand.id,
      p_provider: provider,
      p_success: success,
      p_disabled_until: disabledUntil,
      p_error: errorMsg,
    });

    if (success && parsed) {
      return json({ ok: true, estimate: { ...parsed, provider } });
    }
  }

  return json({ ok: true, estimate: null, reason: "all_keys_failed" });
});
