// vehicle-permit-read: a vehicle-managing approver (or an admin) sends a photo of
// a vehicle operating permit (Malaysia: the APAD / EVP e-hailing permit; named
// differently per country); Gemini reads it and returns the permit number,
// expiry, the plate it is issued for, and the issuing authority — so the approver
// can prefill the permit and catch one issued for a different car. Gemini only,
// keyed off the admin's fare-AI config. Pure shaping is in _shared/vehicle_permit.ts.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import {
  hasAnyField,
  normalizePermit,
  PERMIT_PROMPT,
  PERMIT_SYSTEM,
} from "../_shared/vehicle_permit.ts";

function bearerToken(header: string | null): string | null {
  if (!header) return null;
  const m = header.match(/^Bearer\s+(.+)$/i);
  return m ? m[1].trim() : null;
}

const GEMINI_MODEL = "gemini-2.5-flash";
const MAX_IMAGE_BYTES = 8 * 1024 * 1024;
const READS_PER_HOUR = 30;

function geminiKey(config: unknown): string | null {
  const keys = (config as { keys?: { gemini?: { key?: unknown; enabled?: unknown }[] } } | null)?.keys?.gemini ?? [];
  for (const k of keys) {
    if (k && k.enabled !== false && typeof k.key === "string" && k.key.trim()) return k.key.trim();
  }
  return null;
}

function jsonObjectIn(content: string): Record<string, unknown> | null {
  const cleaned = content.replace(/```json/gi, "").replace(/```/g, "").trim();
  const match = cleaned.match(/\{[\s\S]*\}/);
  if (!match) return null;
  try {
    const v = JSON.parse(match[0]);
    return v && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : null;
  } catch {
    return null;
  }
}

/** Parse a `data:<mime>;base64,<data>` image URL into its parts, or an error. */
function parseDataUrl(input: unknown): { mime: string; base64: string } | string {
  if (typeof input !== "string") return "image is required";
  const m = input.match(/^data:(image\/[a-zA-Z0-9.+-]+);base64,([A-Za-z0-9+/=]+)$/);
  if (!m) return "image must be a base64 data URL";
  const [, mime, base64] = m;
  if (base64.length * 0.75 > MAX_IMAGE_BYTES) return "image is too large";
  return { mime, base64 };
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "7200",
};

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, error: "POST only" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) return json({ ok: false, error: "missing_credentials" }, 500);
  const admin = createClient(supabaseUrl, serviceKey);

  const token = bearerToken(req.headers.get("Authorization"));
  const { data: who } = token ? await admin.auth.getUser(token) : { data: { user: null } };
  const uid = who?.user?.id;
  if (!uid) return json({ ok: false, error: "sign_in" }, 401);

  const [{ data: appr }, { data: adm }] = await Promise.all([
    admin.from("approvers").select("profile_id")
      .eq("profile_id", uid).eq("active", true).eq("can_manage_vehicle", true).limit(1).maybeSingle(),
    admin.from("admin_access").select("profile_id").eq("profile_id", uid).limit(1).maybeSingle(),
  ]);
  if (!appr && !adm) return json({ ok: false, error: "not_allowed" }, 403);

  const { data: wait, error: rateErr } = await admin.rpc("auth_rate_take", {
    p_bucket: "vehicle_permit_ai", p_key: uid, p_limit: READS_PER_HOUR, p_window: "1 hour",
  });
  if (rateErr || typeof wait !== "number") return json({ ok: false, error: "unavailable" }, 503);
  if (wait > 0) return json({ ok: false, error: "rate_limited", retry_after: wait }, 429);

  let body: { front?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "bad_json" }, 400);
  }
  const image = parseDataUrl(body.front);
  if (typeof image === "string") return json({ ok: false, error: image }, 400);

  const { data: cfgRow } = await admin.from("app_settings").select("value").eq("key", "fare_ai_provider").maybeSingle();
  const apiKey = geminiKey(cfgRow?.value ?? null);
  if (!apiKey) return json({ ok: false, error: "no_keys" }, 503);

  let answer: string | null = null;
  try {
    const res = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent?key=${apiKey}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: PERMIT_SYSTEM }] },
          contents: [{
            role: "user",
            parts: [
              { text: PERMIT_PROMPT },
              { inline_data: { mime_type: image.mime, data: image.base64 } },
            ],
          }],
          generationConfig: { temperature: 0, responseMimeType: "application/json" },
        }),
        signal: AbortSignal.timeout(45_000),
      },
    );
    if (res.ok) {
      const data = await res.json();
      answer = data?.candidates?.[0]?.content?.parts?.[0]?.text ?? null;
    } else {
      console.log(`[vehicle-permit-read] gemini HTTP ${res.status}`);
      await res.body?.cancel();
    }
  } catch (e) {
    console.log(`[vehicle-permit-read] gemini error: ${e instanceof Error ? e.message : e}`);
  }
  if (answer == null) return json({ ok: false, error: "read_failed" }, 502);

  const fields = normalizePermit(jsonObjectIn(answer));
  return json({ ok: true, fields, read: hasAnyField(fields) });
});
