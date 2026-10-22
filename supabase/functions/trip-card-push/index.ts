// ============================================================================
// trip-card-push — Supabase Edge Function
// ----------------------------------------------------------------------------
// Moves the trip card on the Android phones of a ride's rider and driver
// while the app is closed (migration 0274): the database calls it when a
// ride's status changes, and for the driver's position at most every 30
// seconds per ride. It builds the card here (_shared/trip_card.ts, the same
// card as lib/src/core/trip_card.dart) and sends each phone an FCM data
// message that TripCardPushReceiver.kt applies. See
// _shared/trip_card_push.ts.
//
//   POST { rideId, formerPartnerId? }  ->  { sent, failed, pruned }
//
// Callers: the database (`x-push-secret`, the push webhook's existing Vault
// secret, checked by push_webhook_secret_ok) or the service role.
//
// Secrets: FCM_SERVICE_ACCOUNT (the Firebase service account JSON send-push
// already uses). Without it nothing is sent.
//
// Deploy (the database carries no user JWT; every caller is checked here):
//   supabase functions deploy trip-card-push --no-verify-jwt
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { googleAccessToken } from "../_shared/google_auth.ts";
import { FCM_SCOPE, fcmOutcome, fcmSendUrl, parseServiceAccount } from "../_shared/push.ts";
import { livePushAuthDeps } from "../_shared/push_auth.ts";
import { handleTripCardPush, type TokenRow, type TripCardSnapshot } from "../_shared/trip_card_push.ts";

const url = Deno.env.get("SUPABASE_URL") ?? "";
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SERVICE_ROLE_KEY") ?? "";
const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });

// The FCM access token lasts an hour; a warm instance reuses it rather than
// signing a new one for every position update.
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
    return await handleTripCardPush(req, {
      auth: livePushAuthDeps({ url, anonKey: Deno.env.get("SUPABASE_ANON_KEY") ?? "", serviceKey }),
      async snapshot(rideId) {
        const { data, error } = await db.rpc("trip_card_push_snapshot", { p_ride: rideId });
        if (error) {
          console.log("[trip-card-push] snapshot:", error.message);
          return null;
        }
        return (data ?? null) as TripCardSnapshot | null;
      },
      async tokens(profileIds) {
        const { data, error } = await db
          .from("push_tokens")
          .select("token, platform, profile_id, mode")
          .in("profile_id", profileIds)
          .eq("platform", "android")
          .order("token", { ascending: true });
        if (error) {
          console.log("[trip-card-push] tokens:", error.message);
          return [];
        }
        return (data ?? []) as TokenRow[];
      },
      async send(message) {
        let creds: { token: string; projectId: string } | null;
        try {
          creds = await fcmCredentials();
        } catch (e) {
          console.log("[trip-card-push] FCM credentials:", String(e instanceof Error ? e.message : e));
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
        if (error) console.log("[trip-card-push] prune:", error.message);
      },
      now: () => new Date(),
    });
  } catch (e) {
    console.error("[trip-card-push] failed", e);
    return new Response(JSON.stringify({ error: "Unexpected error" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
