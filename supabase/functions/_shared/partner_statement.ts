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
import { degrees, PDFDocument, type PDFFont, type PDFImage, type PDFPage, rgb, StandardFonts } from "npm:pdf-lib@1.17.1";
import qrcode from "npm:qrcode-generator@1.4.4";

import {
  cleanLayout,
  type FontFamily,
  layoutHash,
  renamed,
  rgbOf,
  type Section,
  shows,
  type StatementLayout,
} from "./statement_layout.ts";
import { sampleStatement } from "./statement_sample.ts";

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
  /** kind "meter": a meter / TEKSI hire (0224); left out for a booked trip. */
  trips: { at: string; kind?: "meter"; service: string | null; pickup: string; drop: string; payment: string | null; lines: Totals }[];
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
    meterTrips: "Of which meter trips",
    meter: "Meter",
    onlineHours: "Hours online",
    distance: "Distance (km)",
    daily: "Daily breakdown",
    weeklyBreakdown: "Weekly breakdown",
    monthlyBreakdown: "Monthly breakdown",
    date: "Date",
    week: "Week",
    month: "Month",
    tripList: "Trips",
    incentivesList: "Incentives",
    adjustmentsList: "Adjustments",
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
    meterTrips: "Daripadanya perjalanan meter",
    meter: "Meter",
    onlineHours: "Jam dalam talian",
    distance: "Jarak (km)",
    daily: "Pecahan harian",
    weeklyBreakdown: "Pecahan mingguan",
    monthlyBreakdown: "Pecahan bulanan",
    date: "Tarikh",
    week: "Minggu",
    month: "Bulan",
    tripList: "Perjalanan",
    incentivesList: "Insentif",
    adjustmentsList: "Pelarasan",
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
export type Row = { id: string; section: Section; label: string; amount?: number; bold?: boolean; head?: boolean; text?: string };

export function summaryRows(t: Totals, w: Words): Row[] {
  const n = (k: string) => Number(t[k] ?? 0);
  const rows: Row[] = [
    { id: "earnings", section: "earnings", label: w.earnings, head: true },
    { id: "fares", section: "earnings", label: w.fares, amount: n("fare") },
    { id: "surcharges", section: "earnings", label: w.surcharges, amount: n("surcharges") },
    { id: "feesCollected", section: "earnings", label: w.feesCollected, amount: n("platformCollected") },
    { id: "incentives", section: "earnings", label: w.incentives, amount: n("incentives") },
    { id: "handoverIn", section: "earnings", label: w.handoverIn, amount: n("handoverIn") },
    { id: "totalEarnings", section: "earnings", label: w.totalEarnings, amount: n("totalEarnings"), bold: true },
    { id: "deductions", section: "deductions", label: w.deductions, head: true },
    { id: "commission", section: "deductions", label: w.commission, amount: -n("commission") },
    { id: "platformFees", section: "deductions", label: w.platformFees, amount: -n("platformFees") },
    { id: "handoverOut", section: "deductions", label: w.handoverOut, amount: -n("handoverOut") },
    { id: "totalDeductions", section: "deductions", label: w.totalDeductions, amount: -n("totalDeductions"), bold: true },
    { id: "adjustments", section: "net", label: w.adjustments, amount: n("adjustments") },
    { id: "net", section: "net", label: w.net, amount: n("net"), bold: true },
    { id: "passThrough", section: "passThrough", label: w.passThrough, head: true },
    { id: "taxes", section: "passThrough", label: w.taxes, amount: n("taxes") },
    { id: "tolls", section: "passThrough", label: w.tolls, amount: n("tolls") },
    { id: "otherCharges", section: "passThrough", label: w.otherCharges, amount: n("otherCharges") },
    { id: "otherSurcharges", section: "passThrough", label: w.otherSurcharges, amount: n("surchargesPass") },
    { id: "total", section: "passThrough", label: w.total, amount: n("passThrough"), bold: true },
    { id: "howPaid", section: "howPaid", label: w.howPaid, head: true },
    { id: "cash", section: "howPaid", label: w.cash, amount: n("cash") },
    { id: "coins", section: "howPaid", label: w.coins, amount: n("coins") },
    { id: "activity", section: "activity", label: w.activity, head: true },
    { id: "trips", section: "activity", label: w.trips, text: String(n("trips")) },
    { id: "meterTrips", section: "activity", label: w.meterTrips, text: String(n("meterTrips")) },
    { id: "onlineHours", section: "activity", label: w.onlineHours, text: n("onlineHours").toFixed(1) },
    { id: "distance", section: "activity", label: w.distance, text: n("distanceKm").toFixed(1) },
  ];
  // Lines that are nothing in every statement (no handover, no adjustments) are left out.
  const optional = new Set(["handoverIn", "handoverOut", "adjustments", "otherCharges", "otherSurcharges"]);
  return rows.filter((r) =>
    r.id === "meterTrips" ? n("meterTrips") !== 0 : !optional.has(r.id) || (r.amount ?? 0) !== 0
  );
}

// ---- The PDF -------------------------------------------------------------------------------
export interface RenderMeta {
  statementNo: string;
  verifyUrl: string;
  issuedAt: string;
  revisedAt: string | null;
}

/** How it looks: the admin's layout, and the logo's bytes when it has one. */
export interface RenderLook {
  layout?: StatementLayout;
  logo?: { bytes: Uint8Array; png: boolean } | null;
}

const A4 = { w: 595.28, h: 841.89 };
const M = 40;

const FAMILIES: Record<FontFamily, [StandardFonts, StandardFonts]> = {
  helvetica: [StandardFonts.Helvetica, StandardFonts.HelveticaBold],
  times: [StandardFonts.TimesRoman, StandardFonts.TimesRomanBold],
  courier: [StandardFonts.Courier, StandardFonts.CourierBold],
};

export async function renderStatement(d: StatementData, meta: RenderMeta, look: RenderLook = {}): Promise<Uint8Array> {
  const lang = d.lang;
  const L = look.layout ?? cleanLayout({});
  const w = renamed(words(lang), L, lang);
  const on = (id: string) => shows(L, id);
  const fs = L.fonts;
  const color = (k: keyof StatementLayout["colors"]) => rgb(...rgbOf(L.colors[k]));
  const INK = color("ink");
  const MUTED = color("muted");
  const RULE = color("rule");
  const BRAND = color("brand");

  const doc = await PDFDocument.create();
  doc.setTitle(`${w.title} ${meta.statementNo}`);
  doc.setAuthor(latin1(d.company.name));
  doc.setCreator("GET.ride");
  doc.setProducer("GET.ride");
  const [regular, heavy] = FAMILIES[L.fontFamily];
  const font = await doc.embedFont(regular);
  const bold = await doc.embedFont(heavy);

  let logo: PDFImage | null = null;
  if (look.logo && L.logo.path) {
    try {
      logo = look.logo.png ? await doc.embedPng(look.logo.bytes) : await doc.embedJpg(look.logo.bytes);
    } catch {
      logo = null; // A file pdf-lib can't read: the statement goes out without it.
    }
  }

  let page!: PDFPage;
  let y = 0;
  const status = meta.revisedAt ? w.revised : d.status === "final" ? w.final : w.provisional;

  const text = (s: string, x: number, yy: number, size = fs.body, f: PDFFont = font, c = INK) =>
    page.drawText(latin1(s), { x, y: yy, size, font: f, color: c });
  const right = (s: string, xr: number, yy: number, size = fs.body, f: PDFFont = font, c = INK) => {
    const t = latin1(s);
    page.drawText(t, { x: xr - f.widthOfTextAtSize(t, size), y: yy, size, font: f, color: c });
  };
  const rule = (yy: number) =>
    page.drawLine({ start: { x: M, y: yy }, end: { x: A4.w - M, y: yy }, thickness: 0.5, color: RULE });
  const fit = (s: string, max: number, size = fs.body, f: PDFFont = font) => {
    let t = latin1(s);
    while (t.length > 1 && f.widthOfTextAtSize(t, size) > max) t = t.slice(0, -2) + ".";
    return t;
  };

  // The logo's own band at the top; its shift moves only the picture.
  const logoW = logo ? L.logo.width : 0;
  const logoH = logo ? Math.min(120, (logoW * logo.height) / logo.width) : 0;
  const band = logo ? logoH + 8 : 0;

  type Line = { s: string; size: number; f: PDFFont; c: ReturnType<typeof rgb> };
  const companyLines: Line[] = [
    ...(on("companyName") ? [{ s: d.company.name, size: fs.company, f: bold, c: BRAND }] : []),
    ...(on("companySsm") && d.company.ssm ? [{ s: `${w.ssm} ${d.company.ssm}`, size: fs.small + 1, f: font, c: MUTED }] : []),
    ...(on("supportContact") && d.company.support ? [{ s: `${w.support} ${d.company.support}`, size: fs.small + 1, f: font, c: MUTED }] : []),
  ];
  const titleLines: Line[] = [
    ...(on("title") ? [{ s: w.title, size: fs.title, f: bold, c: INK }] : []),
    ...(on("period") ? [{ s: `${w[d.type]} - ${periodLabel(d, lang)}`, size: fs.body, f: font, c: INK }] : []),
    ...(on("statementNo") ? [{ s: `${w.statementNo} ${meta.statementNo}`, size: fs.small + 1, f: font, c: MUTED }] : []),
  ];
  const stack = (lines: Line[], atRight: boolean, top: number) => {
    let yy = top;
    for (const l of lines) {
      yy -= l.size;
      atRight ? right(fit(l.s, 260, l.size, l.f), A4.w - M, yy, l.size, l.f, l.c) : text(fit(l.s, 260, l.size, l.f), M, yy, l.size, l.f, l.c);
      yy -= 3;
    }
    return top - yy;
  };

  const newPage = () => {
    page = doc.addPage([A4.w, A4.h]);
    if (d.status !== "final" && on("watermark")) {
      page.drawText(latin1(w.provisional), {
        x: 110, y: 260, size: 72, font: bold, color: color("watermark"),
        rotate: degrees(40),
      });
    }
    const top = A4.h - M;
    if (logo) {
      const x0 = L.logo.position === "center" ? (A4.w - logoW) / 2 : L.logo.position === "right" ? A4.w - M - logoW : M;
      page.drawImage(logo, { x: x0 + L.logo.dx, y: top - logoH - L.logo.dy, width: logoW, height: logoH });
    }
    // Header on every page: the company on one side, the title on the other.
    const companyRight = L.companySide === "right";
    const h = Math.max(stack(companyLines, companyRight, top - band), stack(titleLines, !companyRight, top - band));
    rule(top - band - h - 4);
    y = top - band - h - 22;
  };
  const need = (h: number) => {
    if (y - h < M + 70) newPage();
  };

  newPage();

  // Status and partner.
  const metaX = L.companySide === "right" ? M : A4.w - M - 200;
  if (on("status")) {
    const badge = latin1(status);
    const bw = bold.widthOfTextAtSize(badge, fs.body) + 14;
    const bx = L.companySide === "right" ? M : A4.w - M - bw;
    page.drawRectangle({ x: bx, y: y - 4, width: bw, height: fs.body + 7, color: d.status === "final" ? color("badge") : MUTED });
    page.drawText(badge, { x: bx + 7, y: y + 1, size: fs.body, font: bold, color: rgb(1, 1, 1) });
  }
  if (on("issued")) text(`${w.issued} ${myt(meta.issuedAt)}`, metaX, y - 20, fs.small + 1, font, MUTED);
  if (meta.revisedAt) text(w.revisedNote(myt(meta.revisedAt)), metaX, y - 31, fs.small + 1, font, MUTED);
  if (d.status !== "final") text(fit(w.provisionalNote, 200, fs.small), metaX, y - 31, fs.small, font, MUTED);

  const p = d.partner;
  const partnerValues: Record<string, [string, string | null]> = {
    partner: [w.partner, p.name],
    partnerId: [w.partnerId, p.displayId],
    ic: [w.ic, p.ic],
    plate: [w.plate, p.plate],
    bank: [w.bank, p.bank ? `${p.bank.bank} ${p.bank.account} (${p.bank.holder})` : null],
  };
  const partnerX = L.companySide === "right" ? A4.w / 2 - 20 : M;
  for (const id of L.partnerOrder) {
    const [k, v] = partnerValues[id] ?? ["", null];
    if (!v || !on(id)) continue;
    text(k, partnerX, y, fs.body, font, MUTED);
    text(fit(v, 230), partnerX + 90, y, fs.body, id === "partner" ? bold : font);
    y -= fs.body + 4;
  }
  y -= 10;

  const col = A4.w - M;
  const heading = (title: string) => {
    y -= 6;
    text(title, M, y, fs.heading, bold, BRAND);
    y -= 4;
    rule(y);
    y -= fs.body + 3;
  };

  // Summary blocks.
  const rows = summaryRows(d.totals, w);
  const summary = (section: Section) => {
    const mine = rows.filter((r) => r.section === section && on(r.id));
    if (!mine.some((r) => !r.head)) return;
    for (const r of mine) {
      need(16);
      if (r.head) {
        heading(r.label);
        continue;
      }
      const size = r.bold ? fs.total : fs.body;
      text(r.label, M + 8, y, size, r.bold ? bold : font);
      right(r.text ?? money(r.amount), col, y, size, r.bold ? bold : font);
      y -= r.bold ? size + 6 : size + 4;
    }
  };

  // Incentives and adjustments.
  const listed = (title: string, items: { at: string; label: string; amount: number }[]) => {
    if (!items.length) return;
    need(40);
    heading(title);
    for (const i of items) {
      need(14);
      text(myt(i.at).slice(0, 10), M + 8, y);
      text(fit(i.label, 330), M + 90, y);
      right(money(i.amount), col, y);
      y -= fs.body + 4;
    }
  };

  // Breakdown.
  const cols = [M + 8, M + 190, M + 270, M + 370, col];
  const table = (title: string, heads: string[], body: string[][]) => {
    need(50);
    y -= 6;
    text(title, M, y, fs.heading, bold, BRAND);
    y -= fs.heading + 4;
    heads.forEach((h, i) => (i === 0 ? text(h, cols[0], y, fs.table, bold, MUTED) : right(h, cols[i + 1], y, fs.table, bold, MUTED)));
    y -= 4;
    rule(y);
    y -= fs.table + 4;
    for (const r of body) {
      need(14);
      r.forEach((c, i) => (i === 0 ? text(c, cols[0], y, fs.table + 1) : right(c, cols[i + 1], y, fs.table + 1)));
      y -= fs.table + 5;
    }
  };
  const breakdownRows = (items: { start: string; end?: string; totals: Totals }[], label: (s: string, e?: string) => string) =>
    items.map((b) => [label(b.start, b.end), String(b.totals.trips ?? 0), money(b.totals.totalEarnings), money(b.totals.net)]);
  const heads = (first: string) => [first, w.trips, w.earned, w.net];
  const breakdown = () => {
    if (d.type === "weekly") {
      if (!on("daily")) return;
      table(w.daily, heads(w.date), breakdownRows(d.breakdown, (s) => {
        const i = (new Date(`${s}T00:00:00Z`).getUTCDay() + 6) % 7;
        return `${w.days[i]} ${day(s, lang)}`;
      }));
    } else if (d.type === "monthly") {
      if (!on("weeklyBreakdown")) return;
      table(w.weeklyBreakdown, heads(w.week), breakdownRows(d.breakdown, (s, e) => `${day(s, lang)} - ${day(e ?? s, lang)}`));
    } else {
      if (!on("monthlyBreakdown")) return;
      table(w.monthlyBreakdown, heads(w.month), breakdownRows(d.breakdown, (s) => periodLabel({ type: "monthly", periodStart: s, periodEnd: s }, lang)));
    }
  };

  // Trips (weekly).
  const tripList = () => {
    if (d.type !== "weekly" || !d.trips.length || !on("tripList")) return;
    const tc = [M + 8, M + 95, M + 175, M + 265, M + 345, M + 425, col];
    const size = fs.table;
    need(50);
    y -= 6;
    text(w.tripList, M, y, fs.heading, bold, BRAND);
    y -= fs.heading + 4;
    const th = [w.time, w.service, w.payment, w.fare, w.earned, w.commission];
    th.forEach((h, i) => (i < 3 ? text(h, tc[i], y, size, bold, MUTED) : right(h, tc[i + 1], y, size, bold, MUTED)));
    y -= 4;
    rule(y);
    y -= size + 4;
    for (const t of d.trips) {
      need(14);
      const l = t.lines;
      text(myt(t.at), tc[0], y, size);
      text(fit(t.kind === "meter" ? w.meter : t.service ?? "", 75, size), tc[1], y, size);
      text(fit(t.payment ?? "", 80, size), tc[2], y, size);
      right(money(l.fare), tc[4], y, size);
      right(money((l.fare ?? 0) + (l.surcharges ?? 0) + (l.platformCollected ?? 0)), tc[5], y, size);
      right(money(-(l.commission ?? 0)), tc[6], y, size);
      y -= size + 4;
    }
  };

  for (const s of L.sections) {
    if (s === "incentivesList") {
      if (on(s)) listed(w.incentivesList, d.incentives);
    } else if (s === "adjustmentsList") {
      if (on(s)) listed(w.adjustmentsList, d.adjustments.map((a) => ({ at: a.at, label: a.reason, amount: a.amount })));
    } else if (s === "breakdown") {
      breakdown();
    } else if (s === "tripList") {
      tripList();
    } else {
      summary(s);
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
  const textX = on("verify") ? M + size + 10 : M;
  pages.forEach((pg, i) => {
    page = pg;
    rule(M + 62);
    if (on("verify")) {
      for (let r = 0; r < n; r++) {
        for (let c = 0; c < n; c++) {
          if (qr.isDark(r, c)) {
            pg.drawRectangle({ x: M + c * cell, y: M + size - (r + 1) * cell, width: cell + 0.05, height: cell + 0.05, color: INK });
          }
        }
      }
      text(w.verify, textX, M + 40, fs.small + 1, bold);
      text(fit(meta.verifyUrl, 300, fs.small), textX, M + 29, fs.small, font, MUTED);
    }
    if (on("footer")) text(fit(w.footer, 380, fs.small), textX, M + 14, fs.small, font, MUTED);
    if (on("pageNumbers")) right(w.page(i + 1, pages.length), A4.w - M, M + 14, fs.small, font, MUTED);
    if (on("statementNo")) right(meta.statementNo, A4.w - M, M + 40, fs.small + 1, bold);
  });

  return await doc.save();
}

// ---- The request ---------------------------------------------------------------------------
export interface StatementRow {
  statement_no: string;
  verify_token: string;
  is_final: boolean;
  data_hash: string;
  /** The layout it was drawn with; null: the built-in one. */
  layout_hash?: string | null;
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
  /** The saved layout and its logo; left out, the built-in look. */
  look?(): Promise<RenderLook & { layout: StatementLayout }>;
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
  const look = deps.look ? await deps.look() : { layout: cleanLayout({}), logo: null };
  const lHash = await layoutHash(look.layout);
  const row = await deps.find(uid, req.type, req.start, req.lang);
  const name = fileName(data, req.lang);
  const final = data.status === "final";
  const sameLook = (row?.layout_hash ?? (await layoutHash(cleanLayout({})))) === lHash;

  if (row && row.is_final && final && row.data_hash === hash && sameLook) {
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
  // A final copy whose numbers changed is revised; one made before the period closed, or only
  // redrawn in a new layout, is not.
  const revisedAt = row?.is_final && final && row.data_hash !== hash ? now : null;
  const pdf = await (deps.render ?? renderStatement)(data, {
    statementNo,
    verifyUrl: verifyLink(data.company.verifyUrl, token),
    issuedAt: now,
    revisedAt: revisedAt ?? (final ? row?.revised_at ?? null : null),
  }, look);
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
    layout_hash: lHash,
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

// ---- The admin's sample --------------------------------------------------------------------
export interface PreviewDeps {
  /** Whether the caller is an admin (any access). */
  isAdmin(): Promise<boolean>;
  company(): Promise<StatementData["company"]>;
  /** The logo at this `app-branding` path, or null. */
  logo(path: string): Promise<RenderLook["logo"]>;
  render?: typeof renderStatement;
}

/**
 * POST { preview: true, type, lang, layout } → { pdf (base64), fileName }: a made-up
 * statement drawn in the layout being edited, before it is saved.
 */
export async function handlePreview(body: unknown, deps: PreviewDeps): Promise<StatementAnswer> {
  const b = (body && typeof body === "object" ? body : {}) as Record<string, unknown>;
  const type = typeof b.type === "string" && PERIOD.test(b.type) ? (b.type as PeriodType) : "monthly";
  const lang: Lang = b.lang === "ms" ? "ms" : "en";
  if (JSON.stringify(b.layout ?? {}).length > 20_000) return fail("bad_request", 400);
  if (!(await deps.isAdmin())) return fail("not_authorized", 403);
  const layout = cleanLayout(b.layout);
  const data = sampleStatement(type, lang, await deps.company());
  const logo = layout.logo.path ? await deps.logo(layout.logo.path) : null;
  const pdf = await (deps.render ?? renderStatement)(data, {
    statementNo: "SAMPLE",
    verifyUrl: verifyLink(data.company.verifyUrl, "SAMPLE"),
    issuedAt: new Date().toISOString(),
    revisedAt: null,
  }, { layout, logo });
  let bin = "";
  for (let i = 0; i < pdf.length; i += 0x8000) bin += String.fromCharCode(...pdf.subarray(i, i + 0x8000));
  return { status: 200, body: { pdf: btoa(bin), fileName: `getride-statement-${type}-SAMPLE-${lang}.pdf` } };
}

/** PNG or JPEG, by their first bytes; anything else is not drawn. */
export function logoKind(bytes: Uint8Array): { bytes: Uint8Array; png: boolean } | null {
  if (bytes.length > 2_000_000) return null;
  if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) return { bytes, png: true };
  if (bytes[0] === 0xff && bytes[1] === 0xd8) return { bytes, png: false };
  return null;
}
