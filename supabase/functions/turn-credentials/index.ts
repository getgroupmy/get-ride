// ============================================================================
// turn-credentials — Supabase Edge Function
// ----------------------------------------------------------------------------
// Hands a signed-in caller the ICE servers for a support call (migration
// 0105): STUN, plus short-lived TURN relay credentials so calls also connect
// on mobile networks that block a direct connection.
//
// Request:  POST (no body), with the caller's session.
// Response: { iceServers: [{ urls, username?, credential? }], ttl, relay }
//
// Function secrets (`supabase secrets set ...`):
//   TURN_URLS     comma list, e.g. "turn:turn.example.com:3478?transport=udp,
//                 turn:turn.example.com:3478?transport=tcp,
//                 turns:turn.example.com:5349?transport=tcp"
//   TURN_SECRET   coturn's static-auth-secret (use-auth-secret mode)
//   STUN_URLS     optional comma list; default Google's public STUN
// Without TURN_URLS and TURN_SECRET it answers STUN only, and calls work
// wherever a direct connection does.
//
// Deploy (the gateway checks the session):
//   supabase functions deploy turn-credentials
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { iceServersFor, splitUrls } from "../_shared/turn.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const authHeader = req.headers.get("Authorization") ?? "";
  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const anon = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const userClient = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
  const { data } = await userClient.auth.getUser();
  const uid = data?.user?.id;
  if (!uid) return json({ error: "Not signed in" }, 401);

  return json(
    await iceServersFor({
      userId: uid,
      nowSeconds: Date.now() / 1000,
      turnUrls: splitUrls(Deno.env.get("TURN_URLS")),
      turnSecret: Deno.env.get("TURN_SECRET"),
      stunUrls: splitUrls(Deno.env.get("STUN_URLS")),
    }),
  );
});
