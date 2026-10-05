// ============================================================================
// document-ai-verify — Supabase Edge Function
// ----------------------------------------------------------------------------
// AI check of a partner's uploaded document photo(s): is it a real document,
// is it the one asked for, and what does it say (number, dates, insurer, and
// for a taxi driver permit the permit fields and where the portrait is).
//
// Replaces the apps sending ID photos straight from the phone to a
// third-party endpoint. The provider and its API keys are the ones the admin
// configured for fare AI (`app_settings` row `fare_ai_provider`), read here
// with the service-role key so they never reach a client. Optional overrides
// in that row: `documentProvider` (a different provider for documents) and
// `documentModels.<provider>` (a vision model); `documentChecksEnabled:false`
// switches the check off.
//
// Only signed-in users may call it. The images are sent to the provider and
// discarded: nothing is stored or logged here.
//
// Request (POST, Authorization: Bearer <user access token>):
//   { "front": "data:image/jpeg;base64,...", "back"?: "data:...",
//     "context": { "docName": "...", "documentNumber"?, "insuranceProviderName"?,
//                  "isPwd"?, "startDate"?, "expiryDate"?, "isTaxiPermit"? } }
// Response:
//   { "ok": true, "result": DocumentAiVerificationResult | null, "reason"? }
//   result is null when checks are off, no usable key exists, the provider
//   cannot read images, or every key failed — the upload goes ahead and an
//   admin reviews it, as before.
//
// Deploy:
//   supabase functions deploy document-ai-verify --no-verify-jwt
//   (the caller's session is verified below instead)
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import {
  bearerToken,
  buildUserText,
  DEFAULT_VISION_MODELS,
  type InlineImage,
  isVisionProvider,
  normalizeResult,
  parseContext,
  parseImage,
  responseText,
  visionRequest,
} from "../_shared/doc_ai.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

interface AiKey {
  id: string;
  label?: string;
  key: string;
  enabled?: boolean;
}

interface Config {
  serviceEnabled?: boolean;
  provider?: string;
  documentChecksEnabled?: boolean;
  documentProvider?: string;
  documentModels?: Record<string, string>;
  keys?: Record<string, AiKey[]>;
}

const PROVIDER_TIMEOUT_MS = 45_000;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, error: "POST only" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) {
    return json({ ok: false, error: "Function is missing Supabase credentials" }, 500);
  }
  const admin = createClient(supabaseUrl, serviceKey);

  // A signed-in user, not just anyone holding the public anon key.
  const token = bearerToken(req.headers.get("Authorization"));
  const { data: who } = token ? await admin.auth.getUser(token) : { data: { user: null } };
  if (!who?.user) return json({ ok: false, error: "Sign in to check a document" }, 401);

  let body: { front?: unknown; back?: unknown; context?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "Invalid JSON body" }, 400);
  }
  const ctx = parseContext(body.context);
  if (!ctx) return json({ ok: false, error: "context.docName is required" }, 400);
  const front = parseImage(body.front);
  if (typeof front === "string") return json({ ok: false, error: `front: ${front}` }, 400);
  const images: InlineImage[] = [front];
  if (body.back != null) {
    const back = parseImage(body.back);
    if (typeof back === "string") return json({ ok: false, error: `back: ${back}` }, 400);
    images.push(back);
  }

  const { data: row, error: rowErr } = await admin
    .from("app_settings")
    .select("value")
    .eq("key", "fare_ai_provider")
    .maybeSingle();
  if (rowErr) return json({ ok: false, error: `Config read failed: ${rowErr.message}` }, 500);
  const config = (row?.value ?? {}) as Config;
  if (config.documentChecksEnabled === false) return json({ ok: true, result: null, reason: "disabled" });

  const provider = config.documentProvider ?? config.provider ?? "gemini";
  if (!isVisionProvider(provider)) return json({ ok: true, result: null, reason: "provider_no_vision" });
  const model = config.documentModels?.[provider] ?? DEFAULT_VISION_MODELS[provider];
  const keys = (config.keys?.[provider] ?? []).filter(
    (k) => k && k.enabled !== false && typeof k.key === "string" && k.key.trim().length > 0,
  );
  if (keys.length === 0) return json({ ok: true, result: null, reason: "no_keys" });

  // Leave out keys fare AI has put on cooldown. Document checks only read
  // that state: a failed image call must not take a key away from fares.
  const { data: states } = await admin
    .from("fare_ai_key_states")
    .select("key_id, disabled_until")
    .in("key_id", keys.map((k) => k.id));
  const now = Date.now();
  const cooling = new Set(
    (states ?? [])
      .filter((s: { disabled_until: string | null }) => s.disabled_until && new Date(s.disabled_until).getTime() > now)
      .map((s: { key_id: string }) => s.key_id),
  );
  const usable = keys.filter((k) => !cooling.has(k.id));
  if (usable.length === 0) return json({ ok: true, result: null, reason: "keys_cooling_down" });

  const userText = buildUserText(ctx, images.length > 1);
  for (const k of usable) {
    const request = visionRequest(provider, model, k.key.trim(), userText, images);
    try {
      const res = await fetch(request.url, {
        method: "POST",
        headers: request.headers,
        body: JSON.stringify(request.body),
        signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS),
      });
      if (!res.ok) {
        console.log(`[document-ai-verify] ${provider} key ${k.label ?? k.id}: HTTP ${res.status}`);
        continue;
      }
      const text = responseText(provider, await res.json());
      const result = text ? normalizeResult(text, ctx, new Date()) : null;
      if (result) return json({ ok: true, result });
      console.log(`[document-ai-verify] ${provider} key ${k.label ?? k.id}: unparseable answer`);
    } catch (e) {
      console.log(`[document-ai-verify] ${provider} key ${k.label ?? k.id}: ${e instanceof Error ? e.message : e}`);
    }
  }
  return json({ ok: true, result: null, reason: "all_keys_failed" });
});
