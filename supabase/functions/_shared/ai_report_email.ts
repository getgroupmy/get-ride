/**
 * The ai-report-email function's work (migration 0280): for each schedule
 * the database handed over, the report run as the admin who made it, its
 * files (CSV, Excel, PDF), and one email to its recipients, either with
 * the files attached or with links that last 7 days. Each send is logged
 * (ai_report_send_log), sent, skipped or failed with the reason.
 *
 *   POST { ids: [schedule id, ...], reason: "scheduled" | "now" }
 *     -> { sent, skipped, failed }
 *
 * Callers: the database (x-push-secret, the push webhook's Vault secret,
 * as location-ping) or the service role. Never an admin's token: "Send
 * now" goes through ai_report_schedule_send_now, which checks the admin.
 *
 *     deno test supabase/functions/_shared/ai_report_email_test.ts
 */
import { type Catalogue, describePlan, type Plan, periodWords } from "./ai_report_plan.ts";
import { base64, type EmailAttachment, type EmailProvider, senderOk } from "./email.ts";
import { sameSecret, WEBHOOK_SECRET_HEADER } from "./push_auth.ts";
import { reportCsv, type ReportResult, reportPdf, reportXlsx } from "./report_files.ts";

export interface ScheduleJob {
  ok: boolean;
  error?: string;
  schedule?: {
    id: string;
    name: string;
    subject: string;
    message: string;
    formats: string[];
    link_only: boolean;
    skip_empty: boolean;
  };
  from?: string | null;
  recipients?: string[];
  report?: ReportResult;
  catalogue?: Catalogue;
}

export interface EmailJobDeps {
  serviceKeys: string[];
  webhookSecretOk(secret: string): Promise<boolean>;
  job(id: string): Promise<ScheduleJob>;
  provider(): Promise<EmailProvider | null>;
  logo(): Promise<{ bytes: Uint8Array; png: boolean } | null>;
  /** Keeps a file and answers a link to it that lasts 7 days. */
  keep(path: string, bytes: Uint8Array, contentType: string): Promise<string>;
  log(entry: {
    schedule: string;
    reason: string;
    rows: number | null;
    recipients: number;
    ok: boolean;
    skipped: boolean;
    error: string | null;
  }): Promise<void>;
  now(): Date;
}

/** Attachments above this go as links instead (the provider takes 40 MB a message). */
export const MAX_ATTACH_BYTES = 25 * 1024 * 1024;
export const LINK_DAYS = 7;

const TYPES: Record<string, { ext: string; mime: string; label: string }> = {
  csv: { ext: "csv", mime: "text/csv", label: "CSV" },
  xlsx: { ext: "xlsx", mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", label: "Excel" },
  pdf: { ext: "pdf", mime: "application/pdf", label: "PDF" },
};

export const NOT_SET_UP = "Email isn't set up yet: add the email key in API Keys.";

function slug(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 60) || "report";
}

/** "12 Oct 2026 to 18 Oct 2026", or "All time". */
export function periodText(r: ReportResult): string {
  return r.period ? periodWords({ from: r.period.from, to: r.period.to }) : "All time";
}

/** {report}, {period} and {rows} filled in. */
export function fillPlaceholders(template: string, v: { report: string; period: string; rows: number }): string {
  return template.replace(/\{report\}/g, v.report).replace(/\{period\}/g, v.period)
    .replace(/\{rows\}/g, v.rows.toLocaleString("en-US"));
}

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

/** Malaysia's time as "2026-10-24 08:00". */
function myt(d: Date): string {
  return new Date(d.getTime() + 8 * 3600_000).toISOString().slice(0, 16).replace("T", " ");
}

export interface EmailParts {
  subject: string;
  text: string;
  html: string;
}

export function emailBody(
  job: Required<Pick<ScheduleJob, "schedule" | "report">> & { catalogue?: Catalogue },
  files: { label: string; filename: string; url?: string }[],
  now: Date,
): EmailParts {
  const s = job.schedule, r = job.report;
  const v = { report: s.name, period: periodText(r), rows: r.row_count };
  const subject = fillPlaceholders(s.subject || "{report} for {period}", v).slice(0, 200);
  const message = fillPlaceholders(s.message ?? "", v).trim();
  const understood = job.catalogue
    ? describePlan(r.plan as Plan, job.catalogue, { resolved: r.period, columns: r.columns })
    : [["Data", r.dataset_label] as [string, string]];
  const lines = [
    ...(message ? [message, ""] : []),
    `${s.name}: ${v.period} (Malaysia time), ${v.rows.toLocaleString("en-US")} rows.`,
    ...(r.truncated ? [`Showing first ${r.max_rows.toLocaleString("en-US")} rows.`] : []),
    "",
    ...files.map((f) => f.url ? `${f.label}: ${f.url} (the link works for ${LINK_DAYS} days)` : `${f.label}: attached (${f.filename})`),
    "",
    "What the AI understood:",
    ...understood.map(([k, w]) => `  ${k}: ${w}`),
    "",
    `Made by GET.ride on ${myt(now)} (Malaysia time). Admin > Reports to change or stop this email.`,
  ];
  const html = `<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#17202b;line-height:1.5">` +
    (message ? message.split(/\n{2,}/).map((p) => `<p>${esc(p).replace(/\n/g, "<br>")}</p>`).join("") : "") +
    `<p><strong>${esc(s.name)}</strong>: ${esc(v.period)} (Malaysia time), ${v.rows.toLocaleString("en-US")} rows.` +
    (r.truncated ? ` Showing first ${r.max_rows.toLocaleString("en-US")} rows.` : "") + `</p>` +
    `<ul>${
      files.map((f) =>
        f.url
          ? `<li><a href="${esc(f.url)}">${esc(f.label)}: ${esc(f.filename)}</a> (the link works for ${LINK_DAYS} days)</li>`
          : `<li>${esc(f.label)}: attached (${esc(f.filename)})</li>`
      ).join("")
    }</ul>` +
    `<p style="margin-bottom:4px"><strong>What the AI understood</strong></p><table style="border-collapse:collapse;font-size:13px">${
      understood.map(([k, w]) => `<tr><td style="padding:2px 12px 2px 0;color:#5d6b7b;vertical-align:top">${esc(k)}</td><td style="padding:2px 0">${esc(w)}</td></tr>`).join("")
    }</table>` +
    `<p style="color:#5d6b7b;font-size:12px">Made by GET.ride on ${myt(now)} (Malaysia time). Admin &gt; Reports to change or stop this email.</p></div>`;
  return { subject, text: lines.join("\n"), html };
}

async function one(id: string, reason: string, deps: EmailJobDeps): Promise<"sent" | "skipped" | "failed"> {
  let job: ScheduleJob;
  try {
    job = await deps.job(id);
  } catch (e) {
    await deps.log({ schedule: id, reason, rows: null, recipients: 0, ok: false, skipped: false,
      error: `The report couldn't be run: ${e instanceof Error ? e.message : "error"}` });
    return "failed";
  }
  const fail = async (error: string, rows: number | null, recipients = 0) => {
    await deps.log({ schedule: id, reason, rows, recipients, ok: false, skipped: false, error });
    return "failed" as const;
  };
  if (!job.ok || !job.schedule || !job.report) return await fail(job.error ?? "The report couldn't be run.", null);
  const s = job.schedule, r = job.report;
  const to = [...new Set((job.recipients ?? []).map((e) => e.trim().toLowerCase()).filter(Boolean))];
  if (s.skip_empty && r.row_count === 0) {
    await deps.log({ schedule: id, reason, rows: 0, recipients: to.length, ok: true, skipped: true, error: null });
    return "skipped";
  }
  if (to.length === 0) return await fail("No one to send it to (the admins picked have no email).", r.row_count);
  const provider = await deps.provider();
  if (!provider) return await fail(NOT_SET_UP, r.row_count, to.length);
  if (!senderOk(job.from)) return await fail("The email sender isn't a valid address (Admin > Reports > Email sender).", r.row_count, to.length);

  const now = deps.now();
  const period = periodText(r);
  const base = `${slug(s.name)}-${r.period ? `${r.period.from}-to-${r.period.to}` : "all-time"}`;
  const understood = job.catalogue
    ? describePlan(r.plan as Plan, job.catalogue, { resolved: r.period, columns: r.columns })
    : [["Data", r.dataset_label] as [string, string]];
  const made: { label: string; filename: string; mime: string; bytes: Uint8Array }[] = [];
  try {
    for (const f of s.formats) {
      const t = TYPES[f];
      if (!t) continue;
      const bytes = f === "csv"
        ? new TextEncoder().encode(reportCsv(r))
        : f === "xlsx"
        ? reportXlsx(r, understood)
        : await reportPdf(r, { title: s.name, period: `${period} (Malaysia time)`, madeAt: myt(now), logo: await deps.logo() });
      made.push({ label: t.label, filename: `${base}.${t.ext}`, mime: t.mime, bytes });
    }
  } catch (e) {
    return await fail(`The files couldn't be made: ${e instanceof Error ? e.message : "error"}`, r.row_count, to.length);
  }
  const size = made.reduce((n, f) => n + f.bytes.length, 0);
  const asLinks = s.link_only || size > MAX_ATTACH_BYTES;
  const files: { label: string; filename: string; url?: string }[] = [];
  const attachments: EmailAttachment[] = [];
  try {
    for (const f of made) {
      if (asLinks) {
        const stamp = now.toISOString().replace(/[-:]/g, "").slice(0, 15);
        files.push({ label: f.label, filename: f.filename, url: await deps.keep(`${s.id}/${stamp}/${f.filename}`, f.bytes, f.mime) });
      } else {
        files.push({ label: f.label, filename: f.filename });
        attachments.push({ filename: f.filename, content: base64(f.bytes), contentType: f.mime });
      }
    }
  } catch (e) {
    return await fail(`The files couldn't be kept for the links: ${e instanceof Error ? e.message : "error"}`, r.row_count, to.length);
  }
  const body = emailBody({ schedule: s, report: r, catalogue: job.catalogue }, files, now);
  for (let i = 0; i < to.length; i += provider.maxRecipients) {
    const sent = await provider.send({
      from: job.from!.trim(),
      to: to.slice(i, i + provider.maxRecipients),
      subject: body.subject,
      text: body.text,
      html: body.html,
      attachments,
    });
    if (!sent.ok) return await fail(sent.error, r.row_count, to.length);
  }
  await deps.log({ schedule: id, reason, rows: r.row_count, recipients: to.length, ok: true, skipped: false, error: null });
  return "sent";
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function handleReportEmail(req: Request, deps: EmailJobDeps): Promise<Response> {
  const reply = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
  if (req.method !== "POST") return reply({ error: "POST only" }, 405);
  const secret = (req.headers.get(WEBHOOK_SECRET_HEADER) ?? "").trim();
  const bearer = /^Bearer\s+(.+)$/i.exec((req.headers.get("Authorization") ?? "").trim())?.[1]?.trim() ?? "";
  const allowed = secret
    ? await deps.webhookSecretOk(secret)
    : !!bearer && deps.serviceKeys.some((k) => k && sameSecret(bearer, k));
  if (!allowed) return reply({ error: "not_allowed" }, 401);
  const body = await req.json().catch(() => null) as { ids?: unknown; reason?: unknown } | null;
  const ids = Array.isArray(body?.ids) ? [...new Set(body!.ids.filter((x): x is string => typeof x === "string" && UUID.test(x)))].slice(0, 50) : [];
  if (ids.length === 0) return reply({ error: "ids required" }, 400);
  const reason = body?.reason === "now" ? "now" : "scheduled";
  const out = { sent: 0, skipped: 0, failed: 0 };
  for (const id of ids) out[await one(id, reason, deps)] += 1;
  return reply(out);
}
