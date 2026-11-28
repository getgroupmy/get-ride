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
// Deploy: supabase functions deploy id-read --no-verify-jwt (the database
// calls it without a user token; see supabase/config.toml)
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
import { base64, type FaceServer } from "../_shared/face_server.ts";
import {
  handleOcrRead,
  isMyKadNumber,
  isOcrReader,
  type MyKadRead,
  mykadFromExtract,
  mykadReaderOn,
  OCR_TIMEOUT_MS,
  OCR_TYPED_EXTRACT_TIMEOUT_MS,
  ocrRequest,
  ocrServer,
  readOcr,
  readTypedExtract,
  serverReaders,
  typedExtractRequest,
} from "../_shared/doc_ocr.ts";

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

// get.ocr (0443): POST the registration document to our own OCR server.
async function ocrCall(server: FaceServer, image: Uint8Array) {
  const r = ocrRequest(server, image);
  const res = await fetch(r.url, {
    method: r.method,
    headers: r.headers,
    body: r.body,
    signal: AbortSignal.timeout(OCR_TIMEOUT_MS),
  });
  return { status: res.status, body: await res.json().catch(() => null) };
}

// Admin → People → User ID Documents: a profile's ID image and the keyed IC
// (the IC's MyKad shape gates reading the card by position). Admin-only; reads
// nothing but the image, and writes nothing (no check row, no profile change).
async function profileIdDoc(profileId: string): Promise<{ url: string; ic: string | null } | null> {
  const { data, error } = await db.from("profiles").select("id_image, ic").eq("id", profileId).maybeSingle();
  if (error) throw error;
  const url = data?.id_image;
  if (typeof url !== "string" || url.length === 0) return null;
  return { url, ic: typeof data?.ic === "string" ? data.ic : null };
}

// A sign-in check's owner profile's keyed IC (its MyKad shape gates reading that
// person's card by position in the sign-in path, migration 0447). The check row
// carries no IC; this reads only the one column, and writes nothing.
async function profileIc(userId: string): Promise<string | null> {
  const { data, error } = await db.from("profiles").select("ic").eq("id", userId).maybeSingle();
  if (error) throw error;
  return typeof data?.ic === "string" ? data.ic : null;
}

// A MyKad read straight off GET.ocr's own position reader (POST /v1/extract
// type "mykad"), or null when its reader did not follow the card or GET.ocr is
// absent — then the text readers run. A short timeout caps GET.ocr falling back
// to its slow model on a picture its reader can't follow.
async function readProfileMykad(apiProviders: unknown, image: Uint8Array): Promise<MyKadRead | null> {
  const server = ocrServer(apiProviders);
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
      console.log(`[id-read] mykad extract: ${read.error}`);
      return null;
    }
    return mykadFromExtract(read.readBy, read.fields);
  } catch (e) {
    console.log(`[id-read] mykad extract: ${e instanceof Error ? e.message : e}`);
    return null;
  }
}

/** The read ID fields as the admin review tool shows them. */
function profileFields(text: string): { body: Record<string, unknown>; status: number } {
  const full = readIdFull(text);
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

async function handleProfileRead(
  profileId: string,
  authorization: string | null,
): Promise<{ body: Record<string, unknown>; status: number }> {
  if (!/^[0-9a-f-]{36}$/i.test(profileId)) return { body: { error: "bad_request" }, status: 400 };
  const allowed = await callerCanEditHere(authorization, DOCUMENT_PAGES);
  if (allowed === null) return { body: { error: "not_signed_in" }, status: 401 };
  if (!allowed) return { body: { error: "not_authorized" }, status: 403 };

  const doc = await profileIdDoc(profileId);
  if (!doc) return { body: { state: "not_read", reason: "no_image" }, status: 200 };
  const where = doc.url.length <= 1000 ? storageObject(doc.url) : null;
  const image = where ? await download(where.bucket, where.path) : null;
  if (!image) return { body: { state: "not_read", reason: "no_image" }, status: 200 };
  if (image.length > MAX_IMAGE_BYTES) return { body: { state: "not_read", reason: "too_big" }, status: 200 };

  const apiProviders = await setting("api_providers");
  const docReading = await setting("document_reading");

  // A MyKad is read by position off GET.ocr's own reader (no text parsing),
  // which keeps the address and a two-line name intact where the text path cuts
  // them. Only when the admin switched the MyKad reader on (Admin → Document
  // reading) and the keyed IC is a MyKad — off by default, because today's
  // GET.ocr still answers type "mykad" with the old reader that cuts two-line
  // names and misreads new-generation cards, so the switch (not the answer's
  // read_by) decides. Falls back to the text readers below when its reader did
  // not follow the card.
  if (mykadReaderOn(docReading) && isMyKadNumber(doc.ic)) {
    const mykad = await readProfileMykad(apiProviders, image);
    if (mykad) return { body: { state: "read", ...mykad }, status: 200 };
  }

  // get.ocr is the primary text reader; Google Vision is the fallback (0444).
  // The order follows Admin → Settings → Document reading, and Vision is tried
  // as a last resort so the review tool is never left with nothing.
  const order = serverReaders(docReading);
  let visionTried = false;
  let lastReason = "no_text";

  const tryOcr = async (): Promise<string | null> => {
    const server = ocrServer(apiProviders);
    if (!server) {
      lastReason = "ocr_off";
      return null;
    }
    const ans = await ocrCall(server, image);
    const v = readOcr(ans.status, ans.body);
    if ("error" in v) {
      lastReason = "ocr_down";
      return null;
    }
    if (!v.text.trim()) {
      lastReason = "no_text";
      return null;
    }
    return v.text;
  };

  const tryVision = async (): Promise<string | null> => {
    visionTried = true;
    const key = visionKey(apiProviders);
    if (!key) {
      lastReason = "vision_off";
      return null;
    }
    const ann = await annotate(key, image);
    const v = readVision(ann.status, ann.body);
    if ("error" in v) {
      lastReason = v.error;
      return null;
    }
    if (!v.text.trim()) {
      lastReason = "no_text";
      return null;
    }
    return v.text;
  };

  for (const rid of order) {
    const text = rid === "getOcr" ? await tryOcr() : await tryVision();
    if (text) return profileFields(text);
  }
  if (!visionTried) {
    const text = await tryVision();
    if (text) return profileFields(text);
  }
  return { body: { state: "not_read", reason: lastReason }, status: 200 };
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
    const authorization = req.headers.get("Authorization");
    const owns = async (uid: string, bucket: string, path: string) => {
      const { data, error } = await db.rpc("registration_file_owned", { p_uid: uid, p_bucket: bucket, p_path: path });
      if (error) throw error;
      return data === true;
    };
    const spend = async (uid: string, limit: number) => {
      const { data, error } = await db.rpc("registration_text_read_spend", { p_user: uid, p_limit: limit });
      if (error) throw error;
      return data === true;
    };
    // get.ocr reader (0443): our own OCR server in place of Google Vision.
    if (isOcrReader(input)) {
      const r = await handleOcrRead(input, authorization, {
        caller: callerId,
        owns,
        spend,
        apiProviders: () => setting("api_providers"),
        download,
        ocr: ocrCall,
      });
      return reply(r.body, r.status);
    }
    const r = await handleRegistrationRead(input, authorization, {
      caller: callerId,
      owns,
      spend,
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
    // get.ocr is the primary reader; Google Vision is the fallback (0444). The
    // order follows Admin → Settings → Document reading, shared with the admin
    // profile read; the sign-in gate above (Vision on) still decides whether the
    // person may ask the server at all.
    serverReaders: async () => serverReaders(await setting("document_reading")),
    async ocrText(image) {
      const server = ocrServer(await setting("api_providers"));
      if (!server) return null;
      const ans = await ocrCall(server, image);
      return readOcr(ans.status, ans.body);
    },
    // A MyKad is read by position off GET.ocr's own reader (no text parsing),
    // keeping a two-line name and the address intact, when the admin switched the
    // MyKad reader on (Admin → Document reading) and the check owner's keyed IC is
    // a MyKad — off by default, the switch (not the answer's read_by) deciding,
    // because today's GET.ocr still answers type "mykad" with the old reader.
    // Shared with the admin profile read (handleProfileRead); falls through to the
    // text readers when its reader did not follow the card.
    async mykadReaderWanted(userId) {
      if (!mykadReaderOn(await setting("document_reading"))) return false;
      return isMyKadNumber(await profileIc(userId));
    },
    async mykadRead(image) {
      const mykad = await readProfileMykad(await setting("api_providers"), image);
      return mykad ? { name: mykad.name, ic: mykad.ic, passport: null, expiry: mykad.expiry } : null;
    },
  }, req.headers.get("x-push-secret"));
  return reply(result.body, result.status);
});
