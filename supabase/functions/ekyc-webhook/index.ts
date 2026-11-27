// ============================================================================
// ekyc-webhook — Supabase Edge Function
// ----------------------------------------------------------------------------
// GET.eKYC (migration 0439): our eKYC server calls this when an identity
// check started by ekyc-start is decided. Signed with the client's webhook
// secret (Admin → API Keys → GET.eKYC → webhook): HMAC-SHA256 over
// "timestamp.body", refused when wrong or older than 5 minutes.
//
// Then, with the API key: the full result and the photos are fetched, the
// photos copied into the person's ID_Image folder, and ekyc_apply() writes
// them as identity checks for the admin (riders may be auto-verified, 0343).
// A failure answers 500, and get.ekyc tries again (after 5 s and 30 s).
//
// Request:  POST from get.ekyc { event: "verification.completed", id, status, … }
// Response: 200 { ok } · 200 { ignored } · 401 bad_signature · 500 failed
//
// Deploy: supabase functions deploy ekyc-webhook --no-verify-jwt (get.ekyc
// has no user token; the signature is the check; see supabase/config.toml)
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { applyPayload, EKYC_TIMEOUT_MS, ekycServer, ekycWebhookSecrets, FINAL, webhookSignatureValid } from "../_shared/ekyc.ts";

const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });

const db = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});

async function setting(key: string): Promise<unknown> {
  const { data, error } = await db.from("app_settings").select("value").eq("key", key).maybeSingle();
  if (error) throw error;
  return data?.value ?? null;
}

const MAX_PHOTO_BYTES = 15 * 1024 * 1024;

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply({ error: "bad_request" }, 405);
  const raw = await req.text();
  const providers = await setting("api_providers");
  const ok = await webhookSignatureValid(
    raw,
    req.headers.get("X-EKYC-Timestamp"),
    req.headers.get("X-EKYC-Signature"),
    ekycWebhookSecrets(providers),
    Math.floor(Date.now() / 1000),
  );
  if (!ok) return reply({ error: "bad_signature" }, 401);

  let event: Record<string, unknown>;
  try {
    event = JSON.parse(raw);
  } catch {
    return reply({ error: "bad_request" }, 400);
  }
  const vid = typeof event.id === "string" ? event.id : "";
  if (event.event !== "verification.completed" || !FINAL.has(String(event.status))) return reply({ ignored: "event" });

  const { data: session } = await db.from("ekyc_sessions").select("id, user_id, state").eq("verification_id", vid).maybeSingle();
  if (!session) return reply({ ignored: "unknown verification" });
  if (session.state === "completed") return reply({ ignored: "already recorded" });

  const server = ekycServer(providers);
  if (!server) return reply({ error: "no_key" }, 500);
  const get = (path: string) =>
    fetch(`${server.url}/v1/verifications/${vid}${path}`, {
      headers: { "X-API-Key": server.secret },
      signal: AbortSignal.timeout(EKYC_TIMEOUT_MS),
    });

  try {
    const res = await get("");
    if (!res.ok) throw new Error(`result: HTTP ${res.status}`);
    const v = await res.json() as Record<string, unknown>;
    if (!FINAL.has(String(v.status))) return reply({ ignored: "not decided" });

    // Copy the photos into the person's own folder, where admins' review
    // screens and the profile already look.
    const stamp = Date.now();
    const copy = async (kind: string): Promise<string | null> => {
      const r = await get(`/media/${kind}`);
      if (r.status === 404) return null;
      if (!r.ok) throw new Error(`${kind}: HTTP ${r.status}`);
      const bytes = new Uint8Array(await r.arrayBuffer());
      if (bytes.length === 0 || bytes.length > MAX_PHOTO_BYTES) throw new Error(`${kind}: size`);
      const type = r.headers.get("Content-Type") ?? "image/jpeg";
      const ext = type.includes("png") ? "png" : type.includes("webp") ? "webp" : "jpg";
      const path = `${session.user_id}/signin/ekyc_${kind}_${stamp}.${ext}`;
      const { error } = await db.storage.from("ID_Image").upload(path, bytes, { contentType: type, upsert: true });
      if (error) throw new Error(`${kind}: upload ${error.message}`);
      return path;
    };
    const front = await copy("document_front");
    if (!front) throw new Error("no document photo");
    const back = await copy("document_back");
    const selfie = await copy("selfie");

    const { error } = await db.rpc("ekyc_apply", {
      p_session: session.id,
      p: applyPayload(v, { front, back, selfie }),
    });
    if (error) throw new Error(`apply: ${error.message}`);
    return reply({ ok: true });
  } catch (e) {
    const why = String(e instanceof Error ? e.message : e).slice(0, 300);
    console.error("ekyc-webhook:", vid, why);
    await db.from("ekyc_sessions").update({ state: "failed", error: why }).eq("id", session.id).neq("state", "completed");
    return reply({ error: "failed" }, 500);
  }
});
