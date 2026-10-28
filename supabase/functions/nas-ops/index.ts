// ============================================================================
// nas-ops — Supabase Edge Function
// ----------------------------------------------------------------------------
// Office NAS backups and uptime (migration 0318): the NAS app
// (deploy/nas-backup) pairs with a one-time code from Admin -> Settings ->
// Office NAS, then checks in every minute (settings, its uptime targets, a
// waiting "Back up now" or "Run a restore test"), reports each backup and
// restore test, and its uptime checks. The app only calls out; its key goes
// in the x-nas-key header. The database's connection string and the storage
// key never leave the NAS. See _shared/nas_ops.ts for the calls.
//
// Request:  POST { action: "pair" | "heartbeat" | "backup_start" | "backup_finish" | "uptime_report", ... }
// Response: 200 · 400 bad_request / NAS_PAIR_CODE · 401 NAS_KEY_INVALID
//           429 NAS_PAIR_BUSY · 503 unavailable
//
// Deploy: supabase functions deploy nas-ops --no-verify-jwt
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { handleNasOps } from "../_shared/nas_ops.ts";

const headers = { "Content-Type": "application/json", "Cache-Control": "no-store" };
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers });

const projectUrl = Deno.env.get("SUPABASE_URL") ?? "";
const db = createClient(projectUrl, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);
  const input = await req.json().catch(() => null);
  try {
    const r = await handleNasOps(input, req.headers.get("x-nas-key"), {
      projectUrl,
      async rpc(name, args) {
        const { data, error } = await db.rpc(name, args);
        if (error) throw error;
        return data;
      },
    });
    return reply(r.body, r.status);
  } catch (e) {
    console.log("[nas-ops]", (e as Error)?.message ?? e);
    return reply({ error: "unavailable" }, 503);
  }
});
