/**
 * The uptime monitor's cloud half (migration 0318), behind the
 * `uptime-check` function. The NAS checks the same targets from the office;
 * this runs on a pg_cron schedule (uptime_cron) so a dead NAS, or a dead
 * office line, is still reported.
 *
 *   GET  ?ping=1                 -> { ok: true }   (the "Server functions" target)
 *   POST { action: "check" }     -> checks every cloud target, records them,
 *                                   then sends what alerts are waiting
 *   POST { action: "flush" }     -> sends the waiting alerts (Telegram, email)
 *
 * Callers: the database (x-push-secret, the push webhook's Vault secret) or
 * the service role. Telegram: the bot token in Admin -> API Keys ->
 * Telegram -> Bot. Email: Resend (_shared/email.ts).
 *
 *     deno test supabase/functions/_shared/uptime_test.ts
 */
import type { EmailProvider } from "./email.ts";
import { fillProject } from "./nas_ops.ts";

export type UptimeStatus = "up" | "slow" | "down";

export interface Target {
  id: string;
  name?: string;
  kind: "http" | "database";
  url?: string | null;
  slowMs?: number | null;
}

export interface CheckResult {
  id: string;
  status: UptimeStatus;
  ms: number | null;
  detail: string | null;
}

/** How long a check may take before it counts as down. */
export const CHECK_TIMEOUT_MS = 10_000;

/**
 * What one answer means: a server error (500 and up) or no answer is down;
 * anything else (even 401 or 404: the server is there) is up, or slow when
 * it took [slowMs] or longer.
 */
export function classify(httpStatus: number | null, ms: number, slowMs: number, error?: string | null): CheckResult["status"] {
  if (httpStatus === null || error) return "down";
  if (httpStatus >= 500) return "down";
  return ms >= slowMs ? "slow" : "up";
}

/** The words shown beside a check. */
export function describe(httpStatus: number | null, ms: number, error?: string | null): string {
  if (error) return error;
  if (httpStatus === null) return "No answer";
  return `HTTP ${httpStatus} in ${ms} ms`;
}

/** One web address, GET, timed. */
export async function checkHttp(
  t: Target,
  projectUrl: string,
  fetchFn: typeof fetch = fetch,
  now: () => number = () => performance.now(),
): Promise<CheckResult> {
  const url = fillProject(t.url, projectUrl);
  const slow = t.slowMs ?? 3000;
  if (!url || !/^https?:\/\//.test(url)) return { id: t.id, status: "down", ms: null, detail: "No address" };
  const started = now();
  let status: number | null = null;
  let error: string | null = null;
  try {
    const res = await fetchFn(url, {
      method: "GET",
      redirect: "follow",
      headers: { "user-agent": "get.ride uptime monitor" },
      signal: AbortSignal.timeout(CHECK_TIMEOUT_MS),
    });
    status = res.status;
    await res.body?.cancel().catch(() => {});
  } catch (e) {
    const name = e instanceof Error ? e.name : "Error";
    error = name === "TimeoutError" || name === "AbortError" ? `No answer in ${CHECK_TIMEOUT_MS / 1000} s` : `Couldn't connect (${name})`;
  }
  const ms = Math.max(0, Math.round(now() - started));
  return { id: t.id, status: classify(status, ms, slow, error), ms, detail: describe(status, ms, error) };
}

/** The database, through its API: a query that answers at once. */
export async function checkDatabase(
  t: Target,
  ping: () => Promise<void>,
  now: () => number = () => performance.now(),
): Promise<CheckResult> {
  const started = now();
  try {
    await ping();
  } catch (e) {
    const ms = Math.round(now() - started);
    return { id: t.id, status: "down", ms, detail: `Query failed: ${String((e as Error)?.message ?? e).slice(0, 120)}` };
  }
  const ms = Math.max(0, Math.round(now() - started));
  return { id: t.id, status: ms >= (t.slowMs ?? 3000) ? "slow" : "up", ms, detail: `Answered in ${ms} ms` };
}

export interface Alert {
  id: string;
  kind: string;
  title: string;
  body: string;
  created_at?: string;
  telegram: boolean;
  email: boolean;
}

export interface AlertsDue {
  telegramChats: string[];
  emails: string[];
  emailFrom: string | null;
  alerts: Alert[];
}

/** An alert as one message: "get.ride monitor · DOWN\ngetride.my is down\n…". */
export function alertText(a: Pick<Alert, "kind" | "title" | "body">): string {
  const mark = ({ down: "DOWN", resolved: "RESOLVED", test: "TEST" } as Record<string, string>)[a.kind] ?? "FAILED";
  return `get.ride monitor · ${mark}\n${a.title}\n${a.body}`.slice(0, 3500);
}

/** Telegram's sendMessage. "sent", or why not (the token never appears). */
export async function telegramSend(
  token: string,
  chat: string,
  text: string,
  fetchFn: typeof fetch = fetch,
): Promise<string> {
  let res: Response;
  try {
    res = await fetchFn(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chat, text, disable_web_page_preview: true }),
      signal: AbortSignal.timeout(15_000),
    });
  } catch (e) {
    return `Couldn't reach Telegram (${e instanceof Error ? e.name : "network"})`;
  }
  const body = await res.json().catch(() => null) as { ok?: boolean; description?: string } | null;
  if (res.ok && body?.ok !== false) return "sent";
  return `Telegram refused (${res.status}): ${String(body?.description ?? "").split(token).join("••••").slice(0, 200)}`;
}

export interface FlushDeps {
  rpc(name: string, args: Record<string, unknown>): Promise<unknown>;
  telegramToken(): Promise<string | null>;
  email(): Promise<EmailProvider | null>;
  fetchFn?: typeof fetch;
}

/** Sends the waiting Telegram and email alerts; how many were handled. */
export async function flushAlerts(deps: FlushDeps): Promise<number> {
  const due = (await deps.rpc("uptime_alerts_due", {})) as AlertsDue | null;
  const alerts = due?.alerts ?? [];
  if (!alerts.length) return 0;
  const token = alerts.some((a) => a.telegram) ? await deps.telegramToken() : null;
  const mail = alerts.some((a) => a.email) ? await deps.email() : null;
  for (const a of alerts) {
    let tg: string | null = null;
    let em: string | null = null;
    if (a.telegram) {
      if (!token) {
        tg = "No Telegram bot token in Admin > API Keys";
      } else {
        const results = [];
        for (const chat of due!.telegramChats ?? []) results.push(await telegramSend(token, chat, alertText(a), deps.fetchFn));
        tg = results.find((r) => r !== "sent") ?? "sent";
      }
    }
    if (a.email) {
      if (!mail) {
        em = "No Resend key in Admin > API Keys";
      } else if (!due!.emailFrom) {
        em = "No sender address";
      } else {
        const r = await mail.send({
          from: due!.emailFrom,
          to: (due!.emails ?? []).slice(0, mail.maxRecipients),
          subject: `get.ride monitor: ${a.title}`,
          text: a.body,
          html: `<p><b>${escapeHtml(a.title)}</b></p><p>${escapeHtml(a.body)}</p>`,
        });
        em = r.ok ? "sent" : r.error;
      }
    }
    await deps.rpc("uptime_alert_sent", { p_id: a.id, p_telegram: tg, p_email: em });
  }
  return alerts.length;
}

export function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

export interface UptimeDeps extends FlushDeps {
  projectUrl: string;
  /** Whether the caller is the database (x-push-secret) or the service role. */
  callerOk(req: Request): Promise<boolean>;
  /** The database check: throws when it fails. */
  ping(): Promise<void>;
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });

export async function handleUptime(req: Request, deps: UptimeDeps): Promise<Response> {
  if (req.method === "GET") {
    return new URL(req.url).searchParams.has("ping") ? json({ ok: true }) : json({ error: "Not found" }, 404);
  }
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  if (!(await deps.callerOk(req))) return json({ error: "Unauthorized" }, 401);
  const input = await req.json().catch(() => ({})) as { action?: string };
  let checked = 0;
  if (input?.action !== "flush") {
    const targets = ((await deps.rpc("uptime_targets_for", { p_source: "cloud" })) ?? []) as Target[];
    const results = await Promise.all(targets.map((t) =>
      t.kind === "database" ? checkDatabase(t, deps.ping) : checkHttp(t, deps.projectUrl, deps.fetchFn)
    ));
    if (results.length) await deps.rpc("uptime_record", { p_source: "cloud", p_results: results });
    checked = results.length;
  }
  const sent = await flushAlerts(deps);
  return json({ checked, sent });
}
