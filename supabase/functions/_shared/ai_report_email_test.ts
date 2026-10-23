import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.19";

import { emailBody, type EmailJobDeps, fillPlaceholders, handleReportEmail, NOT_SET_UP, type ScheduleJob } from "./ai_report_email.ts";
import { fullCatalogue } from "./ai_report_fixture.ts";
import type { EmailMessage, EmailProvider } from "./email.ts";
import type { ReportResult } from "./report_files.ts";

const SID = "00000000-0000-0000-0000-000000000280";
const report: ReportResult = {
  dataset: "rides",
  dataset_label: "Rides",
  columns: [
    { id: "service", label: "Service", type: "text", role: "group", field: "service" },
    { id: "count", label: "Count", type: "number", role: "measure", field: "*", agg: "count" },
  ],
  rows: [["Car", 3], ["Motor", 1]],
  totals: [4],
  row_count: 2,
  truncated: false,
  max_rows: 50000,
  period: { from: "2026-10-12", to: "2026-10-18", preset: "previous_week", field: "created_at" },
  plan: {
    dataset: "rides",
    columns: [],
    filters: [],
    period: { preset: "previous_week", field: "created_at" },
    group_by: ["service"],
    measures: [{ field: "*", agg: "count" }],
    sort: [],
    limit: null,
    title: "",
  },
};
const job = (over: Partial<ScheduleJob["schedule"]> = {}, r: Partial<ReportResult> = {}): ScheduleJob => ({
  ok: true,
  schedule: {
    id: SID,
    name: "Weekly rides",
    subject: "{report} for {period}",
    message: "Hello team,\n\n{rows} rows this time.",
    formats: ["csv", "xlsx"],
    link_only: false,
    skip_empty: true,
    ...over,
  },
  from: "GET.ride Reports <reports@getride.my>",
  recipients: ["Boss@Example.com", "boss@example.com", "ops@example.com"],
  report: { ...report, ...r },
  catalogue: fullCatalogue,
});

function deps(j: ScheduleJob, provider: "ok" | "none" | "refuse" = "ok") {
  const sent: EmailMessage[] = [];
  const logs: Parameters<EmailJobDeps["log"]>[0][] = [];
  const kept: string[] = [];
  const p: EmailProvider = {
    id: "fake",
    label: "Fake",
    maxRecipients: 50,
    send: (m) => {
      sent.push(m);
      return Promise.resolve(provider === "refuse" ? { ok: false, error: "Resend refused (403): domain not verified" } : { ok: true, id: "e1" });
    },
  };
  const d: EmailJobDeps = {
    serviceKeys: ["service-key"],
    webhookSecretOk: (s) => Promise.resolve(s === "db-secret"),
    job: () => Promise.resolve(j),
    provider: () => Promise.resolve(provider === "none" ? null : p),
    logo: () => Promise.resolve(null),
    keep: (path) => {
      kept.push(path);
      return Promise.resolve(`https://files.example/${path}?token=t`);
    },
    log: (e) => {
      logs.push(e);
      return Promise.resolve();
    },
    now: () => new Date("2026-10-19T00:00:00Z"),
  };
  return { d, sent, logs, kept };
}

const post = (headers: Record<string, string>, body: unknown = { ids: [SID], reason: "scheduled" }) =>
  new Request("https://x/functions/v1/ai-report-email", { method: "POST", headers, body: JSON.stringify(body) });

Deno.test("only the database's secret or the service role", async () => {
  const t = deps(job());
  assertEquals((await handleReportEmail(post({}), t.d)).status, 401);
  assertEquals((await handleReportEmail(post({ "x-push-secret": "wrong" }), t.d)).status, 401);
  assertEquals((await handleReportEmail(post({ Authorization: "Bearer admin-jwt" }), t.d)).status, 401);
  assertEquals((await handleReportEmail(post({ Authorization: "Bearer service-key" }, { ids: ["nope"] }), t.d)).status, 400);
  assertEquals(t.sent.length, 0);
});

Deno.test("sent once to each address, with the files attached and the plan in words", async () => {
  const t = deps(job());
  const r = await handleReportEmail(post({ "x-push-secret": "db-secret" }), t.d);
  assertEquals(await r.json(), { sent: 1, skipped: 0, failed: 0 });
  const m = t.sent[0];
  assertEquals(m.to, ["boss@example.com", "ops@example.com"]);
  assertEquals(m.subject, "Weekly rides for 12 Oct 2026 to 18 Oct 2026");
  assertEquals(m.attachments?.map((a) => a.filename), [
    "weekly-rides-2026-10-12-to-2026-10-18.csv",
    "weekly-rides-2026-10-12-to-2026-10-18.xlsx",
  ]);
  assertStringIncludes(m.text, "2 rows this time.");
  assertStringIncludes(m.text, "What the AI understood:");
  assertStringIncludes(m.text, "Group by: Service");
  assertEquals(t.logs[0], { schedule: SID, reason: "scheduled", rows: 2, recipients: 2, ok: true, skipped: false, error: null });
});

Deno.test("link only: the files are kept and linked for 7 days, nothing attached", async () => {
  const t = deps(job({ link_only: true, formats: ["pdf"] }));
  await handleReportEmail(post({ Authorization: "Bearer service-key" }, { ids: [SID], reason: "now" }), t.d);
  assertEquals(t.sent[0].attachments, []);
  assertEquals(t.kept.length, 1);
  assert(t.kept[0].startsWith(`${SID}/`) && t.kept[0].endsWith(".pdf"));
  assertStringIncludes(t.sent[0].html, "the link works for 7 days");
  assertEquals(t.logs[0].reason, "now");
});

Deno.test("skip when empty; no email set up; a refusal is logged with its reason", async () => {
  const empty = deps(job({}, { rows: [], row_count: 0, totals: [0] }));
  assertEquals(await (await handleReportEmail(post({ "x-push-secret": "db-secret" }), empty.d)).json(), { sent: 0, skipped: 1, failed: 0 });
  assertEquals(empty.logs[0].skipped, true);
  assertEquals(empty.sent.length, 0);

  const none = deps(job(), "none");
  await handleReportEmail(post({ "x-push-secret": "db-secret" }), none.d);
  assertEquals(none.logs[0].error, NOT_SET_UP);

  const refused = deps(job(), "refuse");
  await handleReportEmail(post({ "x-push-secret": "db-secret" }), refused.d);
  assertEquals(refused.logs[0].ok, false);
  assertStringIncludes(refused.logs[0].error!, "domain not verified");

  const gone = deps({ ok: false, error: "The admin who made this schedule no longer has access to Reports." });
  await handleReportEmail(post({ "x-push-secret": "db-secret" }), gone.d);
  assertStringIncludes(gone.logs[0].error!, "no longer has access");
});

Deno.test("placeholders and a cut report", () => {
  assertEquals(fillPlaceholders("{report}: {rows} rows, {period}", { report: "R", period: "P", rows: 12345 }), "R: 12,345 rows, P");
  const j = job({}, { truncated: true, row_count: 50000 });
  const b = emailBody({ schedule: j.schedule!, report: j.report!, catalogue: j.catalogue }, [], new Date("2026-10-19T00:00:00Z"));
  assertStringIncludes(b.text, "Showing first 50,000 rows.");
  assertStringIncludes(b.text, "on 2026-10-19 08:00 (Malaysia time)");
});
