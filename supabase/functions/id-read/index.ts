// ============================================================================
// id-read — Supabase Edge Function
// ----------------------------------------------------------------------------
// Sign-in checks (migration 0283): Google Cloud Vision reads the front of a
// MyKad or passport sent for review, when the phone couldn't read it (or on
// web and desktop), or always, as the admin's ID card reading setting says;
// and "Read card again" in Admin → Documents → Sign-in checks. What was read
// is kept on the check and checked against the profile again. The person may
// ask for their own ID once while it waits for review; an admin who edits a
// Documents page for anyone's. The key is read here from Admin → API Keys
// (Google → Cloud Vision (ID reading)) with the service role and never
// returned. See _shared/id_read.ts.
//
// Request:  POST { check_id } with the caller's session token.
// Response: 200 { state: "read" | "not_read" | "error", name?, ic?, passport?,
//                 expiry?, mismatch?, reason?, detail? }
//           400 bad_request · not_an_id · 401 not_signed_in
//           403 not_authorized · vision_off · 404 not_found
//           409 not_waiting · already_read · 503 unavailable
//
// Partner registration (0288): POST { file_url, purpose: "registration" }
// returns the text of the person's own registration document (National ID,
// SSM document, Kad Pemandu, vehicle grant) for the app to read, at most 30
// a day, unless ID card reading is "On the phone only".
//
// Admin ID review (0345): POST { profile_id } with an admin session reads
// that profile's ID image with Vision and returns the full field set
// { state, name?, ic?, birth?, gender?, nationality?, address?, expiry? } so
// the reviewer can compare it with the keyed values. Writes nothing.
//
// The office NAS (0320): with the NAS before Google Vision in Admin's ID card
// reading order, the person's own read answers { state: "not_read",
// reason: "nas" } while the NAS has the ID; what the NAS can't read the
// database hands on: POST { check_id, by: "database" } with x-push-secret.
//
// Deploy: supabase functions deploy id-read
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { callerCanEditHere } from "../_shared/admin_page.ts";
import { storageObject } from "../_shared/face_compare.ts";
import {
  DOCUMENT_PAGES,
  handleIdRead,
  handleRegistrationRead,
  type IdCheckRow,
  isRegistrationRead,
  MAX_IMAGE_BYTES,
  readIdFull,
  readVision,
  visionKey,
  visionRequest,
} from "../_shared/id_read.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "7200",
};

const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });

const db = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});

async function setting(key: string): Promise<unknown> {
  const { data, error } = await db.from("app_settings").select("value").eq("key", key).maybeSingle();
  if (error) throw error;
  return data?.value ?? null;
}

async function callerId(authorization: string | null): Promise<string | null> {
  const token = /^Bearer\s+(.+)$/i.exec((authorization ?? "").trim())?.[1]?.trim();
  if (!token) return null;
  const { data, error } = await db.auth.getUser(token);
  if (error || !data?.user) return null;
  return data.user.id;
}

async function download(bucket: string, path: string): Promise<Uint8Array | null> {
  const { data, error } = await db.storage.from(bucket).download(path);
  if (error || !data) return null;
  return new Uint8Array(await data.arrayBuffer());
}

async function annotate(key: string, image: Uint8Array) {
  const r = visionRequest(key, image);
  const res = await fetch(r.url, { method: r.method, headers: r.headers, body: r.body, signal: AbortSignal.timeout(20000) });
  return { status: res.status, body: await res.json().catch(() => null) };
}

// Admin → People → User ID Documents: read a profile's ID image with Vision
// so the reviewer can compare the read fields with what the user keyed and
// pick per field which to keep. Admin-only; reads nothing but the image, and
// writes nothing (no check row, no profile change).
async function profileIdImage(profileId: string): Promise<string | null> {
  const { data, error } = await db.from("profiles").select("id_image").eq("id", profileId).maybeSingle();
  if (error) throw error;
  const v = data?.id_image;
  return typeof v === "string" && v.length > 0 ? v : null;
}

async function handleProfileRead(
  profileId: string,
  authorization: string | null,
): Promise<{ body: Record<string, unknown>; status: number }> {
  if (!/^[0-9a-f-]{36}$/i.test(profileId)) return { body: { error: "bad_request" }, status: 400 };
  const allowed = await callerCanEditHere(authorization, DOCUMENT_PAGES);
  if (allowed === null) return { body: { error: "not_signed_in" }, status: 401 };
  if (!allowed) return { body: { error: "not_authorized" }, status: 403 };

  const url = await profileIdImage(profileId);
  if (!url) return { body: { state: "not_read", reason: "no_image" }, status: 200 };
  const key = visionKey(await setting("api_providers"));
  if (!key) return { body: { state: "not_read", reason: "vision_off" }, status: 200 };
  const where = url.length <= 1000 ? storageObject(url) : null;
  const image = where ? await download(where.bucket, where.path) : null;
  if (!image) return { body: { state: "not_read", reason: "no_image" }, status: 200 };
  if (image.length > MAX_IMAGE_BYTES) return { body: { state: "not_read", reason: "too_big" }, status: 200 };

  const ann = await annotate(key, image);
  const v = readVision(ann.status, ann.body);
  if ("error" in v) return { body: { state: "error", reason: v.error }, status: 200 };
  if (!v.text.trim()) return { body: { state: "not_read", reason: "no_text" }, status: 200 };

  const full = readIdFull(v.text);
  return {
    body: {
      state: "read",
      name: full.name,
      ic: full.ic,
      birth: full.birth,
      gender: full.gender,
      nationality: full.nationality,
      address: full.address,
      expiry: full.expiry,
    },
    status: 200,
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);

  const input = await req.json().catch(() => null);
  const profileId = (input as { profile_id?: unknown } | null)?.profile_id;
  if (typeof profileId === "string") {
    const r = await handleProfileRead(profileId, req.headers.get("Authorization"));
    return reply(r.body, r.status);
  }
  if (isRegistrationRead(input)) {
    const r = await handleRegistrationRead(input, req.headers.get("Authorization"), {
      caller: callerId,
      async owns(uid, bucket, path) {
        const { data, error } = await db.rpc("registration_file_owned", { p_uid: uid, p_bucket: bucket, p_path: path });
        if (error) throw error;
        return data === true;
      },
      async spend(uid, limit) {
        const { data, error } = await db.rpc("registration_text_read_spend", { p_user: uid, p_limit: limit });
        if (error) throw error;
        return data === true;
      },
      verifySettings: () => setting("dispatch_verify"),
      apiProviders: () => setting("api_providers"),
      download,
      annotate,
    });
    return reply(r.body, r.status);
  }

  const result = await handleIdRead(input, req.headers.get("Authorization"), {
    caller: callerId,
    canReview: (authorization) => callerCanEditHere(authorization, DOCUMENT_PAGES),
    async check(id) {
      const { data, error } = await db.from("identity_checks")
        .select("id, user_id, kind, file_url, status, read_source").eq("id", id).maybeSingle();
      if (error) throw error;
      return (data as IdCheckRow | null) ?? null;
    },
    verifySettings: () => setting("dispatch_verify"),
    apiProviders: () => setting("api_providers"),
    download,
    annotate,
    async store(id, read) {
      const { data, error } = await db.rpc("identity_check_store_read", { p_id: id, p: read });
      if (error) throw error;
      return (data ?? {}) as Record<string, unknown>;
    },
    async nasReading(id) {
      const { data, error } = await db.rpc("identity_nas_reading", { p_check: id });
      if (error) console.log("[id-read] nas:", error.message);
      return data === true;
    },
    async webhookSecretOk(secret) {
      const { data, error } = await db.rpc("push_webhook_secret_ok", { p_secret: secret });
      if (error) console.log("[id-read] secret check:", error.message);
      return data === true;
    },
  }, req.headers.get("x-push-secret"));
  return reply(result.body, result.status);
});
