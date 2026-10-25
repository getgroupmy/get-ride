// ============================================================================
// doc-reader — Supabase Edge Function
// ----------------------------------------------------------------------------
// Document reading (migration 0293): the office NAS (or a GPU reading PC)
// pairs with a one-time code from Admin -> Settings -> Document reading,
// then checks in, claims reading jobs (each with a 5-minute link to its
// photo) and reports what it read. The reader only calls out; its key goes in
// the x-reader-key header. See _shared/doc_reader.ts for the calls.
//
// Request:  POST { action: "pair" | "heartbeat" | "claim" | "report", ... }
// Response: 200 · 400 bad_request / READER_PAIR_CODE · 401 READER_KEY_INVALID
//           429 READER_PAIR_BUSY · 503 unavailable
//
// Deploy: supabase functions deploy doc-reader --no-verify-jwt
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { handleDocReader } from "../_shared/doc_reader.ts";

const headers = { "Content-Type": "application/json", "Cache-Control": "no-store" };
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers });

const db = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);
  const input = await req.json().catch(() => null);
  try {
    const r = await handleDocReader(input, req.headers.get("x-reader-key"), {
      async rpc(name, args) {
        const { data, error } = await db.rpc(name, args);
        if (error) throw error;
        return data;
      },
      async sign(bucket, path, seconds) {
        const { data, error } = await db.storage.from(bucket).createSignedUrl(path, seconds);
        if (error) console.log("[doc-reader] sign:", error.message);
        return data?.signedUrl ?? null;
      },
    });
    return reply(r.body, r.status);
  } catch (e) {
    console.log("[doc-reader]", (e as Error)?.message ?? e);
    return reply({ error: "unavailable" }, 503);
  }
});
