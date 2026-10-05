// Copied from getgroupmy/get-ride scripts/google_auth.ts (the Play upload).
// Used here by send-push for the FCM HTTP v1 API.
/**
 * A Google access token from a service account, without a Google SDK.
 *
 * A signed JWT exchanged at Google's token endpoint. Used by
 * scripts/play_upload.ts with the androidpublisher scope; nothing here is
 * Play specific -- the scope decides what the token is good for.
 */

export interface ServiceAccount {
  client_email: string;
  private_key: string;
  token_uri?: string;
}

const TOKEN_URI = "https://oauth2.googleapis.com/token";

/** Google's JWTs are base64url, which is base64 with three substitutions. */
function b64url(bytes: Uint8Array | string): string {
  const raw = typeof bytes === "string"
    ? bytes
    : Array.from(bytes, (b) => String.fromCharCode(b)).join("");
  return btoa(raw).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/**
 * The PEM body, decoded.
 *
 * Service account keys are PKCS#8 ("BEGIN PRIVATE KEY"). The header,
 * footer and every newline come out before the base64 is decoded —
 * including the literal `\n` sequences left behind when the JSON was
 * pasted through something that escaped them, which is how these keys
 * usually arrive.
 */
// An ArrayBuffer rather than a Uint8Array: `importKey` wants a
// BufferSource backed by an ArrayBuffer specifically, and a Uint8Array
// declared over the wider ArrayBufferLike — which is what the plain
// constructor gives you — does not satisfy it.
function pkcs8(pem: string): ArrayBuffer {
  const body = pem
    .replace(/\\n/g, "\n")
    .replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "")
    .replace(/\s+/g, "");
  const raw = atob(body);
  const buffer = new ArrayBuffer(raw.length);
  const out = new Uint8Array(buffer);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return buffer;
}

export async function googleAccessToken(
  sa: ServiceAccount,
  scope: string,
): Promise<string> {
  if (!sa.client_email || !sa.private_key) {
    throw new Error(
      "The Google credential is not a service account JSON: it has no " +
        "client_email or private_key.",
    );
  }

  const now = Math.floor(Date.now() / 1000);
  const uri = sa.token_uri ?? TOKEN_URI;
  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = b64url(JSON.stringify({
    iss: sa.client_email,
    scope,
    aud: uri,
    // An hour is the maximum Google accepts, and the token is thrown
    // away at the end of this request anyway.
    exp: now + 3600,
    iat: now,
  }));

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pkcs8(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      key,
      new TextEncoder().encode(`${header}.${claims}`),
    ),
  );
  const assertion = `${header}.${claims}.${b64url(signature)}`;

  const response = await fetch(uri, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok || !body?.access_token) {
    throw new Error(
      `Google refused the service account: ${
        body?.error_description ?? body?.error ?? response.status
      }`,
    );
  }
  return body.access_token as string;
}
