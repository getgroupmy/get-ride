// ============================================================================
// attest-device — Supabase Edge Function  [TEMPLATE — NOT YET DEPLOYED]
// ----------------------------------------------------------------------------
// Verifies a platform device-attestation token SERVER-SIDE and logs the verdict
// to public.device_attestations. This is the un-forgeable half of the sign-up
// anti-fraud pipeline: the client can lie about its device_id, but it cannot
// forge a Google-/Apple-signed attestation for a genuine, unmodified app.
//
//   Android → Google Play Integrity API   (integrity token)
//   iOS     → Apple App Attest             (attestation object + key id)
//
// IMPORTANT: this function is INERT until BOTH of the following exist:
//   1. A native client that produces real attestation tokens (Expo Go / the
//      Rork managed flow cannot — a custom dev/prod build is required).
//   2. The provider credentials below, set as Supabase function secrets.
// Until then it is not deployed and nothing in the app calls it. See
// docs/device-attestation.md for the full activation checklist.
//
// Verification status:
//   - Play Integrity (Android): IMPLEMENTED but UNTESTED — needs a real
//     integrity token from a signed device + the service-account secret to
//     exercise. Confirm pass/fail rates before enforcing.
//   - App Attest (iOS): STILL STUBBED — a correct verifier needs CBOR decoding
//     and X.509 chain validation to Apple's App Attest root, which must be done
//     with a vetted library and tested on a real device, not hand-rolled blind.
//     Returns passed:false so it can never false-accept.
//
// Required secrets (supabase secrets set ...):
//   ANDROID_PACKAGE_NAME          e.g. com.getride.app
//   GOOGLE_SERVICE_ACCOUNT_JSON   Play Integrity service-account key (JSON)
//   APPLE_APP_ATTEST_TEAM_ID      Apple Developer Team ID
//   APPLE_APP_ATTEST_BUNDLE_ID    e.g. com.getride.app
// (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically.)
//
// Deploy (only once the above are in place):
//   supabase functions deploy attest-device --no-verify-jwt
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type Platform = "android" | "ios";

interface AttestRequest {
  platform: Platform;
  device_id?: string | null;
  user_id?: string | null;
  // Android Play Integrity: the token from the Play Integrity API.
  integrity_token?: string;
  // iOS App Attest: base64 attestation object + the generated key id + the
  // challenge (nonce) the client attested over.
  attestation?: string;
  key_id?: string;
  challenge?: string;
}

interface Verdict {
  passed: boolean;
  attest_key_id: string | null;
  detail: Record<string, unknown>;
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// Small crypto/encoding helpers (Deno Web Crypto — no external deps).
// ---------------------------------------------------------------------------
function b64urlFromBytes(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function bytesFromB64(b64: string): Uint8Array {
  const bin = atob(b64.replace(/-/g, "+").replace(/_/g, "/"));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** Import a PEM PKCS#8 RSA private key for RS256 signing. */
async function importPkcs8RsaKey(pem: string): Promise<CryptoKey> {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  return crypto.subtle.importKey(
    "pkcs8",
    bytesFromB64(body),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

/** Mint a Google OAuth2 access token from a service-account JSON (RS256 JWT). */
async function googleAccessToken(saJson: string, scope: string): Promise<string> {
  const sa = JSON.parse(saJson) as { client_email: string; private_key: string };
  const now = Math.floor(Date.now() / 1000);
  const enc = (o: unknown) =>
    b64urlFromBytes(new TextEncoder().encode(JSON.stringify(o)));
  const header = enc({ alg: "RS256", typ: "JWT" });
  const claims = enc({
    iss: sa.client_email,
    scope,
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  });
  const signingInput = `${header}.${claims}`;
  const key = await importPkcs8RsaKey(sa.private_key);
  const sig = new Uint8Array(
    await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      key,
      new TextEncoder().encode(signingInput),
    ),
  );
  const assertion = `${signingInput}.${b64urlFromBytes(sig)}`;

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!res.ok) {
    throw new Error(`oauth token HTTP ${res.status}: ${await res.text()}`);
  }
  const data = await res.json();
  if (!data?.access_token) throw new Error("oauth token: no access_token");
  return data.access_token as string;
}

// ---------------------------------------------------------------------------
// Android — Play Integrity  (IMPLEMENTED — untested without a real token)
// ---------------------------------------------------------------------------
// Exchanges the service-account JSON for an access token, decodes the integrity
// token via Google's Play Integrity API, and requires genuine device + app
// verdicts. The token carries no stable device id, so attest_key_id stays null.
//
// NOTE: this path has NOT been exercised end-to-end — it needs a real integrity
// token from a signed app on a real device plus the service-account secret.
// Verify pass/fail rates in device_attestations before gating anything on it.
async function verifyPlayIntegrity(token: string): Promise<Verdict> {
  const pkg = Deno.env.get("ANDROID_PACKAGE_NAME");
  const saJson = Deno.env.get("GOOGLE_SERVICE_ACCOUNT_JSON");
  if (!pkg || !saJson) {
    return { passed: false, attest_key_id: null, detail: { error: "not_configured" } };
  }
  try {
    const accessToken = await googleAccessToken(
      saJson,
      "https://www.googleapis.com/auth/playintegrity",
    );
    const res = await fetch(
      `https://playintegrity.googleapis.com/v1/${encodeURIComponent(pkg)}:decodeIntegrityToken`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${accessToken}`,
        },
        body: JSON.stringify({ integrity_token: token }),
      },
    );
    if (!res.ok) {
      return {
        passed: false,
        attest_key_id: null,
        detail: { error: `decode HTTP ${res.status}`, body: (await res.text()).slice(0, 300) },
      };
    }
    const data = await res.json();
    const payload = data?.tokenPayloadExternal ?? {};
    const appVerdict: string = payload?.appIntegrity?.appRecognitionVerdict ?? "";
    const deviceVerdicts: string[] =
      payload?.deviceIntegrity?.deviceRecognitionVerdict ?? [];
    const requestPkg: string = payload?.requestDetails?.requestPackageName ?? "";

    const passed =
      requestPkg === pkg &&
      appVerdict === "PLAY_RECOGNIZED" &&
      deviceVerdicts.includes("MEETS_DEVICE_INTEGRITY");

    return {
      passed,
      attest_key_id: null,
      detail: {
        appRecognitionVerdict: appVerdict,
        deviceRecognitionVerdict: deviceVerdicts,
        requestPackageName: requestPkg,
        appLicensingVerdict: payload?.accountDetails?.appLicensingVerdict ?? null,
      },
    };
  } catch (e) {
    return {
      passed: false,
      attest_key_id: null,
      detail: { error: e instanceof Error ? e.message : String(e) },
    };
  }
}

// ---------------------------------------------------------------------------
// iOS — App Attest
// ---------------------------------------------------------------------------
// Verifies the CBOR attestation object against Apple's App Attest root, checks
// the nonce/challenge, and returns the hardware-backed key id (stable per app
// install) so it can be used as a strong device signal.
async function verifyAppAttest(
  attestation: string,
  keyId: string,
  challenge: string,
): Promise<Verdict> {
  const teamId = Deno.env.get("APPLE_APP_ATTEST_TEAM_ID");
  const bundleId = Deno.env.get("APPLE_APP_ATTEST_BUNDLE_ID");
  if (!teamId || !bundleId) {
    return { passed: false, attest_key_id: null, detail: { error: "not_configured" } };
  }

  // Activation step: decode the base64 CBOR attestation object, verify the x5c
  // certificate chain up to Apple's App Attest root CA, confirm the nonce =
  // SHA256(authenticatorData ‖ SHA256(challenge)), and that the rpId hash =
  // SHA256(teamId + "." + bundleId). On success the credential id IS the
  // hardware-backed key id.
  return {
    passed: false,
    attest_key_id: keyId ?? null,
    detail: {
      error: "verification_not_implemented",
      attestation_len: attestation.length,
      challenge_len: challenge.length,
    },
  };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ ok: false, error: "POST only" }, 405);
  }

  let body: AttestRequest;
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "Invalid JSON body" }, 400);
  }
  if (body.platform !== "android" && body.platform !== "ios") {
    return json({ ok: false, error: "platform must be 'android' or 'ios'" }, 400);
  }

  let verdict: Verdict;
  if (body.platform === "android") {
    if (!body.integrity_token) {
      return json({ ok: false, error: "integrity_token required" }, 400);
    }
    verdict = await verifyPlayIntegrity(body.integrity_token);
  } else {
    if (!body.attestation || !body.key_id || !body.challenge) {
      return json({ ok: false, error: "attestation, key_id and challenge required" }, 400);
    }
    verdict = await verifyAppAttest(body.attestation, body.key_id, body.challenge);
  }

  // Record the verdict (service role → bypasses RLS). Best-effort.
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (supabaseUrl && serviceKey) {
    try {
      const admin = createClient(supabaseUrl, serviceKey);
      await admin.from("device_attestations").insert({
        user_id: body.user_id ?? null,
        device_id: body.device_id ?? null,
        platform: body.platform,
        attest_key_id: verdict.attest_key_id,
        passed: verdict.passed,
        verdict: verdict.detail,
      });
    } catch (e) {
      console.log("[attest-device] record failed", e);
    }
  }

  return json({
    ok: true,
    passed: verdict.passed,
    attest_key_id: verdict.attest_key_id,
  });
});
