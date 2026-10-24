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
// Deploy: supabase functions deploy id-read
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { callerCanEditHere } from "../_shared/admin_page.ts";
import { DOCUMENT_PAGES, handleIdRead, type IdCheckRow, visionRequest } from "../_shared/id_read.ts";

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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);

  const result = await handleIdRead(await req.json().catch(() => null), req.headers.get("Authorization"), {
    async caller(authorization) {
      const token = /^Bearer\s+(.+)$/i.exec((authorization ?? "").trim())?.[1]?.trim();
      if (!token) return null;
      const { data, error } = await db.auth.getUser(token);
      if (error || !data?.user) return null;
      return data.user.id;
    },
    canReview: (authorization) => callerCanEditHere(authorization, DOCUMENT_PAGES),
    async check(id) {
      const { data, error } = await db.from("identity_checks")
        .select("id, user_id, kind, file_url, status, read_source").eq("id", id).maybeSingle();
      if (error) throw error;
      return (data as IdCheckRow | null) ?? null;
    },
    verifySettings: () => setting("dispatch_verify"),
    apiProviders: () => setting("api_providers"),
    async download(bucket, path) {
      const { data, error } = await db.storage.from(bucket).download(path);
      if (error || !data) return null;
      return new Uint8Array(await data.arrayBuffer());
    },
    async annotate(key, image) {
      const r = visionRequest(key, image);
      const res = await fetch(r.url, {
        method: r.method,
        headers: r.headers,
        body: r.body,
        signal: AbortSignal.timeout(20000),
      });
      return { status: res.status, body: await res.json().catch(() => null) };
    },
    async store(id, read) {
      const { data, error } = await db.rpc("identity_check_store_read", { p_id: id, p: read });
      if (error) throw error;
      return (data ?? {}) as Record<string, unknown>;
    },
  });
  return reply(result.body, result.status);
});
