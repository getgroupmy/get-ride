// vehicle-catalog-lookup (migration 0387): an approver who manages vehicles
// (or an admin) asks the AI to find a make/model that isn't in
// vehicle_make_models yet. The model returns specs constrained to the
// catalogue's own energy/body vocabulary, which are validated and inserted, and
// the rows now on file for that make are returned. All authorization and the
// insert run with the service role; the pure shaping is in
// _shared/vehicle_catalog.ts.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import {
  buildCatalogPrompt,
  CATALOG_SYSTEM,
  type CatalogRow,
  normalizeCatalogEntries,
} from "../_shared/vehicle_catalog.ts";

/** "Bearer <jwt>" → the token, or null. */
function bearerToken(header: string | null): string | null {
  if (!header) return null;
  const m = header.match(/^Bearer\s+(.+)$/i);
  return m ? m[1].trim() : null;
}

const GEMINI_MODEL = "gemini-2.5-flash";

/** The Gemini API key from the admin's fare-AI config (app setting
 *  `fare_ai_provider`), the same place document checks read it. */
function geminiKey(config: unknown): string | null {
  const keys = (config as { keys?: { gemini?: { key?: unknown; enabled?: unknown }[] } } | null)?.keys?.gemini ?? [];
  for (const k of keys) {
    if (k && k.enabled !== false && typeof k.key === "string" && k.key.trim()) return k.key.trim();
  }
  return null;
}

/** The first JSON object in the model's answer. */
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

/** One text question to Gemini, answered as JSON. Null on any failure. */
async function askGemini(apiKey: string, system: string, prompt: string): Promise<string | null> {
  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent?key=${apiKey}`;
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: system }] },
        contents: [{ role: "user", parts: [{ text: prompt }] }],
        generationConfig: { temperature: 0, responseMimeType: "application/json" },
      }),
      signal: AbortSignal.timeout(30_000),
    });
    if (!res.ok) {
      console.log(`[vehicle-catalog-lookup] gemini HTTP ${res.status}`);
      await res.body?.cancel();
      return null;
    }
    const data = await res.json();
    const text: string | undefined = data?.candidates?.[0]?.content?.parts?.[0]?.text;
    return text ?? null;
  } catch (e) {
    console.log(`[vehicle-catalog-lookup] gemini error: ${e instanceof Error ? e.message : e}`);
    return null;
  }
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

const LOOKUPS_PER_HOUR = 30;

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

  // A vehicle-managing approver, or an admin.
  const [{ data: appr }, { data: adm }] = await Promise.all([
    admin.from("approvers").select("profile_id")
      .eq("profile_id", uid).eq("active", true).eq("can_manage_vehicle", true).limit(1).maybeSingle(),
    admin.from("admin_access").select("profile_id").eq("profile_id", uid).limit(1).maybeSingle(),
  ]);
  if (!appr && !adm) return json({ ok: false, error: "not_allowed" }, 403);

  const { data: wait, error: rateErr } = await admin.rpc("auth_rate_take", {
    p_bucket: "vehicle_catalog_ai", p_key: uid, p_limit: LOOKUPS_PER_HOUR, p_window: "1 hour",
  });
  if (rateErr || typeof wait !== "number") return json({ ok: false, error: "unavailable" }, 503);
  if (wait > 0) return json({ ok: false, error: "rate_limited", retry_after: wait }, 429);

  let body: { make?: unknown; model?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "bad_json" }, 400);
  }
  const make = `${body.make ?? ""}`.trim();
  const model = `${body.model ?? ""}`.trim() || null;
  if (make.length < 1 || make.length > 60) return json({ ok: false, error: "make_required" }, 400);

  // The catalogue's own vocabulary + the model names already on file for this
  // make (so we only ever insert what's genuinely new).
  const [{ data: energyRows }, { data: typeRows }, { data: existing }] = await Promise.all([
    admin.from("vehicle_make_models").select("energy_type").eq("status", true),
    admin.from("vehicle_make_models").select("vehicle_type").eq("status", true),
    admin.from("vehicle_make_models").select("model").ilike("make", make),
  ]);
  const uniq = (rows: { [k: string]: unknown }[] | null, col: string) =>
    [...new Set((rows ?? []).map((r) => `${r[col] ?? ""}`.trim()).filter((s) => s))];
  const energies = uniq(energyRows ?? [], "energy_type");
  const types = uniq(typeRows ?? [], "vehicle_type");
  const haveModels = new Set(uniq(existing ?? [], "model").map((m) => m.toLowerCase()));

  const { data: cfgRow } = await admin.from("app_settings").select("value").eq("key", "fare_ai_provider").maybeSingle();
  const apiKey = geminiKey(cfgRow?.value ?? null);
  if (!apiKey) return json({ ok: false, error: "no_keys" }, 503);

  const prompt = buildCatalogPrompt(make, model, energies, types);
  const answer = await askGemini(apiKey, CATALOG_SYSTEM, prompt);
  const rows: CatalogRow[] = answer == null ? [] : normalizeCatalogEntries(jsonObjectIn(answer), {
    expectedMake: make, allowedEnergies: energies, allowedTypes: types,
  });
  if (rows.length === 0) return json({ ok: true, entries: [], added: 0, reason: "nothing_found" });

  // Insert only models not already on file for this make.
  const toAdd = rows.filter((r) => !haveModels.has(r.model.toLowerCase()));
  if (toAdd.length > 0) {
    const { error: insErr } = await admin.from("vehicle_make_models").insert(
      toAdd.map((r) => ({
        make: r.make, model: r.model,
        energy_type: r.energy_type ?? "", vehicle_type: r.vehicle_type ?? "",
        seats: r.seats, status: true, is_default: false, position: 0,
      })),
    );
    if (insErr) {
      console.log(`[vehicle-catalog-lookup] insert failed: ${insErr.message}`);
      return json({ ok: false, error: "insert_failed" }, 500);
    }
  }
  return json({ ok: true, entries: rows, added: toAdd.length });
});
