/**
 * Partner statements (migration 0201): the PDF, in English or Bahasa Melayu,
 * from what `partner_statement_data` returns, and the `partner-statement`
 * function's request, with the database and storage passed in so it is
 * tested without either.
 *
 *   POST { type: "weekly" | "monthly" | "annual", start: "YYYY-MM-DD", lang: "en" | "ms" }
 *     → { url, fileName, statementNo, status: "provisional" | "final" | "revised", revisedAt }
 *
 * A final statement is made once and kept; it is made again ("Revised") only
 * when its numbers change (an adjustment). A provisional one is made fresh
 * each time. 429 past 20 made per partner per hour.
 */
import { degrees, PDFDocument, type PDFFont, type PDFPage, rgb, StandardFonts } from "npm:pdf-lib@1.17.1";
import qrcode from "npm:qrcode-generator@1.4.4";

export type PeriodType = "weekly" | "monthly" | "annual";
export type Lang = "en" | "ms";

export type Totals = Record<string, number>;

export interface StatementData {
  type: PeriodType;
  periodStart: string;
  periodEnd: string;
  status: "provisional" | "final";
  lang: Lang;
  partner: { name: string | null; displayId: string | null; ic: string | null; plate: string | null;
    bank: { bank: string; account: string; holder: string } | null };
  company: { name: string; ssm: string; support: string; verifyUrl?: string };
  weekStart: string;
  totals: Totals;
  incentives: { at: string; label: string; amount: number }[];
  adjustments: { at: string; reason: string; amount: number }[];
  breakdown: { start: string; end?: string; totals: Totals; weeks?: unknown[] }[];
  trips: { at: string; service: string | null; pickup: string; drop: string; payment: string | null; lines: Totals }[];
}

export const DEFAULT_VERIFY_URL = "https://getride.my/verify";

/** Statements made per partner per hour. */
export const RATE_LIMIT = 20;

const PERIOD = /^(weekly|monthly|annual)$/;
const DATE = /^\d{4}-\d{2}-\d{2}$/;

export function parseRequest(body: unknown): { type: PeriodType; start: string; lang: Lang } | null {
  if (!body || typeof body !== "object") return null;
  const b = body as Record<string, unknown>;
  const type = typeof b.type === "string" && PERIOD.test(b.type) ? (b.type as PeriodType) : null;
  const start = typeof b.start === "string" && DATE.test(b.start) && !Number.isNaN(Date.parse(b.start)) ? b.start : null;
  const lang: Lang = b.lang === "ms" ? "ms" : "en";
  return type && start ? { type, start, lang } : null;
}

// ---- Words ---------------------------------------------------------------------------------
const WORDS = {
  en: {
    title: "Partner Earnings Statement",
    weekly: "Weekly",
    monthly: "Monthly",
    annual: "Annual",
    statementNo: "Statement no.",
    period: "Period",
    issued: "Issued",
    provisional: "PROVISIONAL",
    final: "FINAL",
    revised: "REVISED",
    ssm: "SSM no.",
    support: "Support",
    partner: "Partner",
    partnerId: "Partner ID",
    ic: "IC no.",
    plate: "Vehicle plate",
    bank: "Payout account",
    earnings: "Earnings",
    fares: "Fares",
    surcharges: "Surcharges",
    feesCollected: "Fees collected for GET.ride",
    incentives: "Incentives",
    handoverIn: "Trip handover share received",
    totalEarnings: "Total earnings",
    deductions: "Deductions",
    commission: "Commission",
    platformFees: "Platform fees",
    handoverOut: "Trip handover share paid",
    totalDeductions: "Total deductions",
    adjustments: "Adjustments",
    net: "Net earnings",
    passThrough: "Collected for others (not income)",
    taxes: "Taxes",
    tolls: "Tolls",
    otherCharges: "Other charges",
    otherSurcharges: "Other surcharges",
    total: "Total",
    howPaid: "How riders paid",
    cash: "Cash",
    coins: "GET.coin",
    activity: "Activity",
    trips: "Trips",
    onlineHours: "Hours online",
    distance: "Distance (km)",
    daily: "Daily breakdown",
    weeklyBreakdown: "Weekly breakdown",
    monthlyBreakdown: "Monthly breakdown",
    date: "Date",
    week: "Week",
    month: "Month",
    tripList: "Trips",
    time: "Time",
    service: "Service",
    payment: "Payment",
    fare: "Fare",
    earned: "Earnings",
    deducted: "Deductions",
    verify: "Verify this statement",
    page: (i: number, n: number) => `Page ${i} of ${n}`,
    footer: "Computer-generated statement; no signature is required. Amounts in RM.",
    provisionalNote: "This period is still open; the figures may change until the statement is final.",
    revisedNote: (d: string) => `Revised on ${d} after an adjustment.`,
    none: "None",
    days: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
    months: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
  },
  ms: {
    title: "Penyata Pendapatan Rakan Pemandu",
    weekly: "Mingguan",
    monthly: "Bulanan",
    annual: "Tahunan",
    statementNo: "No. penyata",
    period: "Tempoh",
    issued: "Dikeluarkan",
    provisional: "SEMENTARA",
    final: "MUKTAMAD",
    revised: "DISEMAK SEMULA",
    ssm: "No. SSM",
    support: "Sokongan",
    partner: "Rakan pemandu",
    partnerId: "ID rakan",
    ic: "No. KP",
    plate: "No. pendaftaran",
    bank: "Akaun pembayaran",
    earnings: "Pendapatan",
    fares: "Tambang",
    surcharges: "Caj tambahan",
    feesCollected: "Fi dikutip untuk GET.ride",
    incentives: "Insentif",
    handoverIn: "Syer serahan perjalanan diterima",
    totalEarnings: "Jumlah pendapatan",
    deductions: "Potongan",
    commission: "Komisen",
    platformFees: "Fi platform",
    handoverOut: "Syer serahan perjalanan dibayar",
    totalDeductions: "Jumlah potongan",
    adjustments: "Pelarasan",
    net: "Pendapatan bersih",
    passThrough: "Dikutip bagi pihak lain (bukan pendapatan)",
    taxes: "Cukai",
    tolls: "Tol",
    otherCharges: "Caj lain",
    otherSurcharges: "Caj tambahan lain",
    total: "Jumlah",
    howPaid: "Cara penumpang membayar",
    cash: "Tunai",
    coins: "GET.coin",
    activity: "Aktiviti",
    trips: "Perjalanan",
    onlineHours: "Jam dalam talian",
    distance: "Jarak (km)",
    daily: "Pecahan harian",
    weeklyBreakdown: "Pecahan mingguan",
    monthlyBreakdown: "Pecahan bulanan",
    date: "Tarikh",
    week: "Minggu",
    month: "Bulan",
    tripList: "Perjalanan",
    time: "Masa",
    service: "Perkhidmatan",
    payment: "Bayaran",
    fare: "Tambang",
    earned: "Pendapatan",
    deducted: "Potongan",
    verify: "Sahkan penyata ini",
    page: (i: number, n: number) => `Halaman ${i} daripada ${n}`,
    footer: "Penyata janaan komputer; tandatangan tidak diperlukan. Amaun dalam RM.",
    provisionalNote: "Tempoh ini masih dibuka; angka mungkin berubah sehingga penyata dimuktamadkan.",
    revisedNote: (d: string) => `Disemak semula pada ${d} selepas pelarasan.`,
    none: "Tiada",
    days: ["Isn", "Sel", "Rab", "Kha", "Jum", "Sab", "Ahd"],
    months: ["Jan", "Feb", "Mac", "Apr", "Mei", "Jun", "Jul", "Ogo", "Sep", "Okt", "Nov", "Dis"],
  },
};

export type Words = typeof WORDS.en;
export const words = (lang: Lang): Words => WORDS[lang] as Words;

// ---- Formatting ----------------------------------------------------------------------------
export function money(n: number | undefined | null): string {
  const v = Math.round((Number(n) || 0) * 100) / 100;
  const s = Math.abs(v).toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return v < 0 ? `-${s}` : s;
}

/** "2026-09-07" → "7 Sep 2026". */
export function day(iso: string, lang: Lang): string {
  const [y, m, d] = iso.slice(0, 10).split("-").map(Number);
  return `${d} ${words(lang).months[m - 1]} ${y}`;
}

/** A moment in Malaysia time (UTC+8, no daylight saving): "2026-09-08 10:00". */
export function myt(at: string): string {
  const t = new Date(Date.parse(at) + 8 * 3_600_000).toISOString();
  return `${t.slice(0, 10)} ${t.slice(11, 16)}`;
}

export function periodLabel(d: Pick<StatementData, "type" | "periodStart" | "periodEnd">, lang: Lang): string {
  const w = words(lang);
  const [y, m] = d.periodStart.split("-").map(Number);
  if (d.type === "annual") return `${y}`;
  if (d.type === "monthly") return `${w.months[m - 1]} ${y}`;
  return `${day(d.periodStart, lang)} – ${day(d.periodEnd, lang)}`;
}

export function fileName(d: Pick<StatementData, "type" | "periodStart">, lang: Lang): string {
  return `getride-statement-${d.type}-${d.periodStart}-${lang}.pdf`;
}

/** The standard PDF fonts cover Latin-1 only: anything else becomes "?". */
export function latin1(s: string | null | undefined): string {
  return (s ?? "").replace(/[–—]/g, "-").replace(/[‘’]/g, "'").replace(/[“”]/g, '"')
    .replace(/[^\x20-\x7e\xa0-\xff]/g, "?");
}

/** What the statement says, as a hash: a final copy is remade only when it changes. */
export async function statementHash(d: StatementData): Promise<string> {
  const { status: _s, lang: _l, ...rest } = d;
  const bytes = new TextEncoder().encode(stableJson(rest));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function stableJson(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(stableJson).join(",")}]`;
  if (v && typeof v === "object") {
    return `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${stableJson((v as Record<string, unknown>)[k])}`).join(",")}}`;
  }
  return JSON.stringify(v ?? null);
}

export function newVerifyToken(): string {
  return [...crypto.getRandomValues(new Uint8Array(12))].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function verifyLink(base: string | undefined, token: string): string {
  const b = (base && /^https:\/\/\S+$/.test(base) ? base : DEFAULT_VERIFY_URL).replace(/\/+$/, "");
  return `${b}/${token}`;
}

// ---- The summary's rows ---------------------------------------------------------------------
export type Row = { label: string; amount?: number; bold?: boolean; head?: boolean; text?: string };

export function summaryRows(t: Totals, w: Words): Row[] {
  const n = (k: string) => Number(t[k] ?? 0);
  const rows: Row[] = [
    { label: w.earnings, head: true },
    { label: w.fares, amount: n("fare") },
    { label: w.surcharges, amount: n("surcharges") },
    { label: w.feesCollected, amount: n("platformCollected") },
    { label: w.incentives, amount: n("incentives") },
    { label: w.handoverIn, amount: n("handoverIn") },
    { label: w.totalEarnings, amount: n("totalEarnings"), bold: true },
    { label: w.deductions, head: true },
    { label: w.commission, amount: -n("commission") },
    { label: w.platformFees, amount: -n("platformFees") },
    { label: w.handoverOut, amount: -n("handoverOut") },
    { label: w.totalDeductions, amount: -n("totalDeductions"), bold: true },
    { label: w.adjustments, amount: n("adjustments") },
    { label: w.net, amount: n("net"), bold: true },
    { label: w.passThrough, head: true },
    { label: w.taxes, amount: n("taxes") },
    { label: w.tolls, amount: n("tolls") },
    { label: w.otherCharges, amount: n("otherCharges") },
    { label: w.otherSurcharges, amount: n("surchargesPass") },
    { label: w.total, amount: n("passThrough"), bold: true },
    { label: w.howPaid, head: true },
    { label: w.cash, amount: n("cash") },
    { label: w.coins, amount: n("coins") },
    { label: w.activity, head: true },
    { label: w.trips, text: String(n("trips")) },
    { label: w.onlineHours, text: n("onlineHours").toFixed(1) },
    { label: w.distance, text: n("distanceKm").toFixed(1) },
  ];
  // Lines that are nothing in every statement (no handover, no adjustments) are left out.
  const optional = new Set([w.handoverIn, w.handoverOut, w.adjustments, w.otherCharges, w.otherSurcharges]);
  return rows.filter((r) => !optional.has(r.label) || (r.amount ?? 0) !== 0);
}

// ---- The PDF -------------------------------------------------------------------------------
export interface RenderMeta {
  statementNo: string;
  verifyUrl: string;
  issuedAt: string;
  revisedAt: string | null;
}

const A4 = { w: 595.28, h: 841.89 };
const M = 40;
const INK = rgb(0.1, 0.1, 0.12);
const MUTED = rgb(0.42, 0.44, 0.48);
const RULE = rgb(0.85, 0.86, 0.88);
const BRAND = rgb(0.0, 0.47, 0.35);
const WATERMARK = rgb(0.9, 0.9, 0.92);

export async function renderStatement(d: StatementData, meta: RenderMeta): Promise<Uint8Array> {
  const lang = d.lang;
  const w = words(lang);
  const doc = await PDFDocument.create();
  doc.setTitle(`${w.title} ${meta.statementNo}`);
  doc.setAuthor(latin1(d.company.name));
  doc.setCreator("GET.ride");
  doc.setProducer("GET.ride");
  const font = await doc.embedFont(StandardFonts.Helvetica);
  const bold = await doc.embedFont(StandardFonts.HelveticaBold);

  let page!: PDFPage;
  let y = 0;
  const status = meta.revisedAt ? w.revised : d.status === "final" ? w.final : w.provisional;

  const text = (s: string, x: number, yy: number, size = 9, f: PDFFont = font, color = INK) =>
    page.drawText(latin1(s), { x, y: yy, size, font: f, color });
  const right = (s: string, xr: number, yy: number, size = 9, f: PDFFont = font, color = INK) => {
    const t = latin1(s);
    page.drawText(t, { x: xr - f.widthOfTextAtSize(t, size), y: yy, size, font: f, color });
  };
  const rule = (yy: number) =>
    page.drawLine({ start: { x: M, y: yy }, end: { x: A4.w - M, y: yy }, thickness: 0.5, color: RULE });
  const fit = (s: string, max: number, size = 9, f: PDFFont = font) => {
    let t = latin1(s);
    while (t.length > 1 && f.widthOfTextAtSize(t, size) > max) t = t.slice(0, -2) + ".";
    return t;
  };

  const newPage = () => {
    page = doc.addPage([A4.w, A4.h]);
    if (d.status !== "final") {
      page.drawText(w.provisional, {
        x: 110, y: 260, size: 72, font: bold, color: WATERMARK,
        rotate: degrees(40),
      });
    }
    // Header on every page.
    text(d.company.name, M, A4.h - M - 4, 12, bold, BRAND);
    text(`${w.ssm} ${d.company.ssm}`, M, A4.h - M - 18, 8, font, MUTED);
    text(`${w.support} ${d.company.support}`, M, A4.h - M - 29, 8, font, MUTED);
    right(w.title, A4.w - M, A4.h - M - 4, 12, bold);
    right(`${w[d.type]} - ${periodLabel(d, lang)}`, A4.w - M, A4.h - M - 18, 9);
    right(`${w.statementNo} ${meta.statementNo}`, A4.w - M, A4.h - M - 29, 8, font, MUTED);
    rule(A4.h - M - 38);
    y = A4.h - M - 56;
  };
  const need = (h: number) => {
    if (y - h < M + 70) newPage();
  };

  newPage();

  // Status and partner.
  const badge = latin1(status);
  const bw = bold.widthOfTextAtSize(badge, 9) + 14;
  page.drawRectangle({ x: A4.w - M - bw, y: y - 4, width: bw, height: 16, color: d.status === "final" ? BRAND : MUTED });
  page.drawText(badge, { x: A4.w - M - bw + 7, y: y + 1, size: 9, font: bold, color: rgb(1, 1, 1) });
  text(`${w.issued} ${myt(meta.issuedAt)}`, A4.w - M - 200, y - 20, 8, font, MUTED);
  if (meta.revisedAt) text(w.revisedNote(myt(meta.revisedAt)), A4.w - M - 200, y - 31, 8, font, MUTED);
  if (d.status !== "final") text(fit(w.provisionalNote, 200, 7), A4.w - M - 200, y - 31, 7, font, MUTED);

  const p = d.partner;
  const details: [string, string | null][] = [
    [w.partner, p.name],
    [w.partnerId, p.displayId],
    [w.ic, p.ic],
    [w.plate, p.plate],
    [w.bank, p.bank ? `${p.bank.bank} ${p.bank.account} (${p.bank.holder})` : null],
  ];
  for (const [k, v] of details) {
    if (!v) continue;
    text(k, M, y, 9, font, MUTED);
    text(fit(v, 230), M + 90, y, 9, k === w.partner ? bold : font);
    y -= 13;
  }
  y -= 10;

  // Summary.
  const col = A4.w - M;
  for (const r of summaryRows(d.totals, w)) {
    need(16);
    if (r.head) {
      y -= 6;
      text(r.label, M, y, 10, bold, BRAND);
      y -= 4;
      rule(y);
      y -= 12;
      continue;
    }
    text(r.label, M + 8, y, r.bold ? 10 : 9, r.bold ? bold : font);
    right(r.text ?? money(r.amount), col, y, r.bold ? 10 : 9, r.bold ? bold : font);
    y -= r.bold ? 16 : 13;
  }

  // Incentives and adjustments.
  const listed = (title: string, items: { at: string; label: string; amount: number }[]) => {
    if (!items.length) return;
    need(40);
    y -= 6;
    text(title, M, y, 10, bold, BRAND);
    y -= 4;
    rule(y);
    y -= 12;
    for (const i of items) {
      need(14);
      text(myt(i.at).slice(0, 10), M + 8, y);
      text(fit(i.label, 330), M + 90, y);
      right(money(i.amount), col, y);
      y -= 13;
    }
  };
  listed(w.incentives, d.incentives);
  listed(w.adjustments, d.adjustments.map((a) => ({ at: a.at, label: a.reason, amount: a.amount })));

  // Breakdown.
  const cols = [M + 8, M + 190, M + 270, M + 370, col];
  const table = (title: string, heads: string[], rows: string[][]) => {
    need(50);
    y -= 6;
    text(title, M, y, 10, bold, BRAND);
    y -= 14;
    heads.forEach((h, i) => (i === 0 ? text(h, cols[0], y, 8, bold, MUTED) : right(h, cols[i + 1], y, 8, bold, MUTED)));
    y -= 4;
    rule(y);
    y -= 12;
    for (const r of rows) {
      need(14);
      r.forEach((c, i) => (i === 0 ? text(c, cols[0], y) : right(c, cols[i + 1], y)));
      y -= 13;
    }
  };
  const breakdownRows = (items: { start: string; end?: string; totals: Totals }[], label: (s: string, e?: string) => string) =>
    items.map((b) => [label(b.start, b.end), String(b.totals.trips ?? 0), money(b.totals.totalEarnings), money(b.totals.net)]);
  const heads = (first: string) => [first, w.trips, w.earned, w.net];
  if (d.type === "weekly") {
    table(w.daily, heads(w.date), breakdownRows(d.breakdown, (s) => {
      const i = (new Date(`${s}T00:00:00Z`).getUTCDay() + 6) % 7;
      return `${w.days[i]} ${day(s, lang)}`;
    }));
  } else if (d.type === "monthly") {
    table(w.weeklyBreakdown, heads(w.week), breakdownRows(d.breakdown, (s, e) => `${day(s, lang)} - ${day(e ?? s, lang)}`));
  } else {
    table(w.monthlyBreakdown, heads(w.month), breakdownRows(d.breakdown, (s) => periodLabel({ type: "monthly", periodStart: s, periodEnd: s }, lang)));
  }

  // Trips (weekly).
  if (d.type === "weekly" && d.trips.length) {
    const tc = [M + 8, M + 95, M + 175, M + 265, M + 345, M + 425, col];
    need(50);
    y -= 6;
    text(w.tripList, M, y, 10, bold, BRAND);
    y -= 14;
    const th = [w.time, w.service, w.payment, w.fare, w.earned, w.commission];
    th.forEach((h, i) => (i < 3 ? text(h, tc[i], y, 8, bold, MUTED) : right(h, tc[i + 1], y, 8, bold, MUTED)));
    y -= 4;
    rule(y);
    y -= 12;
    for (const t of d.trips) {
      need(14);
      const l = t.lines;
      text(myt(t.at), tc[0], y, 8);
      text(fit(t.service ?? "", 75, 8), tc[1], y, 8);
      text(fit(t.payment ?? "", 80, 8), tc[2], y, 8);
      right(money(l.fare), tc[4], y, 8);
      right(money((l.fare ?? 0) + (l.surcharges ?? 0) + (l.platformCollected ?? 0)), tc[5], y, 8);
      right(money(-(l.commission ?? 0)), tc[6], y, 8);
      y -= 12;
    }
  }

  // Footer on every page: the QR to verify, page numbers.
  const qr = qrcode(0, "M");
  qr.addData(meta.verifyUrl);
  qr.make();
  const n = qr.getModuleCount();
  const size = 54;
  const cell = size / n;
  const pages = doc.getPages();
  pages.forEach((pg, i) => {
    page = pg;
    rule(M + 62);
    for (let r = 0; r < n; r++) {
      for (let c = 0; c < n; c++) {
        if (qr.isDark(r, c)) {
          pg.drawRectangle({ x: M + c * cell, y: M + size - (r + 1) * cell, width: cell + 0.05, height: cell + 0.05, color: INK });
        }
      }
    }
    text(w.verify, M + size + 10, M + 40, 8, bold);
    text(fit(meta.verifyUrl, 300, 7), M + size + 10, M + 29, 7, font, MUTED);
    text(w.footer, M + size + 10, M + 14, 7, font, MUTED);
    right(w.page(i + 1, pages.length), A4.w - M, M + 14, 7, font, MUTED);
    right(meta.statementNo, A4.w - M, M + 40, 8, bold);
  });

  return await doc.save();
}

// ---- The request ---------------------------------------------------------------------------
export interface StatementRow {
  statement_no: string;
  verify_token: string;
  is_final: boolean;
  data_hash: string;
  storage_path: string;
  revised_at: string | null;
}

export interface StatementDeps {
  /** The signed-in caller's auth id, or null. */
  uid(): Promise<string | null>;
  /** partner_statement_data as the caller: throws { code, hint } when refused. */
  data(type: PeriodType, start: string, lang: Lang): Promise<StatementData>;
  find(uid: string, type: PeriodType, start: string, lang: Lang): Promise<StatementRow | null>;
  take(uid: string): Promise<boolean>;
  nextNo(type: PeriodType): Promise<string>;
  upload(path: string, pdf: Uint8Array): Promise<void>;
  save(row: Record<string, unknown>): Promise<void>;
  signedUrl(path: string, fileName: string): Promise<string>;
  now(): Date;
  render?: typeof renderStatement;
}

export interface StatementAnswer {
  status: number;
  body: unknown;
}

const fail = (error: string, status: number, hint?: string): StatementAnswer => ({
  status,
  body: hint ? { error, hint } : { error },
});

export async function handleStatement(body: unknown, deps: StatementDeps): Promise<StatementAnswer> {
  const req = parseRequest(body);
  if (!req) return fail("bad_request", 400);
  const uid = await deps.uid();
  if (!uid) return fail("not_authorized", 401);

  let data: StatementData;
  try {
    data = await deps.data(req.type, req.start, req.lang);
  } catch (e) {
    const err = e as { code?: string; message?: string; hint?: string };
    if (err.code === "42501") return fail("not_authorized", 403);
    if ((err.message ?? "").startsWith("STATEMENT_")) return fail("bad_period", 400, err.hint);
    throw e;
  }

  const hash = await statementHash(data);
  const row = await deps.find(uid, req.type, req.start, req.lang);
  const name = fileName(data, req.lang);
  const final = data.status === "final";

  if (row && row.is_final && final && row.data_hash === hash) {
    return {
      status: 200,
      body: {
        url: await deps.signedUrl(row.storage_path, name),
        fileName: name,
        statementNo: row.statement_no,
        status: row.revised_at ? "revised" : "final",
        revisedAt: row.revised_at,
      },
    };
  }
  if (!(await deps.take(uid))) return fail("rate_limited", 429);

  const now = deps.now().toISOString();
  const statementNo = row?.statement_no ?? (await deps.nextNo(req.type));
  const token = row?.verify_token ?? newVerifyToken();
  // A final copy whose numbers changed is revised; one made before the period closed is not.
  const revisedAt = row?.is_final && final ? now : null;
  const pdf = await (deps.render ?? renderStatement)(data, {
    statementNo,
    verifyUrl: verifyLink(data.company.verifyUrl, token),
    issuedAt: now,
    revisedAt,
  });
  const path = `${uid}/${req.type}-${req.start}-${req.lang}.pdf`;
  await deps.upload(path, pdf);
  await deps.save({
    statement_no: statementNo,
    verify_token: token,
    partner_user_id: uid,
    period_type: req.type,
    period_start: req.start,
    period_end: data.periodEnd,
    lang: req.lang,
    is_final: final,
    totals: data.totals,
    storage_path: path,
    data_hash: hash,
    revised_at: revisedAt ?? row?.revised_at ?? null,
    updated_at: now,
  });
  const keptRevised = revisedAt ?? (final ? row?.revised_at ?? null : null);
  return {
    status: 200,
    body: {
      url: await deps.signedUrl(path, name),
      fileName: name,
      statementNo,
      status: keptRevised ? "revised" : data.status,
      revisedAt: keptRevised,
    },
  };
}
