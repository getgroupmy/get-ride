/**
 * callerCanEdit against stand-in Auth and PostgREST.
 *
 *     deno test supabase/functions/_shared/admin_page_test.ts
 */
import { assertEquals, assertRejects } from "jsr:@std/assert@1.0.19";

import { API_KEY_PAGES, callerCanEdit } from "./admin_page.ts";

const env = { url: "https://ref.supabase.co", anonKey: "anon", serviceKey: "service" };

function fake(edits: Record<string, string[]>, rpcStatus = 200): typeof fetch {
  return ((input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    const headers = new Headers(init?.headers);
    if (url.endsWith("/auth/v1/user")) {
      const token = (headers.get("Authorization") ?? "").replace(/^Bearer /, "");
      return Promise.resolve(token in edits ? Response.json({ id: token }) : new Response("no", { status: 401 }));
    }
    if (url.endsWith("/rpc/admin_can_edit")) {
      if (headers.get("Authorization") !== "Bearer service") return Promise.resolve(new Response("no", { status: 401 }));
      if (rpcStatus !== 200) return Promise.resolve(new Response("down", { status: rpcStatus }));
      const { p_profile, p_page } = JSON.parse(String(init?.body));
      return Promise.resolve(Response.json(edits[p_profile]?.includes(p_page) ?? false));
    }
    return Promise.resolve(new Response("not found", { status: 404 }));
  }) as typeof fetch;
}

Deno.test("edit access to any of the pages", async () => {
  const f = fake({ keys: ["admin-settings-api-keys"], sub: ["admin-settings-help"], none: [] });
  assertEquals(await callerCanEdit(env, "Bearer keys", API_KEY_PAGES, f), true);
  assertEquals(await callerCanEdit(env, "Bearer sub", API_KEY_PAGES, f), false, "another page's admin");
  assertEquals(await callerCanEdit(env, "Bearer none", API_KEY_PAGES, f), false);
});

Deno.test("no token or a refused one is nobody", async () => {
  const f = fake({});
  assertEquals(await callerCanEdit(env, null, API_KEY_PAGES, f), null);
  assertEquals(await callerCanEdit(env, "Basic x", API_KEY_PAGES, f), null);
  assertEquals(await callerCanEdit(env, "Bearer forged", API_KEY_PAGES, f), null);
});

Deno.test("a check that fails throws (callers refuse)", async () => {
  await assertRejects(() => callerCanEdit(env, "Bearer keys", API_KEY_PAGES, fake({ keys: [] }, 500)));
});
