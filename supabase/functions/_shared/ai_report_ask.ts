/**
 * The ai-report function's work (migration 0280): an admin's request in
 * plain words, turned into a checked report plan by the AI service set in
 * API Keys (Admin -> Fare AI's provider and keys). The AI is sent the
 * request and the caller's catalogue, never a row; its answer must be a
 * plan that passes checkPlan, else it is asked once more with the reason.
 *
 *   GET                 -> { ai: { ready }, email: { ready, from, sender_ok } }
 *   POST { request }    -> { ok: true, plan } | { ok: false, error, reason }
 *
 * Callers: admins who may run reports (the catalogue read with their own
 * token says so), each at most ASKS_PER_WINDOW times per ASK_WINDOW.
 *
 *     deno test supabase/functions/_shared/ai_report_ask_test.ts
 */
import { type AIServiceConfig, type CallResult, callProvider, jsonObjectIn, type Provider, serviceOf } from "./ai_providers.ts";
import { type Catalogue, checkPlan, malaysiaToday, type Plan, REPORT_SYSTEM, reportPrompt } from "./ai_report_plan.ts";
import { senderOk } from "./email.ts";

export const ASKS_PER_WINDOW = 30;
export const ASK_WINDOW = "10 minutes";

export interface AskDeps {
  /** The caller's catalogue, read with their token: null when the token isn't accepted, "forbidden" when not a Reports admin. */
  catalogue(authorization: string): Promise<Catalogue | null | "forbidden">;
  userId(authorization: string): Promise<string | null>;
  /** Seconds to wait (0: go ahead); null when the limit can't be checked. */
  rateTake(userId: string): Promise<number | null>;
  aiConfig(): Promise<AIServiceConfig | null>;
  /** The key ids cooling down after failures (Fare AI's counters). */
  coolingKeys(ids: string[]): Promise<Set<string>>;
  email(): Promise<{ keySet: boolean; from: string | null }>;
  audit(userId: string, detail: Record<string, unknown>): Promise<void>;
  call?: (provider: Provider, prompt: string, key: string, model: string) => Promise<CallResult>;
  now(): Date;
}

export const NO_AI = "No AI service is set up yet: add a key for the AI service in API Keys.";

const json = (body: unknown, status = 200) => ({ status, body });

export interface AskAnswer {
  status: number;
  body: unknown;
}

export async function handleAsk(method: string, authorization: string | null, input: unknown, deps: AskDeps): Promise<AskAnswer> {
  if (!authorization || !/^Bearer\s+\S+/i.test(authorization)) return json({ ok: false, error: "not_signed_in" }, 401);
  const cat = await deps.catalogue(authorization);
  if (cat === null) return json({ ok: false, error: "not_signed_in" }, 401);
  if (cat === "forbidden") return json({ ok: false, error: "admin_only" }, 403);

  const config = await deps.aiConfig();
  const service = serviceOf(config);
  if (method === "GET") {
    const email = await deps.email();
    return json({
      ai: { ready: service.keys.length > 0 },
      email: { ready: email.keySet && senderOk(email.from), key_set: email.keySet, from: email.from, sender_ok: senderOk(email.from) },
    });
  }
  if (method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);

  const request = typeof (input as { request?: unknown })?.request === "string"
    ? ((input as { request: string }).request).trim()
    : "";
  if (request.length < 3) return json({ ok: false, error: "empty", reason: "Type what report you need." }, 400);
  if (request.length > 1000) return json({ ok: false, error: "too_long", reason: "Keep the request under 1,000 characters." }, 400);

  const uid = await deps.userId(authorization);
  if (!uid) return json({ ok: false, error: "not_signed_in" }, 401);
  const wait = await deps.rateTake(uid);
  if (wait === null) return json({ ok: false, error: "unavailable", reason: "Try again in a moment." }, 503);
  if (wait > 0) {
    return json({ ok: false, error: "rate_limited", retry_after: wait, reason: `Too many requests: try again in ${Math.ceil(wait / 60)} min.` }, 429);
  }

  const cooling = service.keys.length ? await deps.coolingKeys(service.keys.map((k) => k.id)) : new Set<string>();
  const keys = service.keys.filter((k) => !cooling.has(k.id));
  if (keys.length === 0) {
    return json({ ok: false, error: "ai_not_set_up", reason: service.keys.length ? "The AI service's keys are resting after errors: try again later." : NO_AI });
  }

  const call = deps.call ??
    ((p: Provider, prompt: string, key: string, model: string) =>
      callProvider(p, prompt, key, model, { systemInstruction: REPORT_SYSTEM, temperature: 0, maxTokens: 1200 }));
  const today = malaysiaToday(deps.now());
  let rejected: string | undefined;
  let lastError = "The AI service didn't answer.";
  for (let attempt = 0; attempt < 2; attempt++) {
    const prompt = reportPrompt(request, cat, today, rejected);
    let content: string | null = null;
    for (const k of keys) {
      let r: CallResult;
      try {
        r = await call(service.provider, prompt, k.key, service.model);
      } catch (e) {
        r = { content: null, httpStatus: null, error: e instanceof Error ? e.name : "error" };
      }
      if (r.content) {
        content = r.content;
        break;
      }
      lastError = "The AI service didn't answer. Try again in a moment.";
    }
    if (content === null) break;
    const checked = checkPlan(jsonObjectIn(content), cat);
    if (checked.ok) {
      await deps.audit(uid, { request: request.slice(0, 500), ok: true, dataset: checked.plan.dataset, attempts: attempt + 1 });
      return json({ ok: true, plan: checked.plan satisfies Plan });
    }
    rejected = checked.reason;
    lastError = `The AI's answer didn't fit the data: ${checked.reason} Try saying it another way.`;
  }
  await deps.audit(uid, { request: request.slice(0, 500), ok: false, reason: lastError });
  return json({ ok: false, error: "not_understood", reason: lastError });
}
