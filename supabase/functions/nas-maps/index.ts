// ============================================================================
// nas-maps — Supabase Edge Function
// ----------------------------------------------------------------------------
// Own maps on the office NAS (migration 0319): the NAS's agent pairs with a
// one-time code from Admin -> Settings -> Office NAS -> Maps, then checks in
// every minute with the health of its routes (OSRM), address search
// (Photon), map tiles and weekly data refresh, and with its Cloudflare
// Tunnel addresses and the secret the geo function sends there. The agent
// only calls out; its key goes in the x-nas-key header. See
// _shared/nas_maps.ts for the calls.
//
// Request:  POST { action: "pair" | "heartbeat", ... }
// Response: 200 · 400 bad_request / NAS_PAIR_CODE · 401 NAS_KEY_INVALID
//           429 NAS_PAIR_BUSY · 503 unavailable
//
// Deploy: supabase functions deploy nas-maps --no-verify-jwt
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { handleNasMaps } from "../_shared/nas_maps.ts";

const headers = { "Content-Type": "application/json", "Cache-Control": "no-store" };
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers });

const db = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);
  const input = await req.json().catch(() => null);
  try {
    const r = await handleNasMaps(input, req.headers.get("x-nas-key"), {
      async rpc(name, args) {
        const { data, error } = await db.rpc(name, args);
        if (error) throw error;
        return data;
      },
    });
    return reply(r.body, r.status);
  } catch (e) {
    console.log("[nas-maps]", (e as Error)?.message ?? e);
    return reply({ error: "unavailable" }, 503);
  }
});
