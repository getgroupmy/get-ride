/**
 * Admin -> Reports (migration 0280): a report's files for the scheduled
 * emails, made here as the app makes them on the page: CSV (UTF-8 with a
 * BOM, so Excel reads the accents), Excel (.xlsx: the table, then "What the
 * AI understood") and PDF (the logo, title, period, a bar chart, the table
 * and page numbers).
 *
 * The .xlsx is written by hand (a zip of a few XML files, stored, not
 * compressed): no Excel library is needed for a plain table.
 *
 *     deno test supabase/functions/_shared/report_files_test.ts
 */
import { PDFDocument, type PDFFont, type PDFImage, type PDFPage, rgb, StandardFonts } from "npm:pdf-lib@1.17.1";

import { latin1 } from "./partner_statement.ts";

export interface ReportColumn {
  id: string;
  label: string;
  type: "text" | "number" | "time" | "bool";
  role: "group" | "measure" | "column";
  field?: string;
  agg?: string;
  bucket?: string | null;
}

/** What ai_report_run answers. */
export interface ReportResult {
  dataset: string;
  dataset_label: string;
  columns: ReportColumn[];
  rows: unknown[][];
  totals: unknown[] | null;
  row_count: number;
  truncated: boolean;
  max_rows: number;
  period: { from: string; to: string; preset?: string; days?: number; field?: string } | null;
  hidden?: string[];
  limited?: boolean;
  plan: unknown;
}

/** The total row, lined up with the columns: "Total", blanks, the figures. */
export function totalRow(r: ReportResult): unknown[] | null {
  if (!r.totals) return null;
  const measures = r.columns.filter((c) => c.role === "measure").length;
  const groups = r.columns.length - measures;
  return [...Array.from({ length: groups }, (_, i) => (i === 0 ? "Total" : "")), ...r.totals.slice(0, measures)];
}

// ---- CSV ----------------------------------------------------------------------------------------

/** One CSV cell. Text that a spreadsheet would run as a formula gets a leading '. */
export function csvCell(v: unknown): string {
  if (v === null || v === undefined) return "";
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  let s = String(v);
  if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`;
  return /[",\r\n]|^\s|\s$/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

export function reportCsv(r: ReportResult): string {
  const lines = [r.columns.map((c) => csvCell(c.label)).join(",")];
  for (const row of r.rows) lines.push(row.map(csvCell).join(","));
  const total = totalRow(r);
  if (total) lines.push(total.map(csvCell).join(","));
  return `\uFEFF${lines.join("\r\n")}\r\n`;
}

// ---- Zip (stored) -------------------------------------------------------------------------------

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

export function crc32(bytes: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

/** A zip of [files], stored (no compression), as the .xlsx format allows. */
export function zipStore(files: { name: string; data: Uint8Array }[]): Uint8Array {
  const enc = new TextEncoder();
  const parts: Uint8Array[] = [];
  const central: Uint8Array[] = [];
  let offset = 0;
  for (const f of files) {
    const name = enc.encode(f.name);
    const crc = crc32(f.data);
    const local = new Uint8Array(30 + name.length);
    const lv = new DataView(local.buffer);
    lv.setUint32(0, 0x04034b50, true);
    lv.setUint16(4, 20, true);
    lv.setUint16(6, 0x0800, true); // UTF-8 names
    lv.setUint16(8, 0, true); // stored
    lv.setUint16(10, 0, true);
    lv.setUint16(12, 0x21, true); // 1980-01-01
    lv.setUint32(14, crc, true);
    lv.setUint32(18, f.data.length, true);
    lv.setUint32(22, f.data.length, true);
    lv.setUint16(26, name.length, true);
    lv.setUint16(28, 0, true);
    local.set(name, 30);
    const cen = new Uint8Array(46 + name.length);
    const cv = new DataView(cen.buffer);
    cv.setUint32(0, 0x02014b50, true);
    cv.setUint16(4, 20, true);
    cv.setUint16(6, 20, true);
    cv.setUint16(8, 0x0800, true);
    cv.setUint16(10, 0, true);
    cv.setUint16(12, 0, true);
    cv.setUint16(14, 0x21, true);
    cv.setUint32(16, crc, true);
    cv.setUint32(20, f.data.length, true);
    cv.setUint32(24, f.data.length, true);
    cv.setUint16(28, name.length, true);
    cv.setUint32(42, offset, true);
    cen.set(name, 46);
    parts.push(local, f.data);
    central.push(cen);
    offset += local.length + f.data.length;
  }
  const size = central.reduce((n, c) => n + c.length, 0);
  const end = new Uint8Array(22);
  const ev = new DataView(end.buffer);
  ev.setUint32(0, 0x06054b50, true);
  ev.setUint16(8, files.length, true);
  ev.setUint16(10, files.length, true);
  ev.setUint32(12, size, true);
  ev.setUint32(16, offset, true);
  const all = [...parts, ...central, end];
  const out = new Uint8Array(all.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of all) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

// ---- Excel --------------------------------------------------------------------------------------

/** Text safe inside XML: escaped, without the control characters XML forbids. */
export function xmlText(s: string): string {
  // deno-lint-ignore no-control-regex
  return s.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\ufffe\uffff]/g, "")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function colName(i: number): string {
  let s = "";
  for (let n = i + 1; n > 0; n = Math.floor((n - 1) / 26)) s = String.fromCharCode(65 + ((n - 1) % 26)) + s;
  return s;
}

function sheetXml(rows: unknown[][], boldRows: Set<number>, widths: number[]): string {
  const body = rows.map((row, r) => {
    const cells = row.map((v, c) => {
      const ref = `${colName(c)}${r + 1}`;
      const style = boldRows.has(r) ? ' s="1"' : "";
      if (v === null || v === undefined || v === "") return `<c r="${ref}"${style}/>`;
      if (typeof v === "number" && Number.isFinite(v)) return `<c r="${ref}"${style}><v>${v}</v></c>`;
      if (typeof v === "boolean") return `<c r="${ref}"${style} t="b"><v>${v ? 1 : 0}</v></c>`;
      return `<c r="${ref}"${style} t="inlineStr"><is><t xml:space="preserve">${xmlText(String(v))}</t></is></c>`;
    }).join("");
    return `<row r="${r + 1}">${cells}</row>`;
  }).join("");
  const cols = widths.length
    ? `<cols>${widths.map((w, i) => `<col min="${i + 1}" max="${i + 1}" width="${w}" customWidth="1"/>`).join("")}</cols>`
    : "";
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
    `<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">` +
    `<sheetViews><sheetView workbookViewId="0">${boldRows.has(0) ? '<pane ySplit="1" topLeftCell="A2" state="frozen"/>' : ""}</sheetView></sheetViews>` +
    `${cols}<sheetData>${body}</sheetData></worksheet>`;
}

/** Numbers stay numbers in Excel; the rest is text. */
function cellValue(v: unknown, type: string): unknown {
  if (type === "number" && typeof v === "string" && v.trim() !== "" && Number.isFinite(Number(v))) return Number(v);
  return v;
}

/** The workbook: sheet 1 the table (with the total row), sheet 2 what the AI understood. */
export function reportXlsx(r: ReportResult, understood: [string, string][]): Uint8Array {
  const enc = new TextEncoder();
  const table: unknown[][] = [r.columns.map((c) => c.label)];
  for (const row of r.rows) table.push(row.map((v, i) => cellValue(v, r.columns[i]?.type ?? "text")));
  const total = totalRow(r);
  const bold = new Set([0]);
  if (total) {
    bold.add(table.length);
    table.push(total.map((v, i) => cellValue(v, r.columns[i]?.type ?? "text")));
  }
  if (r.truncated) table.push([`Showing first ${r.max_rows.toLocaleString("en-US")} rows`]);
  const widths = r.columns.map((c) => Math.min(40, Math.max(10, c.label.length + 2)));
  const sheet2: unknown[][] = [["What the AI understood", ""], ...understood.map(([k, v]) => [k, v])];
  const files = [
    {
      name: "[Content_Types].xml",
      text: `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
        `<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">` +
        `<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>` +
        `<Default Extension="xml" ContentType="application/xml"/>` +
        `<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>` +
        `<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>` +
        `<Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>` +
        `<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>` +
        `</Types>`,
    },
    {
      name: "_rels/.rels",
      text: `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
        `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
        `<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>` +
        `</Relationships>`,
    },
    {
      name: "xl/workbook.xml",
      text: `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
        `<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">` +
        `<sheets><sheet name="Report" sheetId="1" r:id="rId1"/><sheet name="What the AI understood" sheetId="2" r:id="rId2"/></sheets>` +
        `</workbook>`,
    },
    {
      name: "xl/_rels/workbook.xml.rels",
      text: `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
        `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
        `<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>` +
        `<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>` +
        `<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>` +
        `</Relationships>`,
    },
    {
      name: "xl/styles.xml",
      text: `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
        `<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">` +
        `<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>` +
        `<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>` +
        `<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>` +
        `<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>` +
        `<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>` +
        `<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>` +
        `<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>` +
        `</styleSheet>`,
    },
    { name: "xl/worksheets/sheet1.xml", text: sheetXml(table, bold, widths) },
    { name: "xl/worksheets/sheet2.xml", text: sheetXml(sheet2, new Set([0]), [24, 80]) },
  ];
  return zipStore(files.map((f) => ({ name: f.name, data: enc.encode(f.text) })));
}

// ---- PDF ----------------------------------------------------------------------------------------

/** The PDF lists this many rows at most; the CSV and Excel files have them all. */
export const PDF_MAX_ROWS = 2000;

export function cellText(v: unknown, type: string): string {
  if (v === null || v === undefined) return "";
  if (typeof v === "boolean") return v ? "Yes" : "No";
  if (type === "number") {
    const n = Number(v);
    if (Number.isFinite(n)) {
      return n.toLocaleString("en-US", { maximumFractionDigits: 2, minimumFractionDigits: Number.isInteger(n) ? 0 : 2 });
    }
  }
  return String(v);
}

/** One measure by one group, the biggest first: what the chart draws (null when it can't). */
export function chartBars(r: ReportResult, max = 12): { label: string; value: number }[] | null {
  const gi = r.columns.findIndex((c) => c.role === "group");
  const mi = r.columns.findIndex((c) => c.role === "measure" && c.type === "number");
  if (gi < 0 || mi < 0) return null;
  const groups = r.columns.filter((c) => c.role === "group").map((c) => r.columns.indexOf(c));
  const bars = r.rows.map((row) => ({
    label: groups.map((i) => cellText(row[i], "text")).join(" · "),
    value: Number(row[mi]) || 0,
  }));
  if (bars.length === 0 || bars.every((b) => b.value <= 0)) return null;
  return bars.slice(0, max);
}

export interface PdfMeta {
  title: string;
  period: string;
  madeAt: string;
  logo?: { bytes: Uint8Array; png: boolean } | null;
}

const A4 = { w: 595.28, h: 841.89 };
const M = 36;

export async function reportPdf(r: ReportResult, meta: PdfMeta): Promise<Uint8Array> {
  const INK = rgb(0.09, 0.13, 0.17);
  const MUTED = rgb(0.36, 0.42, 0.48);
  const RULE = rgb(0.84, 0.87, 0.9);
  const BAR = rgb(0.05, 0.48, 0.72);
  const doc = await PDFDocument.create();
  doc.setTitle(latin1(meta.title));
  doc.setCreator("GET.ride");
  doc.setProducer("GET.ride");
  const font = await doc.embedFont(StandardFonts.Helvetica);
  const bold = await doc.embedFont(StandardFonts.HelveticaBold);
  let logo: PDFImage | null = null;
  if (meta.logo) {
    try {
      logo = meta.logo.png ? await doc.embedPng(meta.logo.bytes) : await doc.embedJpg(meta.logo.bytes);
    } catch {
      logo = null;
    }
  }

  let page!: PDFPage;
  let y = 0;
  const fit = (s: string, max: number, size: number, f: PDFFont) => {
    let t = latin1(s);
    while (t.length > 1 && f.widthOfTextAtSize(t, size) > max) t = t.slice(0, -2) + ".";
    return t;
  };
  const text = (s: string, x: number, yy: number, size: number, f: PDFFont = font, c = INK) =>
    page.drawText(latin1(s), { x, y: yy, size, font: f, color: c });
  const right = (s: string, xr: number, yy: number, size: number, f: PDFFont = font, c = INK) =>
    page.drawText(s, { x: xr - f.widthOfTextAtSize(s, size), y: yy, size, font: f, color: c });

  page = doc.addPage([A4.w, A4.h]);
  y = A4.h - M;
  if (logo) {
    const h = 28;
    const w = (h * logo.width) / logo.height;
    page.drawImage(logo, { x: M, y: y - h, width: w, height: h });
    y -= h + 10;
  } else {
    text("GET.ride", M, y - 16, 16, bold, BAR);
    y -= 26;
  }
  text(fit(meta.title, A4.w - 2 * M, 16, bold), M, y - 16, 16, bold);
  y -= 24;
  text(fit(meta.period, A4.w - 2 * M, 10, font), M, y - 10, 10, font, MUTED);
  y -= 14;
  text(`Made ${meta.madeAt} (Malaysia time). ${r.row_count.toLocaleString("en-US")} rows.`, M, y - 9, 9, font, MUTED);
  y -= 20;

  const bars = chartBars(r);
  if (bars) {
    const top = Math.max(...bars.map((b) => b.value));
    const labelW = 150, valueW = 70, barW = A4.w - 2 * M - labelW - valueW - 12;
    for (const b of bars) {
      text(fit(b.label, labelW - 6, 9, font), M, y - 9, 9);
      const w = top > 0 ? Math.max(1, (barW * Math.max(0, b.value)) / top) : 1;
      page.drawRectangle({ x: M + labelW, y: y - 10, width: w, height: 9, color: BAR });
      right(cellText(b.value, "number"), A4.w - M, y - 9, 9);
      y -= 14;
    }
    y -= 10;
  }

  const cols = r.columns;
  const colW = (A4.w - 2 * M) / Math.max(1, cols.length);
  const size = cols.length > 8 ? 7 : 8.5;
  const header = () => {
    for (const [i, c] of cols.entries()) {
      const t = fit(c.label, colW - 4, size, bold);
      if (c.type === "number") right(t, M + (i + 1) * colW - 2, y - size, size, bold, MUTED);
      else text(t, M + i * colW, y - size, size, bold, MUTED);
    }
    y -= size + 4;
    page.drawLine({ start: { x: M, y }, end: { x: A4.w - M, y }, thickness: 0.5, color: RULE });
    y -= 4;
  };
  const row = (vals: unknown[], f: PDFFont) => {
    if (y < M + 30) {
      page = doc.addPage([A4.w, A4.h]);
      y = A4.h - M;
      header();
    }
    for (const [i, c] of cols.entries()) {
      const t = fit(cellText(vals[i], c.type), colW - 4, size, f);
      if (c.type === "number") right(t, M + (i + 1) * colW - 2, y - size, size, f);
      else text(t, M + i * colW, y - size, size, f);
    }
    y -= size + 5;
  };
  header();
  for (const v of r.rows.slice(0, PDF_MAX_ROWS)) row(v, font);
  const total = totalRow(r);
  if (total) row(total, bold);
  if (r.truncated || r.rows.length > PDF_MAX_ROWS) {
    y -= 6;
    if (y < M + 20) {
      page = doc.addPage([A4.w, A4.h]);
      y = A4.h - M;
    }
    const note = r.rows.length > PDF_MAX_ROWS
      ? `This PDF lists the first ${PDF_MAX_ROWS.toLocaleString("en-US")} rows; the CSV and Excel files have them all.`
      : `Showing first ${r.max_rows.toLocaleString("en-US")} rows.`;
    text(note, M, y - 9, 9, font, MUTED);
  }

  const pages = doc.getPages();
  for (const [i, p] of pages.entries()) {
    const s = `Page ${i + 1} of ${pages.length}`;
    p.drawText(s, { x: A4.w - M - font.widthOfTextAtSize(s, 8), y: M / 2, size: 8, font, color: MUTED });
    p.drawText("GET.ride", { x: M, y: M / 2, size: 8, font, color: MUTED });
  }
  return await doc.save();
}
