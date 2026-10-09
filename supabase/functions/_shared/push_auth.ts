/**
 * Who may make send-push send. The function is deployed --no-verify-jwt (the
 * database webhook carries no user JWT), so it checks every caller itself:
 *
 *   * the database webhook (`public.send_push_webhook`, migration 0128)
 *     sends `x-push-secret` with the Vault secret `push_webhook_secret`;
 *     the database says whether it matches (`push_webhook_secret_ok`), so
 *     the secret lives in one place;
 *   * a bearer that is the project's service-role key;
 *   * a bearer that is a signed-in admin's access token — the admin
 *     "Push Notification" screens. `caller_is_admin()` is asked with that
 *     token, which also answers true for a service-role JWT.
 *
 * Anything else is refused before the body is read: no credentials -> 401,
 * a valid token that is not an admin's -> 403.
 *
 *     deno test supabase/functions/_shared/push_auth_test.ts
 */

export const WEBHOOK_SECRET_HEADER = "x-push-secret";

export interface PushAuthDeps {
  /** Keys accepted as a bearer without asking the database. */
  serviceKeys: string[];
  /** Whether the webhook secret matches the one in Vault. */
  webhookSecretOk(secret: string): Promise<boolean>;
  /** `caller_is_admin()` for this Authorization header; null when the token is not accepted. */
  callerIsAdmin(authorization: string): Promise<boolean | null>;
}

export type PushAuthResult =
  | { ok: true; caller: "webhook" | "service" | "admin" }
  | { ok: false; status: 401 | 403; error: string };

/** Constant-time string comparison, so a key can't be guessed byte by byte. */
export function sameSecret(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const x = enc.encode(a);
  const y = enc.encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i += 1) {
    diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  }
  return diff === 0;
}

function bearerOf(header: string | null): string | null {
  const m = /^Bearer\s+(.+)$/i.exec((header ?? "").trim());
  return m ? m[1].trim() || null : null;
}

export async function authorizePush(
  req: Request,
  deps: PushAuthDeps,
): Promise<PushAuthResult> {
  const secret = (req.headers.get(WEBHOOK_SECRET_HEADER) ?? "").trim();
  if (secret) {
    if (await deps.webhookSecretOk(secret)) return { ok: true, caller: "webhook" };
    return { ok: false, status: 401, error: "Invalid webhook secret" };
  }

  const token = bearerOf(req.headers.get("Authorization"));
  if (!token) return { ok: false, status: 401, error: "Missing Authorization header" };

  if (deps.serviceKeys.some((key) => key && sameSecret(token, key))) {
    return { ok: true, caller: "service" };
  }

  const admin = await deps.callerIsAdmin(`Bearer ${token}`);
  if (admin === null) return { ok: false, status: 401, error: "Invalid or expired token" };
  if (!admin) return { ok: false, status: 403, error: "Only admins can send notifications" };
  return { ok: true, caller: "admin" };
}

/**
 * The deps over PostgREST. Plain fetch rather than supabase-js so the test
 * can stand in for the network.
 */
export function livePushAuthDeps(
  env: { url: string; anonKey: string; serviceKey: string },
  fetchFn: typeof fetch = fetch,
): PushAuthDeps {
  const rpc = (name: string, apikey: string, authorization: string, body: unknown) =>
    fetchFn(`${env.url}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: { apikey, Authorization: authorization, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });

  return {
    serviceKeys: [env.serviceKey],
    async webhookSecretOk(secret) {
      const res = await rpc(
        "push_webhook_secret_ok",
        env.serviceKey,
        `Bearer ${env.serviceKey}`,
        { p_secret: secret },
      );
      if (!res.ok) {
        console.log("[send-push] webhook secret check failed:", res.status, await res.text());
        return false;
      }
      return (await res.json()) === true;
    },
    async callerIsAdmin(authorization) {
      const res = await rpc("caller_is_admin", env.anonKey, authorization, {});
      // PostgREST answers 401 for a token it won't accept (bad signature, expired).
      if (res.status === 401 || res.status === 403) {
        await res.body?.cancel();
        return null;
      }
      if (!res.ok) throw new Error(`caller_is_admin: HTTP ${res.status} ${await res.text()}`);
      return (await res.json()) === true;
    },
  };
}
