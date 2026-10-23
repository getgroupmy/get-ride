// ============================================================================
// location-ping — Supabase Edge Function
// ----------------------------------------------------------------------------
// "Still there?" (migration 0276): a silent push to "Always on" phones that
// have been quiet, which the app's native code answers with one location
// fix through push_background_location. The database decides who is due
// (location_ping_due every 5 minutes, God View's "Ping now" through
// god_view_ping) and calls this with the rows it claimed; this sends each
// one an FCM message (an iPhone a background push, Android a data-only high
// priority message). See _shared/location_ping.ts.
//
//   POST { tokenIds, reason }  ->  { sent, failed, pruned }
//
// Callers: the database (`x-push-secret`, the push webhook's existing Vault
// secret, checked by push_webhook_secret_ok) or the service role.
//
// Secrets: FCM_SERVICE_ACCOUNT (the Firebase service account JSON send-push
// already uses). Without it nothing is sent.
//
// Deploy (the database carries no user JWT; every caller is checked here):
//   supabase functions deploy location-ping --no-verify-jwt
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { googleAccessToken } from "../_shared/google_auth.ts";
import { handleLocationPing, type PingTarget } from "../_shared/location_ping.ts";
import { FCM_SCOPE, fcmOutcome, fcmSendUrl, parseServiceAccount } from "../_shared/push.ts";
import { livePushAuthDeps } from "../_shared/push_auth.ts";

const url = Deno.env.get("SUPABASE_URL") ?? "";
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SERVICE_ROLE_KEY") ?? "";
const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });

// The FCM access token lasts an hour; a warm instance reuses it.
let fcmAuth: { token: string; projectId: string; until: number } | null = null;

async function fcmCredentials(): Promise<{ token: string; projectId: string } | null> {
  if (fcmAuth && fcmAuth.until > Date.now()) return fcmAuth;
  const account = parseServiceAccount(Deno.env.get("FCM_SERVICE_ACCOUNT"));
  if (!account?.project_id) return null;
  const token = await googleAccessToken(
    { client_email: account.client_email!, private_key: account.private_key!, token_uri: account.token_uri },
    FCM_SCOPE,
  );
  fcmAuth = { token, projectId: account.project_id, until: Date.now() + 50 * 60 * 1000 };
  return fcmAuth;
}

Deno.serve(async (req) => {
  try {
    return await handleLocationPing(req, {
      auth: livePushAuthDeps({ url, anonKey: Deno.env.get("SUPABASE_ANON_KEY") ?? "", serviceKey }),
      async targets(ids) {
        const { data, error } = await db
          .rpc("location_ping_targets", { p_ids: ids })
          .order("id", { ascending: true });
        if (error) {
          console.log("[location-ping] targets:", error.message);
          return [];
        }
        return (data ?? []) as PingTarget[];
      },
      async send(message) {
        let creds: { token: string; projectId: string } | null;
        try {
          creds = await fcmCredentials();
        } catch (e) {
          console.log("[location-ping] FCM credentials:", String(e instanceof Error ? e.message : e));
          return "failed";
        }
        if (!creds) return "failed";
        const res = await fetch(fcmSendUrl(creds.projectId), {
          method: "POST",
          headers: { Authorization: `Bearer ${creds.token}`, "Content-Type": "application/json" },
          body: JSON.stringify(message),
        });
        const result = await res.json().catch(() => null);
        if (res.status === 401) fcmAuth = null;
        return fcmOutcome(res.status, result);
      },
      async prune(tokens) {
        const { error } = await db.from("push_tokens").delete().in("token", tokens);
        if (error) console.log("[location-ping] prune:", error.message);
      },
      now: () => new Date(),
    });
  } catch (e) {
    console.error("[location-ping] failed", e);
    return new Response(JSON.stringify({ error: "Unexpected error" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
