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
// Store review login (migration 0333, _shared/store_review.ts):
// Request:  POST { action: "review", phone: "+60608080", platform?, device?, app_version? }
// Response: 200 { session }  for the one sealed demo account, when Admin ›
//               App Settings › Store review login is on and the number is its
//           403 { error: "review_off" }   (off, or another number)
//           429 { error: "rate_limited", retry_after }
//           400 / 503 as above
//
// Deploy (there is no session yet, so the gateway must not ask for one):
//   supabase functions deploy pin-login --no-verify-jwt
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { accountPassword, clientIp, handlePinLogin, type PinLoginSession } from "../_shared/pin_login.ts";
import { handleStoreReviewLogin, isStoreReviewBody } from "../_shared/store_review.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "7200",
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
  const authPhone = async (userId: string) => {
    const { data, error } = await admin.auth.admin.getUserById(userId);
    if (error) {
      if (/not.?found/i.test(error.message)) return null;
      throw error;
    }
    const phone = data.user?.phone;
    return phone ? (phone.startsWith("+") ? phone : `+${phone}`) : null;
  };
  const setPassword = async (userId: string, password: string) => {
    const { error } = await admin.auth.admin.updateUserById(userId, { password });
    if (error) throw error;
  };
  const signIn = async (phone: string, password: string): Promise<PinLoginSession | null> => {
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
  };

  // The store review login (0333): the database checks the switch, the
  // number and the rate limits, and logs the try.
  if (isStoreReviewBody(body)) {
    const review = await handleStoreReviewLogin(body, clientIp(req.headers), req.headers.get("user-agent"), {
      async check(r, ip, userAgent) {
        const { data, error } = await admin.rpc("store_review_sign_in", {
          p_phone: r.phone,
          p_ip: ip,
          p_platform: r.platform,
          p_device: r.device,
          p_app_version: r.appVersion,
          p_user_agent: userAgent?.slice(0, 200) ?? null,
        });
        if (error) throw new Error(error.message);
        return data;
      },
      authPhone,
      setPassword,
      signIn,
      accountPassword: (userId) => accountPassword(passwordKey, userId),
    });
    return json(review.body, review.status);
  }

  const result = await handlePinLogin(body, clientIp(req.headers), {
    async check(phone, pin, ip) {
      const { data, error } = await admin.rpc("pin_login_check", { p_phone: phone, p_pin: pin, p_ip: ip });
      if (error) throw new Error(error.message);
      return typeof data === "string" && data ? data : null;
    },
    authPhone,
    setPassword,
    signIn,
    async attemptsLeft(phone) {
      const { data, error } = await admin.rpc("pin_attempts_left", { p_phone: phone });
      if (error) return null;
      return typeof data === "number" ? data : null;
    },
    accountPassword: (userId) => accountPassword(passwordKey, userId),
  });
  return json(result.body, result.status);
});
