// ============================================================================
// face-compare — Supabase Edge Function
// ----------------------------------------------------------------------------
// Admin → Documents → Sign-in checks (migrations 0281, 0283): how alike a
// selfie and the person's ID photo are, as a score that helps the admin
// decide. Never an approval. Only for an admin who edits a Documents page.
// Who scores it is the admin's setting: AWS Rekognition, the self-hosted face
// server, the server then AWS, or nobody. The keys are read here from Admin →
// API Keys (AWS → Rekognition, Face match server) with the service role and
// never returned; without a usable one the answer is "not_checked" with the
// reason. See _shared/face_compare.ts and _shared/face_server.ts.
//
// Request:  POST { check_id } with the admin's session token.
// Response: 200 { state: "match" | "no_match" | "no_face" | "not_checked" | "error",
//                 score?, provider?: "aws" | "self_hosted", fell_back?, reason?, detail? }
//           400 bad_request · 401 not_signed_in · 403 not_authorized
//           404 not_found · 503 unavailable
//
// Partner registration (0288): POST { document: { kind, id } } compares one
// document with the person's photo (National ID, Kad Pemandu, a Required
// Document marked "Has the person's photo") against their newest live
// selfie, asked by the database (x-push-secret) or an admin, and keeps the
// score per document (document_face_checks).
//
// Going online (0290): POST { online_check: { id } } compares a partner's
// live selfie with their profile photo and ID photo, asked by the database
// (x-push-secret) or an admin, and keeps the better score
// (online_selfie_check_store), which alerts on a low match.
//
// Deploy: supabase functions deploy face-compare
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { callerCanEditHere } from "../_shared/admin_page.ts";
import { signedJsonPost } from "../_shared/aws_sigv4.ts";
import {
  base64,
  type CheckRow,
  DOCUMENT_FACE_PAGES,
  DOCUMENT_PAGES,
  documentRequest,
  type FaceProvider,
  type FaceState,
  handleDocumentFaceCompare,
  handleFaceCompare,
  handleOnlineFaceCompare,
  ONLINE_FACE_PAGES,
  type Result,
  storageObject,
} from "../_shared/face_compare.ts";
import { compareRequest, FACE_SERVER_TIMEOUT_MS } from "../_shared/face_server.ts";
import { type IdFull, MAX_IMAGE_BYTES, readIdFull, readVision, visionKey, visionRequest } from "../_shared/id_read.ts";

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

async function download(bucket: string, path: string): Promise<Uint8Array | null> {
  const { data, error } = await db.storage.from(bucket).download(path);
  if (error || !data) return null;
  return new Uint8Array(await data.arrayBuffer());
}

async function awsCompare(key: Parameters<typeof signedJsonPost>[0], source: Uint8Array, target: Uint8Array) {
  const body = JSON.stringify({
    SourceImage: { Bytes: base64(source) },
    TargetImage: { Bytes: base64(target) },
    SimilarityThreshold: 0,
  });
  const signed = await signedJsonPost(key, "rekognition", "RekognitionService.CompareFaces", body);
  const res = await fetch(signed.url, { method: "POST", headers: signed.headers, body, signal: AbortSignal.timeout(15000) });
  return { status: res.status, body: await res.json().catch(() => null) };
}

async function serverCompare(server: Parameters<typeof compareRequest>[0], selfie: Uint8Array, card: Uint8Array) {
  const r = compareRequest(server, selfie, card);
  const res = await fetch(r.url, {
    method: r.method,
    headers: r.headers,
    body: r.body,
    signal: AbortSignal.timeout(FACE_SERVER_TIMEOUT_MS),
  });
  return { status: res.status, body: await res.json().catch(() => null) };
}

// ---- Rider ID verification (migrations 0342 / 0343) ----------------------------------------------
// A rider self-verifies before booking: they upload their ID photo and a live
// selfie, and this scores the two server-side (the admin face pipeline, keys
// never leaving the server) and applies the auto-verify policy. The score is
// ALWAYS computed here, never taken from the client, and only the rider's own
// `rider_gate` check is ever scored.
async function saveScore(
  id: string,
  state: FaceState,
  score: number | null,
  provider: FaceProvider | null,
  reason: string | null,
) {
  const { error } = await db.from("identity_checks").update({
    face_state: state,
    face_score: score,
    face_provider: provider,
    face_reason: reason,
    face_checked_at: new Date().toISOString(),
  }).eq("id", id);
  if (error) throw error;
}

const riderText = (v: unknown, max: number): string | null => {
  const s = typeof v === "string" ? v.trim() : "";
  return s ? s.slice(0, max) : null;
};
const riderDate = (v: unknown): string | null => {
  const s = typeof v === "string" ? v.trim() : "";
  return /^\d{4}-\d{2}-\d{2}$/.test(s) ? s : null;
};
const riderNationality = (v: unknown): string | null => {
  const s = typeof v === "string" ? v.trim().toUpperCase() : "";
  return /^[A-Z]{3}$/.test(s) ? s : null;
};
const riderGender = (v: unknown): string | null =>
  v === "male" || v === "female" || v === "other" ? v : null;

/**
 * Re-reads the ID image on the server with Google Vision — the TRUSTED read,
 * since a client could lie about the name / DOB / gender it sends. Null when
 * Vision isn't configured, the image is missing/too big, or nothing was read;
 * the caller then falls back to the client's values.
 */
async function serverReadId(idFrontUrl: string): Promise<IdFull | null> {
  try {
    const key = visionKey(await setting("api_providers"));
    if (!key) return null;
    const where = storageObject(idFrontUrl);
    const image = where ? await download(where.bucket, where.path) : null;
    if (!image || image.length > MAX_IMAGE_BYTES) return null;
    const rq = visionRequest(key, image);
    const res = await fetch(rq.url, {
      method: rq.method,
      headers: rq.headers,
      body: rq.body,
      signal: AbortSignal.timeout(15000),
    });
    const v = readVision(res.status, await res.json().catch(() => null));
    if ("error" in v || !v.text.trim()) return null;
    const full = readIdFull(v.text);
    const found = full.name || full.ic || full.passport || full.birth || full.gender || full.nationality ||
      full.address;
    return found ? full : null;
  } catch {
    return null;
  }
}

async function handleRiderVerify(body: unknown, authorization: string | null): Promise<Result> {
  if (!authorization) return { status: 401, body: { error: "not_signed_in" } };
  const b = (body ?? {}) as Record<string, unknown>;
  const idFrontUrl = typeof b.idFrontUrl === "string" ? b.idFrontUrl : null;
  const selfieUrl = typeof b.selfieUrl === "string" ? b.selfieUrl : null;
  if (!idFrontUrl || !selfieUrl) return { status: 400, body: { error: "bad_request" } };
  const read = (b.read ?? {}) as Record<string, unknown>;

  // Who is asking — resolved from the token, never from the body.
  const user = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_ANON_KEY") ?? "",
    { global: { headers: { Authorization: authorization } }, auth: { persistSession: false, autoRefreshToken: false } },
  );
  const { data: who, error: whoErr } = await user.auth.getUser();
  const rider = who?.user?.id;
  if (whoErr || !rider) return { status: 401, body: { error: "not_signed_in" } };

  // Re-read the ID server-side (Vision). The server read WINS for every field
  // it could read — a client value only fills a field the server missed, or
  // stands in entirely when Vision isn't configured (read_source 'phone').
  const srv = await serverReadId(idFrontUrl);

  // Record the submission (service role).
  const { data: idRow, error: idErr } = await db.from("identity_checks").insert({
    user_id: rider,
    kind: "id",
    purpose: "rider_gate",
    file_url: idFrontUrl,
    status: "Pending Review",
    read_source: srv ? "vision" : "phone",
    read_name: riderText(srv?.name ?? read.name, 120),
    read_ic: riderText(srv?.ic ?? read.ic, 40),
    read_expiry: riderDate(srv?.expiry ?? read.expiry),
    read_birth: riderDate(srv?.birth ?? read.birth),
    read_nationality: riderNationality(srv?.nationality ?? read.nationality),
    read_gender: riderGender(srv?.gender ?? read.gender),
    read_address: riderText(srv?.address ?? read.address, 300),
  }).select("id").single();
  if (idErr || !idRow) return { status: 500, body: { error: "insert_failed" } };
  const idCheckId = idRow.id as string;
  await db.from("identity_checks").insert({
    user_id: rider,
    kind: "selfie",
    purpose: "rider_gate",
    file_url: selfieUrl,
    status: "Pending Review",
  });

  // Score the rider's own check with the admin face pipeline (service role);
  // canReview is scoped to this rider's rider_gate check, not an admin page.
  const scored = await handleFaceCompare({ check_id: idCheckId }, authorization, {
    async canReview() {
      const { data } = await db.from("identity_checks").select("user_id, purpose").eq("id", idCheckId).maybeSingle();
      return !!data && data.user_id === rider && data.purpose === "rider_gate";
    },
    async check(id) {
      const { data, error } = await db.from("identity_checks").select("id, user_id, kind, file_url")
        .eq("id", id).maybeSingle();
      if (error) throw error;
      return (data as CheckRow | null) ?? null;
    },
    async counterpart(row) {
      const { data, error } = await db.from("identity_checks").select("id, user_id, kind, file_url")
        .eq("user_id", row.user_id).eq("kind", row.kind === "selfie" ? "id" : "selfie").eq("purpose", "rider_gate")
        .neq("status", "Rejected").order("created_at", { ascending: false }).limit(1).maybeSingle();
      if (error) throw error;
      return (data as CheckRow | null) ?? null;
    },
    apiProviders: () => setting("api_providers"),
    verifySettings: () => setting("dispatch_verify"),
    download,
    compare: awsCompare,
    compareSelfHosted: serverCompare,
    save: saveScore,
  });

  // Apply the auto-verify policy — reads only the score just saved above.
  let verified = false;
  let pending = true;
  try {
    const { data: applied, error: applyErr } = await db.rpc("rider_id_gate_apply", { p_check: idCheckId });
    if (!applyErr && applied) {
      verified = (applied as Record<string, unknown>).verified === true;
      pending = (applied as Record<string, unknown>).pending === true;
    }
  } catch {
    // Leave the rider pending; an admin will review the check.
  }

  const sb = (scored.body ?? {}) as Record<string, unknown>;
  return { status: 200, body: { verified, pending, state: sb.state ?? null, score: sb.score ?? null } };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);

  const input = await req.json().catch(() => null);
  if ((input as { rider_verify?: unknown } | null)?.rider_verify !== undefined) {
    const r = await handleRiderVerify((input as { rider_verify?: unknown }).rider_verify, req.headers.get("Authorization"));
    return reply(r.body, r.status);
  }
  if ((input as { online_check?: unknown } | null)?.online_check !== undefined) {
    const online = await handleOnlineFaceCompare(input, {
      authorization: req.headers.get("Authorization"),
      secret: req.headers.get("x-push-secret"),
    }, {
      async webhookSecretOk(secret) {
        const { data, error } = await db.rpc("push_webhook_secret_ok", { p_secret: secret });
        if (error) console.log("[face-compare] secret check:", error.message);
        return data === true;
      },
      canReview: (authorization) => callerCanEditHere(authorization, ONLINE_FACE_PAGES),
      async source(id) {
        const { data, error } = await db.rpc("online_selfie_face_source", { p_id: id });
        if (error) throw error;
        return data ?? null;
      },
      apiProviders: () => setting("api_providers"),
      verifySettings: () => setting("dispatch_verify"),
      download,
      compare: awsCompare,
      compareSelfHosted: serverCompare,
      async store(id, result) {
        const { error } = await db.rpc("online_selfie_check_store", { p_id: id, p: result });
        if (error) throw error;
      },
    });
    return reply(online.body, online.status);
  }
  if (documentRequest(input) !== null || (input as { document?: unknown } | null)?.document !== undefined) {
    const doc = await handleDocumentFaceCompare(input, {
      authorization: req.headers.get("Authorization"),
      secret: req.headers.get("x-push-secret"),
    }, {
      async webhookSecretOk(secret) {
        const { data, error } = await db.rpc("push_webhook_secret_ok", { p_secret: secret });
        if (error) console.log("[face-compare] secret check:", error.message);
        return data === true;
      },
      canReview: (authorization) => callerCanEditHere(authorization, DOCUMENT_FACE_PAGES),
      async source(kind, id) {
        const { data, error } = await db.rpc("document_face_check_source", { p_kind: kind, p_id: id });
        if (error) throw error;
        return data ?? null;
      },
      apiProviders: () => setting("api_providers"),
      verifySettings: () => setting("dispatch_verify"),
      download,
      compare: awsCompare,
      compareSelfHosted: serverCompare,
      async store(kind, id, state, score, provider, reason, selfieUrl) {
        const { error } = await db.rpc("document_face_check_store", {
          p_kind: kind, p_id: id, p_state: state, p_score: score, p_provider: provider, p_reason: reason,
          p_selfie: selfieUrl,
        });
        if (error) throw error;
      },
    });
    return reply(doc.body, doc.status);
  }

  const result = await handleFaceCompare(input, req.headers.get("Authorization"), {
    canReview: (authorization) => callerCanEditHere(authorization, DOCUMENT_PAGES),
    async check(id) {
      const { data, error } = await db.from("identity_checks").select("id, user_id, kind, file_url")
        .eq("id", id).maybeSingle();
      if (error) throw error;
      return (data as CheckRow | null) ?? null;
    },
    async counterpart(row) {
      // The ID's front for a selfie; for an ID the newest selfie, else nothing.
      const { data, error } = await db.from("identity_checks").select("id, user_id, kind, file_url")
        .eq("user_id", row.user_id).eq("kind", row.kind === "selfie" ? "id" : "selfie")
        .neq("purpose", "profile").neq("status", "Rejected")
        .order("created_at", { ascending: false }).limit(1).maybeSingle();
      if (error) throw error;
      return (data as CheckRow | null) ?? null;
    },
    async apiProviders() {
      const { data, error } = await db.from("app_settings").select("value").eq("key", "api_providers").maybeSingle();
      if (error) throw error;
      return data?.value ?? null;
    },
    async verifySettings() {
      const { data, error } = await db.from("app_settings").select("value").eq("key", "dispatch_verify").maybeSingle();
      if (error) throw error;
      return data?.value ?? null;
    },
    async download(bucket, path) {
      const { data, error } = await db.storage.from(bucket).download(path);
      if (error || !data) return null;
      return new Uint8Array(await data.arrayBuffer());
    },
    async compare(key, source, target) {
      const body = JSON.stringify({
        SourceImage: { Bytes: base64(source) },
        TargetImage: { Bytes: base64(target) },
        SimilarityThreshold: 0,
      });
      const signed = await signedJsonPost(key, "rekognition", "RekognitionService.CompareFaces", body);
      const res = await fetch(signed.url, {
        method: "POST",
        headers: signed.headers,
        body,
        signal: AbortSignal.timeout(15000),
      });
      return { status: res.status, body: await res.json().catch(() => null) };
    },
    async compareSelfHosted(server, selfie, card) {
      const r = compareRequest(server, selfie, card);
      const res = await fetch(r.url, {
        method: r.method,
        headers: r.headers,
        body: r.body,
        signal: AbortSignal.timeout(FACE_SERVER_TIMEOUT_MS),
      });
      return { status: res.status, body: await res.json().catch(() => null) };
    },
    async save(id, state, score, provider, reason) {
      const { error } = await db.from("identity_checks").update({
        face_state: state,
        face_score: score,
        face_provider: provider,
        face_reason: reason,
        face_checked_at: new Date().toISOString(),
      }).eq("id", id);
      if (error) throw error;
    },
  });
  return reply(result.body, result.status);
});
