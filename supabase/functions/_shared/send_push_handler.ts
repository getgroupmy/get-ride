/**
 * The request half of send-push: method, caller check, body. The sending
 * itself is `dispatch` (send-push/index.ts), so the gate can be tested
 * without devices.
 *
 *     deno test supabase/functions/_shared/send_push_handler_test.ts
 */
import { authorizePush, type PushAuthDeps } from "./push_auth.ts";

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "7200",
};

export interface SendBody {
  title?: string;
  body?: string;
  audience?: string;
  /** Target a single profile's devices instead of a broadcast audience. */
  profileId?: string;
  /** With the partner audience: approved partners only. */
  approvedOnly?: boolean;
  /** Profiles a broadcast skips (a ride request's own rider). */
  excludeProfileIds?: string[];
  /** Only the phones last seen here (0168). */
  area?: unknown;
  /** Count who it would reach; send nothing. */
  dryRun?: boolean;
  data?: Record<string, unknown>;
  /** A picture shown large in the notification: an https address (0279). */
  image?: string;
  /** The full message the push opens in the app (push_messages, 0279). */
  messageId?: string;
  /** With the partner audience: only partners of these types (any of them). */
  partnerTypes?: string[];
  /** The push_schedules row this send is for; taken from the database only. */
  scheduleId?: string;
}

/** Who is asking (authorizePush): a schedule id counts from the database only. */
export type SendCaller = "webhook" | "service" | "admin";

export function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

export async function handleSendPush(
  req: Request,
  deps: { auth: PushAuthDeps; dispatch(payload: SendBody, caller: SendCaller): Promise<Response> },
): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const auth = await authorizePush(req, deps.auth);
  if (!auth.ok) return json({ error: auth.error }, auth.status);

  let payload: SendBody;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }
  return await deps.dispatch(payload, auth.caller);
}
