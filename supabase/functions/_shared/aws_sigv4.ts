/**
 * AWS Signature Version 4 for a JSON POST (Rekognition's API), and the key
 * as Admin → API Keys keeps it: "ACCESS_KEY_ID:SECRET_ACCESS_KEY" or
 * "ACCESS_KEY_ID:SECRET_ACCESS_KEY:region". Web Crypto only, so it runs in an
 * edge function and in deno test alike.
 *
 *     deno test supabase/functions/_shared/aws_sigv4_test.ts
 */

export interface AwsKey {
  accessKeyId: string;
  secretAccessKey: string;
  region: string;
}

export const DEFAULT_AWS_REGION = "ap-southeast-1";

/** The stored key value, split; null when it isn't one. */
export function parseAwsKey(value: string | null | undefined, fallbackRegion = DEFAULT_AWS_REGION): AwsKey | null {
  const parts = (value ?? "").trim().split(":").map((s) => s.trim());
  if (parts.length < 2 || parts.length > 3) return null;
  const [accessKeyId, secretAccessKey, region] = parts;
  if (!/^[A-Z0-9]{16,128}$/.test(accessKeyId) || secretAccessKey.length < 16) return null;
  const r = region && /^[a-z]{2}(-[a-z]+)+-\d$/.test(region) ? region : fallbackRegion;
  return { accessKeyId, secretAccessKey, region: r };
}

const enc = new TextEncoder();

function hex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function sha256Hex(data: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", enc.encode(data)));
}

async function hmac(key: ArrayBuffer | Uint8Array<ArrayBuffer>, data: string): Promise<ArrayBuffer> {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return crypto.subtle.sign("HMAC", k, enc.encode(data));
}

/** "20261024T110000Z" and "20261024". */
export function amzDates(now: Date): { amzDate: string; day: string } {
  const amzDate = now.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
  return { amzDate, day: amzDate.slice(0, 8) };
}

/**
 * The headers for a POST of [body] to https://[service].[region].amazonaws.com/
 * with the JSON 1.1 [target] (e.g. "RekognitionService.CompareFaces").
 */
export async function signedJsonPost(
  key: AwsKey,
  service: string,
  target: string,
  body: string,
  now = new Date(),
): Promise<{ url: string; headers: Record<string, string> }> {
  const host = `${service}.${key.region}.amazonaws.com`;
  const { amzDate, day } = amzDates(now);
  const payloadHash = await sha256Hex(body);
  const contentType = "application/x-amz-json-1.1";
  const canonicalHeaders = `content-type:${contentType}\nhost:${host}\nx-amz-date:${amzDate}\nx-amz-target:${target}\n`;
  const signedHeaders = "content-type;host;x-amz-date;x-amz-target";
  const canonicalRequest = ["POST", "/", "", canonicalHeaders, signedHeaders, payloadHash].join("\n");
  const scope = `${day}/${key.region}/${service}/aws4_request`;
  const stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, await sha256Hex(canonicalRequest)].join("\n");
  let k = await hmac(enc.encode(`AWS4${key.secretAccessKey}`) as Uint8Array<ArrayBuffer>, day);
  k = await hmac(k, key.region);
  k = await hmac(k, service);
  k = await hmac(k, "aws4_request");
  const signature = hex(await hmac(k, stringToSign));
  return {
    url: `https://${host}/`,
    headers: {
      "Content-Type": contentType,
      "X-Amz-Date": amzDate,
      "X-Amz-Target": target,
      Authorization: `AWS4-HMAC-SHA256 Credential=${key.accessKeyId}/${scope}, SignedHeaders=${signedHeaders}, ` +
        `Signature=${signature}`,
    },
  };
}
