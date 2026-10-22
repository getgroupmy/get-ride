/**
 * freight-notify: the recipient of a freight delivery is sent its tracking
 * link when the trip starts (migration 0267). Pure parts, so they can be
 * tested without a database:
 *
 *   * who may ask: the database job (`x-push-secret`, the push webhook's
 *     existing Vault secret, checked by `push_webhook_secret_ok`), the
 *     service-role key, or the signed-in driver or rider of the ride asked
 *     about (`freight_notice_caller_ok`);
 *   * the message: the notice's text and the ride's share link (0108),
 *     and for a courier delivery (0268) the confirmation code, which the
 *     database hands over only here (never stored in the notice row the
 *     driver can read);
 *   * WhatsApp: a Business Cloud API text message, with the token and the
 *     sending number's id from this function's own secrets
 *     (WHATSAPP_TOKEN, WHATSAPP_PHONE_NUMBER_ID). Without them a WhatsApp
 *     notice fails with a reason and the SMS one still goes.
 *
 *     deno test supabase/functions/_shared/freight_notify_test.ts
 */

export const SHARE_BASE_DEFAULT = "https://getride.my";

export interface Notice {
  id: string;
  channel: "sms" | "whatsapp";
  to_phone: string;
  body: string;
  share_token: string | null;
  /** A courier delivery's code (0268); absent before 0268 or for freight. */
  delivery_code?: string | null;
}

/** The text sent: the notice's words, the link and, for a courier, the code. */
export function noticeText(n: Notice, base = SHARE_BASE_DEFAULT): string {
  const link = n.share_token ? `${base.replace(/\/+$/, "")}/share/${n.share_token}` : "";
  const code = n.delivery_code && /^[0-9]{4}$/.test(n.delivery_code)
    ? ` Your delivery code is ${n.delivery_code}. Give it to the courier only once you have the parcel.`
    : "";
  return `${`${n.body}${link}`.trim()}${code}`.trim().slice(0, 600);
}

/** A phone number as the WhatsApp API takes it: digits only. */
export function whatsappNumber(phone: string): string {
  return phone.replace(/[^0-9]/g, "");
}

/** The Cloud API request for one WhatsApp text, or null without its secrets. */
export function whatsappRequest(
  n: Notice,
  text: string,
  env: { token?: string; phoneNumberId?: string },
): { url: string; init: RequestInit } | null {
  if (!env.token || !env.phoneNumberId) return null;
  return {
    url: `https://graph.facebook.com/v19.0/${encodeURIComponent(env.phoneNumberId)}/messages`,
    init: {
      method: "POST",
      headers: { "Authorization": `Bearer ${env.token}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        messaging_product: "whatsapp",
        to: whatsappNumber(n.to_phone),
        type: "text",
        text: { preview_url: true, body: text },
      }),
    },
  };
}

/** The ride a request body names, if it is a UUID. */
export function rideIdOf(body: unknown): string | null {
  const v = (body as { rideId?: unknown } | null)?.rideId;
  return typeof v === "string" && /^[0-9a-f-]{36}$/i.test(v) ? v : null;
}

export type Caller = "job" | "service" | "user" | null;

/**
 * Who is calling: the job (the secret header), the service role, or a user
 * (a bearer that is not the service key, checked against the ride later).
 */
export async function callerOf(
  req: Request,
  deps: { serviceKey: string; secretOk(secret: string): Promise<boolean> },
): Promise<{ caller: Caller; bearer: string | null }> {
  const secret = (req.headers.get("x-push-secret") ?? "").trim();
  if (secret) return { caller: (await deps.secretOk(secret)) ? "job" : null, bearer: null };
  const m = /^Bearer\s+(.+)$/i.exec((req.headers.get("authorization") ?? "").trim());
  const bearer = m ? m[1].trim() : null;
  if (!bearer) return { caller: null, bearer: null };
  if (deps.serviceKey && bearer === deps.serviceKey) return { caller: "service", bearer };
  return { caller: "user", bearer };
}
