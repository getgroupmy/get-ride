import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.19";

import { catalogueForPrompt, checkPlan, describePlan, malaysiaToday, type Plan, periodWords, reportPrompt } from "./ai_report_plan.ts";
import { fullCatalogue, subAdminCatalogue } from "./ai_report_fixture.ts";

const reason = (raw: unknown, cat = fullCatalogue) => {
  const r = checkPlan(raw, cat);
  assert(!r.ok, `expected a refusal for ${JSON.stringify(raw)}`);
  return r.reason;
};
const ok = (raw: unknown, cat = fullCatalogue): Plan => {
  const r = checkPlan(raw, cat);
  if (!r.ok) throw new Error(r.reason);
  return r.plan;
};

Deno.test("an unknown dataset, field, op or aggregate is refused in words", () => {
  assertStringIncludes(reason({ dataset: "people" }), 'no dataset "people"');
  assertStringIncludes(reason({ dataset: "users", columns: ["pin_hash"] }), 'Users has no field "pin_hash"');
  assertStringIncludes(reason({ dataset: "rides", filters: [{ field: "otp", op: "eq", value: "1" }] }), 'no field "otp"');
  assertStringIncludes(reason({ dataset: "rides", group_by: ["id; drop table x"] }), "Rides has no field");
  assertStringIncludes(reason({ dataset: "rides", filters: [{ field: "fare", op: "contains", value: "1" }] }), "can't be used on");
  assertStringIncludes(reason({ dataset: "rides", measures: [{ field: "fare", agg: "median" }] }), "not a way to sum up");
  assertStringIncludes(reason({ dataset: "rides", measures: [{ field: "service", agg: "sum" }] }), "is not a number");
  assertStringIncludes(reason({ dataset: "rides", group_by: ["service:month"] }), "Only dates");
  assertStringIncludes(reason({ dataset: "rides", sort: [{ field: "city", dir: "asc" }], group_by: ["service"] }), "isn't a column");
  assertStringIncludes(reason("SELECT * FROM profiles"), "not a report plan");
});

Deno.test("values must fit the field", () => {
  assertStringIncludes(reason({ dataset: "rides", filters: [{ field: "fare", op: "gt", value: "1; select 1" }] }), "needs a number");
  assertStringIncludes(reason({ dataset: "rides", filters: [{ field: "fare", op: "between", value: [1] }] }), "two numbers");
  assertStringIncludes(reason({ dataset: "rides", filters: [{ field: "created_at", op: "gte", value: "2026-02-30" }] }), "a date");
  assertStringIncludes(reason({ dataset: "rides", filters: [{ field: "status", op: "in", value: [] }] }), "list of 1 to 50");
  assertStringIncludes(reason({ dataset: "partners", filters: [{ field: "documents_ok", op: "eq", value: "maybe" }] }), "yes (true)");
  assertStringIncludes(reason({ dataset: "rides", period: { preset: "forever" } }), 'Unknown period "forever"');
  assertStringIncludes(reason({ dataset: "rides", period: { preset: "last_n_days", days: 0 } }), "N from 1 to 366");
  assertStringIncludes(reason({ dataset: "rides", period: { from: "2026-10-10", to: "2026-10-01" } }), "ends before");
});

Deno.test("the catalogue's limits", () => {
  assertEquals(fullCatalogue.limits.max_rows, 50000);
  assertStringIncludes(reason({ dataset: "rides", group_by: ["service", "city", "state", "suburb"] }), "at most 3");
  const nine = ["fare", "commission", "distance_km"].flatMap((field) => ["sum", "avg", "max"].map((agg) => ({ field, agg })));
  assertStringIncludes(reason({ dataset: "rides", measures: nine }), "At most 8");
  assertStringIncludes(reason({ dataset: "rides", filters: Array.from({ length: 13 }, () => ({ field: "status", op: "not_null" })) }), "At most 12");
  // A limit at or over 50,000 is the cap itself.
  assertEquals(ok({ dataset: "rides", limit: 999999 }).limit, null);
  assertEquals(ok({ dataset: "rides", limit: 20 }).limit, 20);
  assertStringIncludes(reason({ dataset: "rides", limit: 0 }), "at least 1");
});

Deno.test("personal fields are only in the catalogue of an admin with the People pages", () => {
  assertEquals(ok({ dataset: "rides", columns: ["driver_name"] }).columns, ["driver_name"]);
  assertStringIncludes(reason({ dataset: "rides", columns: ["driver_name"] }, subAdminCatalogue), 'no field "driver_name"');
  assertStringIncludes(reason({ dataset: "users", filters: [{ field: "phone", op: "eq", value: "1" }] }, subAdminCatalogue), 'no field "phone"');
  const rides = subAdminCatalogue.datasets.find((d) => d.id === "rides")!;
  assert(rides.hidden!.includes("Driver name"));
  // Nothing secret anywhere.
  for (const d of fullCatalogue.datasets) {
    for (const f of d.fields) assert(!/pin|hash|id_image|token|otp|key/.test(f.id), `${d.id}.${f.id}`);
  }
});

Deno.test("a good plan is tidied: date groups get a bucket, sorts name the column", () => {
  const p = ok({
    dataset: "rides",
    title: "  Fares by month  ",
    group_by: ["created_at", "service"],
    measures: [{ field: "*", agg: "count" }, { field: "fare", agg: "sum" }],
    sort: [{ field: "fare", dir: "DESC" }, { field: "count", dir: "asc" }],
    filters: [{ field: "status", op: "eq", value: "completed" }, { field: "cancel_reason", op: "is_null", value: "x" }],
    period: { preset: "last_n_days", days: "14" },
  });
  assertEquals(p.group_by, ["created_at:day", "service"]);
  assertEquals(p.sort, [{ field: "sum_fare", dir: "desc" }, { field: "count", dir: "asc" }]);
  assertEquals(p.filters[1], { field: "cancel_reason", op: "is_null" });
  assertEquals(p.period, { preset: "last_n_days", field: "created_at", days: 14 });
  assertEquals(p.title, "Fares by month");
});

Deno.test("what the AI is told: names and types, no views, no data", () => {
  const told = JSON.stringify(catalogueForPrompt(subAdminCatalogue));
  assert(!told.includes("ai_report_v_"));
  assert(!told.includes("driver_name"));
  const prompt = reportPrompt("Cancelled rides by reason, last 7 days", subAdminCatalogue, "2026-10-23", 'Rides has no field "x".');
  assertStringIncludes(prompt, "Today in Malaysia is 2026-10-23.");
  assertStringIncludes(prompt, "Cancelled rides by reason");
  assertStringIncludes(prompt, "Your last plan was refused: Rides has no field");
  assertEquals(malaysiaToday(new Date("2026-10-23T16:30:00Z")), "2026-10-24");
});

Deno.test("the plan in plain words", () => {
  const p = ok({
    dataset: "rides",
    group_by: ["city", "service"],
    measures: [{ field: "*", agg: "count" }, { field: "fare", agg: "sum" }],
    filters: [{ field: "status", op: "in", value: ["completed"] }],
    period: { preset: "last_30_days" },
    sort: [{ field: "fare", dir: "desc" }],
  }, subAdminCatalogue);
  const lines = Object.fromEntries(describePlan(p, subAdminCatalogue, {
    resolved: { from: "2026-09-24", to: "2026-10-23" },
    columns: [{ id: "sum_fare", label: "Total fare (RM)" }],
  }));
  assertEquals(lines["Data"], "Rides");
  assertEquals(lines["Period"], "The last 30 days (24 Sep 2026 to 23 Oct 2026), by Booked, Malaysia time");
  assertEquals(lines["Only"], "Status is one of completed");
  assertEquals(lines["Group by"], "City, Service");
  assertEquals(lines["Figures"], "Count, Total fare (RM)");
  assertEquals(lines["Sort"], "Total fare (RM), highest first");
  assertStringIncludes(lines["Hidden"], "Rider name");
  assertEquals(periodWords(null), "All time");
  assertEquals(periodWords({ from: "2026-10-01", to: "2026-10-01" }), "1 Oct 2026");
});
