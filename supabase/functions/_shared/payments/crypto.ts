/**
 * Hashes and signatures the payment gateways use: SHA-256, HMAC-SHA256 (hex
 * and base64), MD5 (Fiuu's vcode / skey; Web Crypto has no MD5, so it is
 * written here and checked against RFC 1321's vectors) and a comparison that
 * doesn't stop at the first difference.
 *
 *     deno test supabase/functions/_shared/payments/crypto_test.ts
 */

const te = new TextEncoder();

/** Bytes backed by a plain ArrayBuffer, as Web Crypto takes them. */
export type Bytes = Uint8Array<ArrayBuffer>;

export const utf8 = (s: string): Bytes => te.encode(s) as Bytes;

export function toHex(bytes: ArrayBuffer | Uint8Array): string {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let out = "";
  for (const x of b) out += x.toString(16).padStart(2, "0");
  return out;
}

export function fromHex(hex: string): Bytes {
  const clean = hex.trim();
  if (clean.length % 2 !== 0 || /[^0-9a-fA-F]/.test(clean)) throw new Error("bad hex");
  const out = new Uint8Array(clean.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(clean.slice(i * 2, i * 2 + 2), 16);
  return out;
}

export function toBase64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

export function toBase64Url(bytes: Uint8Array): string {
  return toBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromBase64Url(s: string): Bytes {
  const std = s.replace(/-/g, "+").replace(/_/g, "/");
  const padded = std + "=".repeat((4 - (std.length % 4)) % 4);
  const bin = atob(padded);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export async function sha256Hex(s: string): Promise<string> {
  return toHex(await crypto.subtle.digest("SHA-256", utf8(s)));
}

export async function hmacSha256(key: string | Bytes, message: string): Promise<Bytes> {
  const raw = typeof key === "string" ? utf8(key) : key;
  const k = await crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, utf8(message)));
}

export async function hmacSha256Hex(key: string | Bytes, message: string): Promise<string> {
  return toHex(await hmacSha256(key, message));
}

export async function hmacSha256Base64(key: string | Bytes, message: string): Promise<string> {
  return toBase64(await hmacSha256(key, message));
}

/** Equal strings, compared over their whole length. */
export function safeEqual(a: string, b: string): boolean {
  if (typeof a !== "string" || typeof b !== "string") return false;
  let diff = a.length ^ b.length;
  const n = Math.max(a.length, b.length);
  for (let i = 0; i < n; i++) diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  return diff === 0;
}

/** Hex digests compared without regard to case. */
export const sameHex = (a: string, b: string): boolean => safeEqual(a.toLowerCase(), b.toLowerCase());

// ---- MD5 (RFC 1321) --------------------------------------------------------------------------------

const S = [
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
];
const K = Array.from({ length: 64 }, (_, i) => Math.floor(Math.abs(Math.sin(i + 1)) * 2 ** 32) >>> 0);

export function md5Hex(input: string): string {
  const msg = utf8(input);
  const bitLen = msg.length * 8;
  const padLen = (((msg.length + 8) >> 6) + 1) << 6;
  const buf = new Uint8Array(padLen);
  buf.set(msg);
  buf[msg.length] = 0x80;
  const view = new DataView(buf.buffer);
  view.setUint32(padLen - 8, bitLen >>> 0, true);
  view.setUint32(padLen - 4, Math.floor(bitLen / 2 ** 32), true);

  let a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
  for (let off = 0; off < padLen; off += 64) {
    const M = Array.from({ length: 16 }, (_, i) => view.getUint32(off + i * 4, true));
    let a = a0, b = b0, c = c0, d = d0;
    for (let i = 0; i < 64; i++) {
      let f: number, g: number;
      if (i < 16) {
        f = (b & c) | (~b & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | (~d & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | ~d);
        g = (7 * i) % 16;
      }
      const tmp = d;
      d = c;
      c = b;
      const sum = (a + f + K[i] + M[g]) >>> 0;
      b = (b + ((sum << S[i]) | (sum >>> (32 - S[i])))) >>> 0;
      a = tmp;
    }
    a0 = (a0 + a) >>> 0;
    b0 = (b0 + b) >>> 0;
    c0 = (c0 + c) >>> 0;
    d0 = (d0 + d) >>> 0;
  }
  const out = new Uint8Array(16);
  const ov = new DataView(out.buffer);
  [a0, b0, c0, d0].forEach((w, i) => ov.setUint32(i * 4, w, true));
  return toHex(out);
}
