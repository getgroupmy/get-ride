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

import {
  applyPayload,
  docTypeOf,
  EKYC_TIMEOUT_MS,
  ekycServer,
  ekycWebhookSecrets,
  FINAL,
  type MyKadFields,
  webhookSignatureValid,
} from "../_shared/ekyc.ts";
import { base64 } from "../_shared/face_server.ts";
import {
  mykadFromExtract,
  mykadReaderOn,
  OCR_TYPED_EXTRACT_TIMEOUT_MS,
  ocrServer,
  readTypedExtract,
  typedExtractRequest,
} from "../_shared/doc_ocr.ts";

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

// A MyKad read straight off GET.ocr's own position reader (POST /v1/extract type
// "mykad"), mapped to the fields ekyc_apply stores, or null when its reader did
// not follow the card or GET.ocr is absent — then GET.eKYC's own extraction is
// kept. A short timeout caps GET.ocr falling back to its slow model. Mirrors
// id-read's readProfileMykad; the verdict stays GET.eKYC's, only the fields move.
async function readMykadFields(providers: unknown, image: Uint8Array): Promise<MyKadFields | null> {
  const server = ocrServer(providers);
  if (!server) return null;
  try {
    const r = typedExtractRequest(server, base64(image), "mykad");
    const res = await fetch(r.url, {
      method: r.method,
      headers: r.headers,
      body: r.body,
      signal: AbortSignal.timeout(OCR_TYPED_EXTRACT_TIMEOUT_MS),
    });
    const read = readTypedExtract(res.status, await res.json().catch(() => null));
    if ("error" in read) {
      console.log(`ekyc-webhook: mykad extract: ${read.error}`);
      return null;
    }
    const m = mykadFromExtract(read.readBy, read.fields);
    return m ? { name: m.name, ic: m.ic, birth: m.birth, gender: m.gender, nationality: m.nationality, address: m.address } : null;
  } catch (e) {
    console.log(`ekyc-webhook: mykad extract: ${e instanceof Error ? e.message : e}`);
    return null;
  }
}

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
    const copy = async (kind: string): Promise<{ url: string; bytes: Uint8Array } | null> => {
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
      // The bucket's public-form URL (the same shape the rider-verify face match
      // stores), so the admin review screens and the profile can sign and show
      // it; ekyc_apply still binds it to the person (ekyc_photo_bound). The bytes
      // are kept so GET.ocr can read a MyKad off the front without fetching again.
      return { url: db.storage.from("ID_Image").getPublicUrl(path).data.publicUrl, bytes };
    };
    const front = await copy("document_front");
    if (!front) throw new Error("no document photo");
    const back = await copy("document_back");
    const selfie = await copy("selfie");

    // GET.ocr reads a MyKad's fields by position (migration 0447's switch),
    // keeping a two-line name and the address intact where GET.eKYC's own
    // extraction cuts them; GET.eKYC keeps the verdict, face match and liveness.
    // Only when GET.eKYC classified the document a MyKad and the admin switched
    // the reader on — off by default, so GET.eKYC's fields are used as before.
    let mykad: MyKadFields | null = null;
    const extracted = ((v.result ?? {}) as Record<string, unknown>).extracted;
    if (
      docTypeOf((extracted ?? {}) as Record<string, unknown>) === "mykad" &&
      mykadReaderOn(await setting("document_reading"))
    ) {
      mykad = await readMykadFields(providers, front.bytes);
    }

    const { error } = await db.rpc("ekyc_apply", {
      p_session: session.id,
      p: applyPayload(v, { front: front.url, back: back?.url ?? null, selfie: selfie?.url ?? null }, mykad),
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
