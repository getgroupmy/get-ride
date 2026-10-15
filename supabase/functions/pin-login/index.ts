// ============================================================================
// pin-login — Supabase Edge Function
// ----------------------------------------------------------------------------
// PIN sign-in through the server (migration 0172). The phone sends its number
// and PIN; the database checks the PIN (hash, per-address rate limit, five
// wrong PINs lock the account for fifteen minutes); on a match this function
// signs in with the account's server password (derived from a key only it
// holds, see _shared/pin_login.ts) and returns the session. The password stays
// the same between sign-ins, so the account's other devices stay signed in.
// Nothing derived from the PIN is a password, so Auth's password grant is no
// use to someone guessing PINs.
//
// Request:  POST { phone: "+60123456789", pin: "123456" }   (no session)
// Response: 200 { session: { access_token, refresh_token, expires_in, ... } }
//           400 { error: "bad_request" }
//           401 { error: "wrong_pin", attempts_left? } (also for an unknown number; the
//               tries left only for an account with a PIN, 0192)
//           409 { error: "needs_otp" }        (sign in by SMS code instead)
//           423 { error: "locked", retry_after }
//           429 { error: "rate_limited", retry_after }
//           503 { error: "unavailable" }
//
// Deploy (there is no session yet, so the gateway must not ask for one):
//   supabase functions deploy pin-login --no-verify-jwt
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { accountPassword, clientIp, handlePinLogin } from "../_shared/pin_login.ts";

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

const url = Deno.env.get("SUPABASE_URL") ?? "";
const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
// The key account passwords are derived with: PIN_LOGIN_SECRET when set,
// else the service key (as secret, and already this function's). Changing it
// means each account's next PIN sign-in sets its password again once.
const passwordKey = Deno.env.get("PIN_LOGIN_SECRET") || serviceKey;
const noSession = { auth: { persistSession: false, autoRefreshToken: false } };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_request" }, 400);
  }

  const admin = createClient(url, serviceKey, noSession);
  const result = await handlePinLogin(body, clientIp(req.headers), {
    async check(phone, pin, ip) {
      const { data, error } = await admin.rpc("pin_login_check", { p_phone: phone, p_pin: pin, p_ip: ip });
      if (error) throw new Error(error.message);
      return typeof data === "string" && data ? data : null;
    },
    async authPhone(userId) {
      const { data, error } = await admin.auth.admin.getUserById(userId);
      if (error) {
        if (/not.?found/i.test(error.message)) return null;
        throw error;
      }
      const phone = data.user?.phone;
      return phone ? (phone.startsWith("+") ? phone : `+${phone}`) : null;
    },
    async setPassword(userId, password) {
      const { error } = await admin.auth.admin.updateUserById(userId, { password });
      if (error) throw error;
    },
    async signIn(phone, password) {
      // A fresh client each time: the session is handed to the phone, never kept.
      const anon = createClient(url, anonKey, noSession);
      const { data, error } = await anon.auth.signInWithPassword({ phone, password });
      if (error || !data.session) return null;
      const s = data.session;
      return {
        access_token: s.access_token,
        refresh_token: s.refresh_token,
        expires_in: s.expires_in,
        expires_at: s.expires_at,
        token_type: s.token_type,
      };
    },
    async attemptsLeft(phone) {
      const { data, error } = await admin.rpc("pin_attempts_left", { p_phone: phone });
      if (error) return null;
      return typeof data === "number" ? data : null;
    },
    accountPassword: (userId) => accountPassword(passwordKey, userId),
  });
  return json(result.body, result.status);
});
