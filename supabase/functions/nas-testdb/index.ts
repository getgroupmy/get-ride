// ============================================================================
// nas-testdb — Supabase Edge Function
// ----------------------------------------------------------------------------
// The office NAS's test database (migration 0321, deploy/nas-testdb): the
// runner pairs with a one-time code from Admin -> Settings -> Office NAS ->
// Test database, then checks in every minute, claims the runs an admin asked
// for (try a PR's migrations, refresh the copy now) and reports how each
// went. The runner only calls out; its key goes in the x-runner-key header.
// See _shared/nas_testdb.ts for the calls.
//
// Request:  POST { action: "pair" | "heartbeat" | "claim" | "report", ... }
// Response: 200 · 400 bad_request / TESTDB_PAIR_CODE · 401 TESTDB_KEY_INVALID
//           429 TESTDB_PAIR_BUSY · 503 unavailable
//
// Deploy: supabase functions deploy nas-testdb --no-verify-jwt
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { handleTestDb } from "../_shared/nas_testdb.ts";

const headers = { "Content-Type": "application/json", "Cache-Control": "no-store" };
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers });

const db = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);
  const input = await req.json().catch(() => null);
  try {
    const r = await handleTestDb(input, req.headers.get("x-runner-key"), {
      async rpc(name, args) {
        const { data, error } = await db.rpc(name, args);
        if (error) throw error;
        return data;
      },
    });
    return reply(r.body, r.status);
  } catch (e) {
    console.log("[nas-testdb]", (e as Error)?.message ?? e);
    return reply({ error: "unavailable" }, 503);
  }
});
