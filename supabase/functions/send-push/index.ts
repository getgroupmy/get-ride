// ============================================================================
// send-push — Supabase Edge Function
// ----------------------------------------------------------------------------
// Broadcasts a push notification to registered devices. Each stored token
// goes through the service that issued it:
//
//   * Expo push tokens (the Expo app) -> Expo's push service
//     (https://exp.host/--/api/v2/push/send);
//   * FCM registration tokens (the Flutter app) -> the FCM HTTP v1 API, which
//     reaches Android directly and iOS through the APNs key uploaded to the
//     Firebase project. Needs the FCM_SERVICE_ACCOUNT secret (the Firebase
//     project's service account JSON); without it FCM devices are counted as
//     failed and Expo devices are still sent to.
//
// Request body: { title: string, body: string, audience?: "all" | "partners" | "users", profileId?: string, data?: object }
//
// Audience resolution:
//   * all      — every registered token
//   * users    — every registered token as well: every account is a user
//                account, whether or not it also has a partner account
//   * partners — tokens whose profile is in `partners` (auth_user_id),
//                whether or not the same account is also used as a user
//
// "drivers" is accepted as a legacy alias for "partners".
//
// When `profileId` is set the notification goes only to that profile's
// devices (used for targeted events like wallet transfer requests) and the
// audience field is ignored.
//
// Reads tokens with the service-role key (bypasses RLS) and logs the dispatch
// to `public.push_notifications`.
//
// Callers: only the database webhook (`x-push-secret`, migration 0128), the
// service-role key, or a signed-in admin. Everyone else gets 401/403 before
// the body is read — see _shared/push_auth.ts.
//
// Deploy (no gateway JWT check: the webhook has no user JWT, and the
// function checks every caller itself):
//   supabase functions deploy send-push --no-verify-jwt
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { googleAccessToken } from "../_shared/google_auth.ts";
import {
  apnsJwt,
  apnsOutcome,
  apnsRequest,
  APNS_DEVELOPMENT,
  APNS_PRODUCTION,
  parseApnsKey,
  voipPayload,
} from "../_shared/apns.ts";
import {
  type DeviceRow,
  FCM_SCOPE,
  fcmCallMessage,
  fcmMessage,
  fcmOutcome,
  fcmSendUrl,
  parseServiceAccount,
  planDeliveries,
} from "../_shared/push.ts";
import { livePushAuthDeps } from "../_shared/push_auth.ts";
import { handleSendPush, json, type SendBody } from "../_shared/send_push_handler.ts";

const EXPO_PUSH_URL = "https://exp.host/--/api/v2/push/send";

// FCM v1 takes one message per request; this many are in flight at once.
const FCM_CONCURRENCY = 10;

Deno.serve(async (req: Request) => {
  try {
    return await handleSendPush(req, {
      auth: livePushAuthDeps({
        url: Deno.env.get("SUPABASE_URL") ?? "",
        anonKey: Deno.env.get("SUPABASE_ANON_KEY") ?? "",
        serviceKey: serviceRoleKey() ?? "",
      }),
      dispatch,
    });
  } catch (e) {
    console.error("[send-push] failed", e);
    return json({ error: "Unexpected error" }, 500);
  }
});

function serviceRoleKey(): string | undefined {
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SERVICE_ROLE_KEY");
}

type Audience = "all" | "partners" | "users";

async function dispatch(payload: SendBody): Promise<Response> {
  const title = (payload.title ?? "").trim();
  const body = (payload.body ?? "").trim();
  const rawAudience = (payload.audience ?? "all").toLowerCase();
  // "drivers" is the legacy key for the partner audience.
  const audience = (
    rawAudience === "drivers" || rawAudience === "partners"
      ? "partners"
      : rawAudience === "users"
        ? "users"
        : "all"
  ) as Audience;

  if (!title || !body) {
    return json({ error: "title and body are required" }, 400);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = serviceRoleKey();
  if (!supabaseUrl || !serviceKey) {
    return json({ error: "Function is missing Supabase credentials" }, 500);
  }

  const supabase = createClient(supabaseUrl, serviceKey);

  const profileId = (payload.profileId ?? "").trim();

  // Resolve the audience to a set of profile ids when scoping by role.
  // "all" and "users" both reach every registered device: every account is a
  // user account, whether or not it also has a partner account. Only the
  // "partners" audience narrows to profiles that hold a `partners` row.
  let profileFilter: string[] | null = null;
  if (profileId) {
    profileFilter = [profileId];
  } else if (audience === "partners") {
    const { data: partners, error: partnersErr } = await supabase
      .from("partners")
      .select("auth_user_id")
      .not("auth_user_id", "is", null);
    if (partnersErr) {
      return json({ error: `Failed to load partners: ${partnersErr.message}` }, 500);
    }
    const partnerIds = Array.from(
      new Set(
        (partners ?? [])
          .map((p: { auth_user_id: string | null }) => p.auth_user_id)
          .filter((v: string | null): v is string => !!v)
      )
    );

    profileFilter = partnerIds;
    if (profileFilter.length === 0) {
      return json({ recipients: 0, sent: 0, failed: 0, tickets: [] });
    }
  }

  // `capabilities` arrived with migration 0134; a database without it is
  // read without it, and every device gets an ordinary notification.
  const loadTokens = (columns: string) => {
    let query = supabase.from("push_tokens").select(columns);
    if (profileFilter) query = query.in("profile_id", profileFilter);
    return query;
  };
  let { data: tokenRows, error: tokensErr } = await loadTokens("token, platform, profile_id, capabilities");
  if (tokensErr && /capabilities/.test(tokensErr.message ?? "")) {
    ({ data: tokenRows, error: tokensErr } = await loadTokens("token, platform, profile_id"));
  }
  if (tokensErr) {
    return json({ error: `Failed to load tokens: ${tokensErr.message}` }, 500);
  }

  // Each device's way of being told (push.ts: planDeliveries). A ride call
  // rings capable Android builds through a data message and iPhones through
  // a VoIP push once the APNs key is configured.
  const apnsKey = parseApnsKey((name) => Deno.env.get(name));
  const kind = payload.data?.type;
  const deliveries = planDeliveries((tokenRows ?? []) as unknown as DeviceRow[], kind, apnsKey !== null);
  const tokens = deliveries.flatMap((d) => (d.via === "expo" ? [d.token] : []));
  const fcmDeliveries = deliveries.flatMap((d) => (d.via === "fcm" ? [d] : []));
  const voipTokens = deliveries.flatMap((d) => (d.via === "voip" ? [d.token] : []));
  const recipients = deliveries.length;

  const loggedAudience = profileId ? "direct" : audience;

  if (recipients === 0) {
    await supabase.from("push_notifications").insert({
      title,
      body,
      audience: loggedAudience,
      recipients: 0,
      sent: 0,
      failed: 0,
    });
    return json({ recipients: 0, sent: 0, failed: 0, tickets: [] });
  }

  // Expo accepts up to 100 messages per request.
  const messages = tokens.map((to) => ({
    to,
    title,
    body,
    sound: "default",
    data: payload.data ?? { audience },
  }));

  const tickets: unknown[] = [];
  let sent = 0;
  let failed = 0;
  // Tokens Expo or FCM reports as no longer valid — pruned after dispatch.
  const deadTokens = new Set<string>();

  for (let i = 0; i < messages.length; i += 100) {
    const chunk = messages.slice(i, i + 100);
    try {
      const res = await fetch(EXPO_PUSH_URL, {
        method: "POST",
        headers: {
          Accept: "application/json",
          "Accept-encoding": "gzip, deflate",
          "Content-Type": "application/json",
        },
        body: JSON.stringify(chunk),
      });
      const result = await res.json();
      const data = Array.isArray(result?.data) ? result.data : [];
      for (let j = 0; j < data.length; j += 1) {
        const ticket = data[j];
        tickets.push(ticket);
        if (ticket?.status === "ok") {
          sent += 1;
        } else {
          failed += 1;
          // Expo flags unregistered/invalid tokens — collect them for pruning.
          const errCode = ticket?.details?.error;
          if (errCode === "DeviceNotRegistered" || errCode === "InvalidCredentials") {
            const badToken = chunk[j]?.to;
            if (typeof badToken === "string") deadTokens.add(badToken);
          }
        }
      }
      // If Expo returned fewer tickets than messages (hard error), count the rest as failed.
      if (data.length < chunk.length) failed += chunk.length - data.length;
    } catch (e) {
      failed += chunk.length;
      tickets.push({ status: "error", message: String(e) });
    }
  }

  // ---- FCM (the Flutter app) ----------------------------------------------
  if (fcmDeliveries.length > 0) {
    const account = parseServiceAccount(Deno.env.get("FCM_SERVICE_ACCOUNT"));
    let accessToken: string | null = null;
    let setupError: string | null = null;
    if (!account) {
      setupError = "FCM_SERVICE_ACCOUNT is not set (or is not a service account JSON)";
    } else {
      try {
        accessToken = await googleAccessToken(
          { client_email: account.client_email!, private_key: account.private_key!, token_uri: account.token_uri },
          FCM_SCOPE
        );
      } catch (e) {
        setupError = String(e instanceof Error ? e.message : e);
      }
    }

    if (!accessToken || !account?.project_id) {
      failed += fcmDeliveries.length;
      tickets.push({ status: "error", service: "fcm", message: setupError, count: fcmDeliveries.length });
      console.log("[send-push] FCM not sent:", setupError);
    } else {
      const url = fcmSendUrl(account.project_id);
      const sendOne = async ({ token, style }: { token: string; style: "alert" | "call" }) => {
        const data = payload.data ?? { audience };
        try {
          const res = await fetch(url, {
            method: "POST",
            headers: {
              Authorization: `Bearer ${accessToken}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify(
              style === "call" ? fcmCallMessage(token, title, body, data) : fcmMessage(token, title, body, data)
            ),
          });
          const result = await res.json().catch(() => null);
          const outcome = fcmOutcome(res.status, result);
          if (outcome === "sent") {
            sent += 1;
            tickets.push({ status: "ok", service: "fcm" });
          } else {
            failed += 1;
            if (outcome === "unregistered") deadTokens.add(token);
            tickets.push({ status: "error", service: "fcm", http: res.status, error: result?.error?.status ?? null });
          }
        } catch (e) {
          failed += 1;
          tickets.push({ status: "error", service: "fcm", message: String(e) });
        }
      };
      for (let i = 0; i < fcmDeliveries.length; i += FCM_CONCURRENCY) {
        await Promise.all(fcmDeliveries.slice(i, i + FCM_CONCURRENCY).map(sendOne));
      }
    }
  }

  // ---- VoIP (iPhones, ride calls only) -------------------------------------
  if (apnsKey && voipTokens.length > 0) {
    let jwt: string | null = null;
    try {
      jwt = await apnsJwt(apnsKey, Date.now() / 1000);
    } catch (e) {
      failed += voipTokens.length;
      tickets.push({ status: "error", service: "apns", message: String(e instanceof Error ? e.message : e) });
    }
    if (jwt) {
      const voip = voipPayload(payload.data ?? {}, title);
      const post = async (host: string, token: string) => {
        const { url, init } = apnsRequest(host, apnsKey, jwt!, token, voip);
        const res = await fetch(url, init);
        const reason = res.ok ? null : ((await res.json().catch(() => null))?.reason ?? null);
        return apnsOutcome(res.status, reason);
      };
      await Promise.all(
        voipTokens.map(async (token) => {
          try {
            // A token is production's or development's, and nothing records
            // which: BadDeviceToken from one is a try at the other.
            let outcome = await post(APNS_PRODUCTION, token);
            if (outcome === "wrong_environment") {
              outcome = await post(APNS_DEVELOPMENT, token);
              if (outcome === "wrong_environment") outcome = "unregistered";
            }
            if (outcome === "sent") {
              sent += 1;
              tickets.push({ status: "ok", service: "apns" });
            } else {
              failed += 1;
              if (outcome === "unregistered") deadTokens.add(token);
              tickets.push({ status: "error", service: "apns", outcome });
            }
          } catch (e) {
            failed += 1;
            tickets.push({ status: "error", service: "apns", message: String(e) });
          }
        })
      );
    }
  }

  // Auto-prune dead tokens so future broadcasts stay lean.
  let pruned = 0;
  if (deadTokens.size > 0) {
    const { error: pruneErr } = await supabase
      .from("push_tokens")
      .delete()
      .in("token", Array.from(deadTokens));
    if (pruneErr) {
      console.log("[send-push] failed to prune dead tokens:", pruneErr.message);
    } else {
      pruned = deadTokens.size;
    }
  }

  await supabase.from("push_notifications").insert({
    title,
    body,
    audience: loggedAudience,
    recipients,
    sent,
    failed,
  });

  return json({ recipients, sent, failed, pruned, tickets });
}
