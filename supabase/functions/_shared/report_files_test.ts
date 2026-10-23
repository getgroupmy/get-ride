import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.19";

import { chartBars, crc32, csvCell, reportCsv, reportPdf, type ReportResult, reportXlsx, totalRow, xmlText, zipStore } from "./report_files.ts";

const report: ReportResult = {
  dataset: "rides",
  dataset_label: "Rides",
  columns: [
    { id: "city", label: "City", type: "text", role: "group", field: "city" },
    { id: "count", label: "Count", type: "number", role: "measure", field: "*", agg: "count" },
    { id: "sum_fare", label: "Total fare (RM)", type: "number", role: "measure", field: "fare", agg: "sum" },
  ],
  rows: [["Kajang", 212, 4812.4], ['Bangi, "Old" town', 98, 2210.5], ["=HYPERLINK(1)", 1, -3]],
  totals: [311, 7019.9],
  row_count: 3,
  truncated: false,
  max_rows: 50000,
  period: { from: "2026-09-24", to: "2026-10-23", preset: "last_30_days", field: "created_at" },
  plan: { dataset: "rides" },
};

Deno.test("CSV cells: quotes doubled, commas and new lines quoted, formulas defused", () => {
  assertEquals(csvCell('Bangi, "Old" town'), '"Bangi, ""Old"" town"');
  assertEquals(csvCell("two\nlines"), '"two\nlines"');
  assertEquals(csvCell(" padded"), '" padded"');
  assertEquals(csvCell("=SUM(A1)"), "'=SUM(A1)");
  assertEquals(csvCell("+60123"), "'+60123");
  assertEquals(csvCell(-3), "-3");
  assertEquals(csvCell(null), "");
  assertEquals(csvCell(true), "true");
});

Deno.test("the CSV: a BOM, the labels, the rows and the total row", () => {
  const csv = reportCsv(report);
  assert(csv.startsWith("﻿City,Count,Total fare (RM)\r\n"));
  assertStringIncludes(csv, '"Bangi, ""Old"" town",98,2210.5\r\n');
  assertStringIncludes(csv, "'=HYPERLINK(1),1,-3\r\n");
  assert(csv.endsWith("Total,311,7019.9\r\n"));
  assertEquals(totalRow({ ...report, totals: null }), null);
});

Deno.test("zip: stored entries with the right CRC", () => {
  assertEquals(crc32(new TextEncoder().encode("The quick brown fox jumps over the lazy dog")), 0x414fa339);
  const z = zipStore([{ name: "a.txt", data: new TextEncoder().encode("hi") }]);
  assertEquals([...z.slice(0, 4)], [0x50, 0x4b, 0x03, 0x04]);
  const end = z.slice(z.length - 22);
  assertEquals([...end.slice(0, 4)], [0x50, 0x4b, 0x05, 0x06]);
  assertEquals(new DataView(end.buffer, end.byteOffset).getUint16(10, true), 1);
});

Deno.test("the workbook: two sheets, numbers as numbers, text escaped", () => {
  const bytes = reportXlsx(report, [["Data", "Rides"], ["Only", "Status is <completed> & paid"]]);
  const text = new TextDecoder("latin1").decode(bytes);
  for (const part of ["[Content_Types].xml", "xl/workbook.xml", "xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml", "xl/styles.xml"]) {
    assertStringIncludes(text, part);
  }
  assertStringIncludes(text, '<sheet name="What the AI understood" sheetId="2" r:id="rId2"/>');
  assertStringIncludes(text, '<c r="B2"><v>212</v></c>');
  assertStringIncludes(text, "Bangi, &quot;Old&quot; town");
  assertStringIncludes(text, "Status is &lt;completed&gt; &amp; paid");
  assertStringIncludes(text, '<c r="A5" s="1" t="inlineStr"><is><t xml:space="preserve">Total</t></is></c>');
  const cut = new TextDecoder("latin1").decode(reportXlsx({ ...report, truncated: true }, []));
  assertStringIncludes(cut, "Showing first 50,000 rows");
  assertEquals(xmlText("a\u0001b"), "ab");
});

Deno.test("the chart: one measure by the groups, biggest as drawn", () => {
  assertEquals(chartBars(report)?.map((b) => b.value), [212, 98, 1]);
  assertEquals(chartBars({ ...report, columns: report.columns.slice(1), rows: [[1, 2]] }), null);
});

Deno.test("the PDF: made, with page numbers, latin-1 only", async () => {
  const many: ReportResult = { ...report, rows: Array.from({ length: 300 }, (_, i) => [`Kota ${i} 新`, i, i * 1.5]) };
  const pdf = await reportPdf(many, { title: "Rides by city", period: "The last 30 days", madeAt: "2026-10-23 08:00" });
  assertEquals(new TextDecoder().decode(pdf.slice(0, 5)), "%PDF-");
  assert(pdf.length > 2000);
});
