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
};

export interface SendBody {
  title?: string;
  body?: string;
  audience?: string;
  /** Target a single profile's devices instead of a broadcast audience. */
  profileId?: string;
  data?: Record<string, unknown>;
}

export function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

export async function handleSendPush(
  req: Request,
  deps: { auth: PushAuthDeps; dispatch(payload: SendBody): Promise<Response> },
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
  return await deps.dispatch(payload);
}
