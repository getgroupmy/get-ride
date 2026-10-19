// ============================================================================
// key-test — Supabase Edge Function
// ----------------------------------------------------------------------------
// Admin → API Keys → a key → Test: one small, real request with that key to
// the API the admin picked, and what came back in plain words. Admins only.
// The key is read here from app_settings 'api_providers' by its id and never
// returned. See _shared/key_test.ts for the tests and how answers are read.
//
//   GET                                          → { tests: [...] }
//   POST { provider, service, key, test, as?, cert? }
//        → { result: "ok" | "warn" | "fail", title, detail, http, ms, as }
//
// Deploy: supabase functions deploy key-test
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { runKeyTest, testList } from "../_shared/key_test.ts";
import { API_KEY_PAGES, callerCanEditHere } from "../_shared/admin_page.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Max-Age": "7200",
};

const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });

const url = Deno.env.get("SUPABASE_URL") ?? "";
const db = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});

/** The first 4 KB of the answer: enough for any error, never a whole image. */
async function readStart(res: Response): Promise<string> {
  const reader = res.body?.getReader();
  if (!reader) return "";
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (size < 4096) {
    const { done, value } = await reader.read();
    if (done || !value) break;
    chunks.push(value);
    size += value.length;
  }
  await reader.cancel().catch(() => {});
  const all = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) {
    all.set(c, at);
    at += c.length;
  }
  return new TextDecoder().decode(all.slice(0, 4096));
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "GET" && req.method !== "POST") return reply({ error: "Method not allowed" }, 405);

  // Edit access to API Keys, not any admin: a test spends the keys.
  const canEdit = await callerCanEditHere(req.headers.get("Authorization"), API_KEY_PAGES).catch(() => false);
  if (canEdit === null) return reply({ error: "not_signed_in" }, 401);
  if (canEdit !== true) return reply({ error: "admin_only" }, 403);

  if (req.method === "GET") return reply({ tests: testList() });

  try {
    const answer = await runKeyTest(await req.json().catch(() => null), {
      settings: async () => {
        const { data, error } = await db.from("app_settings").select("key, value")
          .in("key", ["api_providers", "map_config"]);
        if (error) throw error;
        const by = Object.fromEntries((data ?? []).map((r) => [r.key, r.value]));
        return { apiProviders: by.api_providers ?? null, config: by.map_config ?? null };
      },
      fetch: async (r) => {
        const res = await fetch(r.url, {
          method: r.method ?? "GET",
          headers: { Accept: "application/json", "User-Agent": "GET.ride key test (getride.my)", ...(r.headers ?? {}) },
          body: r.body,
          redirect: "follow",
          signal: AbortSignal.timeout(10_000),
        });
        return { status: res.status, text: await readStart(res) };
      },
      now: () => Date.now(),
    });
    return reply(answer.body, answer.status);
  } catch (e) {
    console.error("key-test:", e instanceof Error ? e.message : "failed");
    return reply({ error: "unavailable" }, 503);
  }
});
