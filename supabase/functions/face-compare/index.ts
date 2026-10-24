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
// Deploy: supabase functions deploy face-compare
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { callerCanEditHere } from "../_shared/admin_page.ts";
import { signedJsonPost } from "../_shared/aws_sigv4.ts";
import { base64, type CheckRow, DOCUMENT_PAGES, handleFaceCompare } from "../_shared/face_compare.ts";
import { compareRequest, FACE_SERVER_TIMEOUT_MS } from "../_shared/face_server.ts";

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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);

  const result = await handleFaceCompare(await req.json().catch(() => null), req.headers.get("Authorization"), {
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
