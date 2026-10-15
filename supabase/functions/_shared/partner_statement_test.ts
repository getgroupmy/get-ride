/**
 * Partner statements (migration 0201): the request, the words, the summary
 * rows, the PDF, and when a statement is kept, remade or revised.
 *
 *     deno test supabase/functions/_shared/partner_statement_test.ts
 */
import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1.0.19";
import { PDFDocument } from "npm:pdf-lib@1.17.1";

import {
  day,
  DEFAULT_VERIFY_URL,
  fileName,
  handleStatement,
  latin1,
  money,
  myt,
  parseRequest,
  periodLabel,
  renderStatement,
  type StatementData,
  type StatementDeps,
  statementHash,
  type StatementRow,
  summaryRows,
  verifyLink,
  words,
} from "./partner_statement.ts";

const totals = {
  fare: 48, surcharges: 5, platformCollected: 2, surchargesPass: 2, taxes: 1.74, tolls: 3, otherCharges: 0,
  commission: 7.2, platformFees: 2, coins: 4, cash: 29.74, distanceKm: 18.5, trips: 2, incentives: 10,
  handoverIn: 6, handoverOut: 1.5, adjustments: -2, onlineHours: 12.25, totalEarnings: 71, totalDeductions: 10.7,
  net: 58.3, passThrough: 6.74,
};

function sample(over: Partial<StatementData> = {}): StatementData {
  return {
    type: "weekly",
    periodStart: "2026-09-07",
    periodEnd: "2026-09-13",
    status: "final",
    lang: "en",
    partner: { name: "Ahmad Bin Ali", displayId: "GR201A", ic: "******-**-5678", plate: "WXY 201", bank: null },
    company: { name: "PUNCAK NIAGA BERSAMA SDN. BHD.", ssm: "202201025129 (1470826-D)", support: "+6012-5252255" },
    weekStart: "monday",
    totals,
    incentives: [{ at: "2026-09-09T00:00:00Z", label: "Rainy day bonus", amount: 10 }],
    adjustments: [{ at: "2026-09-10T04:00:00Z", reason: "Toll refunded twice", amount: -2 }],
    breakdown: Array.from({ length: 7 }, (_, i) => ({
      start: `2026-09-${String(7 + i).padStart(2, "0")}`,
      totals: i === 1 ? { trips: 1, totalEarnings: 27, net: 22 } : { trips: 0, totalEarnings: 0, net: 0 },
    })),
    trips: [{
      at: "2026-09-08T02:00:00Z", service: "car", pickup: "KLCC", drop: "Mid Valley", payment: "cash",
      lines: { fare: 20, surcharges: 5, platformCollected: 2, commission: 3 },
    }],
    ...over,
  };
}

Deno.test("requests: a period type, a date and a language", () => {
  assertEquals(parseRequest({ type: "weekly", start: "2026-09-07", lang: "ms" }),
    { type: "weekly", start: "2026-09-07", lang: "ms" });
  assertEquals(parseRequest({ type: "monthly", start: "2026-09-01" })?.lang, "en");
  assertEquals(parseRequest({ type: "daily", start: "2026-09-07" }), null);
  assertEquals(parseRequest({ type: "weekly", start: "7/9/2026" }), null);
  assertEquals(parseRequest({ type: "weekly", start: "2026-13-45" }), null);
  assertEquals(parseRequest(null), null);
});

Deno.test("formatting: money, dates, Malaysia time, periods, file names", () => {
  assertEquals(money(1234.5), "1,234.50");
  assertEquals(money(-7.2), "-7.20");
  assertEquals(money(undefined), "0.00");
  assertEquals(day("2026-09-07", "en"), "7 Sep 2026");
  assertEquals(day("2026-08-07", "ms"), "7 Ogo 2026");
  assertEquals(myt("2026-09-07T16:30:00Z"), "2026-09-08 00:30");
  assertEquals(periodLabel(sample(), "en"), "7 Sep 2026 – 13 Sep 2026");
  assertEquals(periodLabel({ type: "monthly", periodStart: "2026-03-01", periodEnd: "2026-03-31" }, "ms"), "Mac 2026");
  assertEquals(periodLabel({ type: "annual", periodStart: "2026-01-01", periodEnd: "2026-12-31" }, "en"), "2026");
  assertEquals(fileName(sample(), "ms"), "getride-statement-weekly-2026-09-07-ms.pdf");
  assertEquals(latin1("Café – “ok” 你好"), 'Café - "ok" ??');
});

Deno.test("verify links: the admin's base, else getride.my", () => {
  assertEquals(verifyLink("", "abc"), `${DEFAULT_VERIFY_URL}/abc`);
  assertEquals(verifyLink("http://x.test", "abc"), `${DEFAULT_VERIFY_URL}/abc`);
  assertEquals(verifyLink("https://www.getride.my/verify/", "abc"), "https://www.getride.my/verify/abc");
});

Deno.test("summary: earnings, deductions, net, then what passes through", () => {
  const rows = summaryRows(totals, words("en"));
  const amount = (label: string) => rows.find((r) => r.label === label)?.amount;
  assertEquals(amount("Fares"), 48);
  assertEquals(amount("Total earnings"), 71);
  assertEquals(amount("Commission"), -7.2);
  assertEquals(amount("Total deductions"), -10.7);
  assertEquals(amount("Net earnings"), 58.3);
  assertEquals(amount("Taxes"), 1.74);
  assertEquals(amount("GET.coin"), 4);
  assertEquals(rows.find((r) => r.label === "Hours online")?.text, "12.3");
  // Taxes and tolls sit after the net, under their own heading.
  const idx = (label: string) => rows.findIndex((r) => r.label === label);
  assert(idx("Net earnings") < idx("Collected for others (not income)"));
  assert(idx("Collected for others (not income)") < idx("Taxes"));
  // Lines that are nothing are left out.
  assertEquals(rows.some((r) => r.label === "Other charges"), false);
  const quiet = summaryRows({ ...totals, handoverIn: 0, handoverOut: 0, adjustments: 0 }, words("ms"));
  assertEquals(quiet.some((r) => r.label === "Pelarasan"), false);
  assertEquals(quiet.find((r) => r.label === "Pendapatan bersih")?.amount, 58.3);
});

Deno.test("the hash: same numbers, same hash; a changed number, a new one", async () => {
  const a = await statementHash(sample());
  assertEquals(a, await statementHash(sample({ lang: "ms", status: "provisional" })));
  assertNotEquals(a, await statementHash(sample({ totals: { ...totals, net: 58.31 } })));
  assertEquals(a.length, 64);
});

for (const lang of ["en", "ms"] as const) {
  for (const type of ["weekly", "monthly", "annual"] as const) {
    Deno.test(`renders a ${type} statement in ${lang}`, async () => {
      const trips = type === "weekly"
        ? Array.from({ length: 120 }, (_, i) => ({ ...sample().trips[0], at: `2026-09-08T0${i % 10}:00:00Z` }))
        : [];
      const breakdown = type === "annual"
        ? Array.from({ length: 12 }, (_, i) => ({ start: `2026-${String(i + 1).padStart(2, "0")}-01`, totals }))
        : sample().breakdown;
      const pdf = await renderStatement(
        sample({ type, lang, trips, breakdown, status: type === "annual" ? "provisional" : "final",
          partner: { ...sample().partner, name: "Siti Nur'aini 李", bank: { bank: "Maybank", account: "****9012", holder: "Siti" } } }),
        { statementNo: "GR-W-2026-000001", verifyUrl: verifyLink("", "a1b2c3d4e5f6a1b2c3d4e5f6"),
          issuedAt: "2026-09-14T01:00:00Z", revisedAt: type === "monthly" ? "2026-09-20T01:00:00Z" : null },
      );
      assertEquals(new TextDecoder().decode(pdf.slice(0, 5)), "%PDF-");
      const doc = await PDFDocument.load(pdf);
      // 120 trips run onto more pages; every page carries the footer.
      assert(type === "weekly" ? doc.getPageCount() >= 3 : doc.getPageCount() >= 1);
      assertEquals(doc.getTitle(), `${words(lang).title} GR-W-2026-000001`);
    });
  }
}

// ---- The request ---------------------------------------------------------------------------
function deps(over: Partial<StatementDeps> & { row?: StatementRow | null; statement?: StatementData } = {}) {
  const log: string[] = [];
  const saved: Record<string, unknown>[] = [];
  const d: StatementDeps = {
    uid: async () => "uid-1",
    data: async () => over.statement ?? sample(),
    find: async () => over.row ?? null,
    take: async () => true,
    nextNo: async () => "GR-W-2026-000009",
    upload: async (path) => void log.push(`upload ${path}`),
    save: async (row) => void saved.push(row),
    signedUrl: async (path) => `https://signed/${path}`,
    now: () => new Date("2026-09-20T00:00:00Z"),
    render: async () => new Uint8Array([1]),
    ...over,
  };
  delete (d as { row?: unknown }).row;
  return { d, log, saved };
}

const req = { type: "weekly", start: "2026-09-07", lang: "en" };

Deno.test("handler: a first final statement is made, kept and linked", async () => {
  const { d, log, saved } = deps();
  const a = await handleStatement(req, d);
  assertEquals(a.status, 200);
  assertEquals(a.body, {
    url: "https://signed/uid-1/weekly-2026-09-07-en.pdf",
    fileName: "getride-statement-weekly-2026-09-07-en.pdf",
    statementNo: "GR-W-2026-000009",
    status: "final",
    revisedAt: null,
  });
  assertEquals(log, ["upload uid-1/weekly-2026-09-07-en.pdf"]);
  assertEquals(saved[0].is_final, true);
  assertEquals((saved[0].verify_token as string).length, 24);
});

Deno.test("handler: an unchanged final statement is handed back, not remade", async () => {
  const hash = await statementHash(sample());
  const row = { statement_no: "GR-W-2026-000001", verify_token: "t".repeat(24), is_final: true, data_hash: hash,
    storage_path: "uid-1/weekly-2026-09-07-en.pdf", revised_at: null };
  const { d, log } = deps({ row, take: async () => false });
  const a = await handleStatement(req, d);
  assertEquals(a.status, 200);
  assertEquals((a.body as { statementNo: string }).statementNo, "GR-W-2026-000001");
  assertEquals(log, []);
});

Deno.test("handler: a final statement whose numbers changed is revised, same number and token", async () => {
  const row = { statement_no: "GR-W-2026-000001", verify_token: "t".repeat(24), is_final: true, data_hash: "stale",
    storage_path: "uid-1/weekly-2026-09-07-en.pdf", revised_at: null };
  let meta: unknown;
  const { d, saved } = deps({ row, render: async (_d, m) => (meta = m, new Uint8Array([1])) });
  const a = await handleStatement(req, d);
  assertEquals((a.body as { status: string }).status, "revised");
  assertEquals((a.body as { revisedAt: string }).revisedAt, "2026-09-20T00:00:00.000Z");
  assertEquals(saved[0].statement_no, "GR-W-2026-000001");
  assertEquals(saved[0].verify_token, "t".repeat(24));
  assertEquals((meta as { verifyUrl: string }).verifyUrl, `${DEFAULT_VERIFY_URL}/${"t".repeat(24)}`);
});

Deno.test("handler: a provisional copy made before the period closed is not a revision", async () => {
  const row = { statement_no: "GR-W-2026-000001", verify_token: "t".repeat(24), is_final: false, data_hash: "x",
    storage_path: "p", revised_at: null };
  const { d } = deps({ row });
  assertEquals(((await handleStatement(req, d)).body as { status: string }).status, "final");
  const { d: d2, saved } = deps({ row, statement: sample({ status: "provisional" }) });
  assertEquals(((await handleStatement(req, d2)).body as { status: string }).status, "provisional");
  assertEquals(saved[0].is_final, false);
});

Deno.test("handler: refusals", async () => {
  assertEquals((await handleStatement({ type: "x" }, deps().d)).status, 400);
  assertEquals((await handleStatement(req, deps({ uid: async () => null }).d)).status, 401);
  assertEquals((await handleStatement(req, deps({ take: async () => false }).d)).status, 429);
  const forbidden = deps({ data: () => Promise.reject({ code: "42501", message: "not_authorized" }) }).d;
  assertEquals((await handleStatement(req, forbidden)).status, 403);
  const period = deps({
    data: () => Promise.reject({ code: "P0001", message: "STATEMENT_PERIOD", hint: "There is no statement for that period." }),
  }).d;
  assertEquals(await handleStatement(req, period), {
    status: 400,
    body: { error: "bad_period", hint: "There is no statement for that period." },
  });
});
