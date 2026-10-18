/**
 * Whether the caller may edit one of an admin page's pages: the user their
 * token names, checked with the service role against admin_access
 * (`admin_can_edit`), as release_handler does.
 *
 * `caller_is_admin()` answers true for anyone with any admin_access row — a
 * sub-admin given one unrelated page to read — so it no longer guards a
 * function that spends keys, sends to every phone or shows settings.
 *
 * Plain fetch rather than supabase-js so tests can stand in for the network.
 *
 *     deno test supabase/functions/_shared/admin_page_test.ts
 */

export interface AdminPageEnv {
  url: string;
  anonKey: string;
  serviceKey: string;
}

/** true / false, or null when the token is missing or not accepted. */
export async function callerCanEdit(
  env: AdminPageEnv,
  authorization: string | null,
  pages: string[],
  fetchFn: typeof fetch = fetch,
): Promise<boolean | null> {
  const token = /^Bearer\s+(.+)$/i.exec((authorization ?? "").trim())?.[1]?.trim();
  if (!token) return null;
  const who = await fetchFn(`${env.url}/auth/v1/user`, {
    headers: { apikey: env.anonKey, Authorization: `Bearer ${token}` },
  });
  // Auth answers 401/403 for a token it won't accept (bad signature, expired, no user).
  if (who.status === 401 || who.status === 403) {
    await who.body?.cancel();
    return null;
  }
  if (!who.ok) throw new Error(`auth user: HTTP ${who.status}`);
  const uid = ((await who.json()) as { id?: unknown } | null)?.id;
  if (typeof uid !== "string" || !uid) return null;
  for (const page of pages) {
    const res = await fetchFn(`${env.url}/rest/v1/rpc/admin_can_edit`, {
      method: "POST",
      headers: {
        apikey: env.serviceKey,
        Authorization: `Bearer ${env.serviceKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ p_profile: uid, p_page: page }),
    });
    if (!res.ok) throw new Error(`admin_can_edit: HTTP ${res.status}`);
    if ((await res.json()) === true) return true;
  }
  return false;
}

/** callerCanEdit from the function's own environment. */
export function callerCanEditHere(authorization: string | null, pages: string[]): Promise<boolean | null> {
  return callerCanEdit({
    url: Deno.env.get("SUPABASE_URL") ?? "",
    anonKey: Deno.env.get("SUPABASE_ANON_KEY") ?? "",
    serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  }, authorization, pages);
}

export const PUSH_PAGES = ["admin-settings-push-notification"];
export const API_KEY_PAGES = ["admin-settings-api-keys-keys", "admin-settings-api-keys"];
export const FARE_AI_PAGES = ["admin-settings-fare-ai"];
export const STATEMENT_PAGES = ["admin-settings-partner-statements"];
