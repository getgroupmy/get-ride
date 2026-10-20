// ============================================================================
// dispatch-account — Supabase Edge Function
// ----------------------------------------------------------------------------
// Order dispatch IDs (migration 0251): an admin makes a stand admin or a
// fleet owner, a stand admin makes their staff — by phone number. A number
// with no account gets one (phone confirmed, no password); they choose their
// own PIN on first sign-in through the usual SMS code. A number with an
// account is just given the role. The rules are the database's
// (dispatch_may_grant / dispatch_grant); see _shared/dispatch_account.ts.
//
// Request:  POST { kind: "stand_admin" | "staff" | "fleet_owner", name, phone,
//                  stand_ids?: uuid[], group_id?: uuid, perms?: {assign, ...} }
//           with the caller's session token.
// Response: 200 { user_id, created }
//           400 bad_request · 401 not_signed_in · 403 not_authorized
//           409 { error: "DISPATCH_..." } · 503 unavailable
//
// Deploy: supabase functions deploy dispatch-account
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleDispatchAccount } from "../_shared/dispatch_account.ts";

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

  const admin = createClient(url, serviceKey, noSession);
  const result = await handleDispatchAccount(body, req.headers.get("authorization"), {
    async caller(authorization) {
      const token = /^Bearer\s+(.+)$/i.exec((authorization ?? "").trim())?.[1]?.trim();
      if (!token) return null;
      const anon = createClient(url, anonKey, noSession);
      const { data, error } = await anon.auth.getUser(token);
      if (error || !data.user) return null;
      return data.user.id;
    },
    async mayGrant(caller, r) {
      const { data, error } = await admin.rpc("dispatch_may_grant", {
        p_caller: caller,
        p_kind: r.kind,
        p_stand_ids: r.stand_ids,
        p_group: r.group_id,
      });
      if (error) throw new Error(error.message);
      return data === true;
    },
    async userByPhone(phone) {
      const { data, error } = await admin.rpc("dispatch_profile_by_phone", { p_phone: phone });
      if (error) throw new Error(error.message);
      return typeof data === "string" && data ? data : null;
    },
    async createUser(phone) {
      const { data, error } = await admin.auth.admin.createUser({ phone, phone_confirm: true });
      if (error || !data.user) throw new Error(error?.message ?? "create failed");
      return data.user.id;
    },
    async grant(caller, user, r) {
      const { data, error } = await admin.rpc("dispatch_grant", {
        p_caller: caller,
        p_user: user,
        p_kind: r.kind,
        p_name: r.name,
        p_phone: r.phone,
        p_stand_ids: r.stand_ids,
        p_group: r.group_id,
        p_perms: r.perms,
      });
      if (error) throw new Error(error.message);
      return data;
    },
  });
  return json(result.body, result.status);
});
