// ============================================================================
// approver-upload — Supabase Edge Function (migration 0353)
// ----------------------------------------------------------------------------
// An approver with can_upload replaces the image of an in-scope document.
// Approvers cannot write the private document buckets from the app (storage
// RLS allows only the folder's owner or an admin), so the write runs here with
// the service role. Authorization stays in SQL: approver_upload_target checks
// the approver grant + approver_covers (as the caller) and returns the current
// image's URL; this overwrites that one storage object; approver_upload_commit
// reopens the document for review. It never creates a new document or path.
//
// Request:  POST { source: "partner"|"vehicle"|"identity", id: uuid,
//                  contentType: "image/...", data: <base64> }
//           with the caller's session token (JWT verified at the gateway).
// Response: 200 { ok } · 400 bad_request · 401 not_signed_in
//           403 not_authorized · 409 APPROVER_* · 422 · 502 upload_failed
//
// Deploy: supabase functions deploy approver-upload
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleApproverUpload } from "../_shared/approver_upload.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "7200",
};

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

const url = Deno.env.get("SUPABASE_URL") ?? "";
const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const noSession = { auth: { persistSession: false, autoRefreshToken: false } };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_request" }, 400);
  }

  const authorization = req.headers.get("authorization");
  // The RPCs run as the caller (so auth.uid() is the approver); the storage
  // write runs as the service role.
  const asCaller = createClient(url, anonKey, {
    ...noSession,
    global: { headers: { Authorization: authorization ?? "" } },
  });
  const admin = createClient(url, serviceKey, noSession);

  const result = await handleApproverUpload(body, authorization, {
    async target(source, id) {
      const { data, error } = await asCaller.rpc("approver_upload_target", { p_source: source, p_id: id });
      if (error) throw new Error(error.message);
      const fileUrl = (data as { file_url?: unknown } | null)?.file_url;
      if (typeof fileUrl !== "string") throw new Error("APPROVER_NO_IMAGE");
      return { file_url: fileUrl };
    },
    async upload(ref, bytes, contentType) {
      const { error } = await admin.storage.from(ref.bucket).upload(ref.path, bytes, { contentType, upsert: true });
      if (error) throw new Error(error.message);
    },
    async commit(source, id) {
      const { error } = await asCaller.rpc("approver_upload_commit", { p_source: source, p_id: id });
      if (error) throw new Error(error.message);
    },
  });
  return json(result.body, result.status);
});
