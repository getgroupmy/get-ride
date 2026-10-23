/**
 * Sending email from an edge function (migration 0280: the Reports
 * schedules). One small provider layer, so another service can be added
 * beside Resend without touching the callers:
 *
 *   * the key is Admin -> API Keys -> Email -> Resend (app setting
 *     `api_providers`, provider "email", service "resend", the first key
 *     that is on), else the function secret RESEND_API_KEY;
 *   * the sender is Admin -> Reports -> Email sender
 *     (ai_report_settings.email_from), e.g. "GET.ride Reports
 *     <reports@getride.my>"; its domain must be verified with Resend.
 *
 * The key is never logged or returned.
 *
 *     deno test supabase/functions/_shared/email_test.ts
 */

export interface EmailAttachment {
  filename: string;
  /** The file, base64. */
  content: string;
  contentType?: string;
}

export interface EmailMessage {
  from: string;
  to: string[];
  subject: string;
  text: string;
  html: string;
  attachments?: EmailAttachment[];
}

export type SendOutcome = { ok: true; id: string | null } | { ok: false; error: string };

export interface EmailProvider {
  id: string;
  label: string;
  /** Most recipients one message may carry. */
  maxRecipients: number;
  send(message: EmailMessage): Promise<SendOutcome>;
}

/** Resend's HTTPS API (https://resend.com/docs/api-reference/emails/send-email). */
export function resendProvider(apiKey: string, fetchFn: typeof fetch = fetch): EmailProvider {
  return {
    id: "resend",
    label: "Resend",
    maxRecipients: 50,
    async send(m) {
      let res: Response;
      try {
        res = await fetchFn("https://api.resend.com/emails", {
          method: "POST",
          headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            from: m.from,
            to: m.to,
            subject: m.subject,
            text: m.text,
            html: m.html,
            ...(m.attachments?.length
              ? { attachments: m.attachments.map((a) => ({ filename: a.filename, content: a.content })) }
              : {}),
          }),
          signal: AbortSignal.timeout(30_000),
        });
      } catch (e) {
        return { ok: false, error: `Couldn't reach Resend: ${e instanceof Error ? e.name : "network"}` };
      }
      const body = await res.json().catch(() => null) as { id?: string; message?: string; name?: string } | null;
      if (!res.ok) {
        const why = body?.message ?? body?.name ?? `HTTP ${res.status}`;
        return { ok: false, error: `Resend refused (${res.status}): ${String(why).split(apiKey).join("••••").slice(0, 300)}` };
      }
      return { ok: true, id: typeof body?.id === "string" ? body.id : null };
    },
  };
}

interface KeyEntry {
  value?: unknown;
  disabled?: unknown;
}

/** The first key that is on for [provider] / [service] in Admin -> API Keys. */
export function apiKeyFrom(apiProviders: unknown, provider: string, service: string): string | null {
  const list = Array.isArray(apiProviders) ? apiProviders : (apiProviders as { providers?: unknown })?.providers;
  if (!Array.isArray(list)) return null;
  const p = list.find((x) => x?.id === provider);
  const s = (Array.isArray(p?.services) ? p.services : []).find((x: { id?: string }) => x?.id === service);
  for (const k of (Array.isArray(s?.keys) ? s.keys : []) as KeyEntry[]) {
    const v = typeof k?.value === "string" ? k.value.trim() : "";
    if (v && k?.disabled !== true) return v;
  }
  return null;
}

export const EMAIL_PROVIDER = "email";
export const RESEND_SERVICE = "resend";

/** The provider to send with, or null when no key is set anywhere. */
export function emailProvider(
  apiProviders: unknown,
  env: (name: string) => string | undefined,
  fetchFn: typeof fetch = fetch,
): EmailProvider | null {
  const key = apiKeyFrom(apiProviders, EMAIL_PROVIDER, RESEND_SERVICE) ?? (env("RESEND_API_KEY")?.trim() || null);
  return key ? resendProvider(key, fetchFn) : null;
}

/** A sender the provider will take: "Name <a@b.c>" or "a@b.c". */
export function senderOk(from: string | null | undefined): boolean {
  const s = (from ?? "").trim();
  const addr = /<([^<>]+)>$/.exec(s)?.[1] ?? s;
  return /^[^@\s<>]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/.test(addr);
}

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/** Bytes as base64, without building one huge string of characters first. */
export function base64(bytes: Uint8Array): string {
  const out: string[] = [];
  let chunk = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i], b = bytes[i + 1], c = bytes[i + 2];
    chunk += B64[a >> 2] + B64[((a & 3) << 4) | ((b ?? 0) >> 4)] +
      (b === undefined ? "=" : B64[((b & 15) << 2) | ((c ?? 0) >> 6)]) +
      (c === undefined ? "=" : B64[c & 63]);
    if (chunk.length >= 65536) {
      out.push(chunk);
      chunk = "";
    }
  }
  out.push(chunk);
  return out.join("");
}
