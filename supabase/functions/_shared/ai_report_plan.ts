/**
 * Admin -> Reports (migration 0280): a report plan, what the AI is asked
 * for one, the check of its answer against the caller's catalogue, and the
 * plan in plain words. The pure half of the ai-report and ai-report-email
 * functions.
 *
 * The catalogue is the database's (`ai_report_catalogue()`, read as the
 * caller, so a sub-admin's has no personal fields they may not see). The
 * AI is told the catalogue and the request, never a row of data, and may
 * answer only a plan:
 *
 *   { dataset, columns?, filters[{field, op, value}], period {from, to} |
 *     {preset, days?}, group_by[], measures[{field, agg}],
 *     sort[{field, dir}], limit?, title }
 *
 * The database checks the plan again when it runs it (ai_report_run) and
 * builds the query from the catalogue's own names only; this check is
 * there so a wrong answer is caught early, with a reason a person can read,
 * and the AI asked once more.
 *
 *     deno test supabase/functions/_shared/ai_report_plan_test.ts
 */

export type FieldType = "text" | "number" | "time" | "bool";

export interface CatalogueField {
  id: string;
  label: string;
  type: FieldType;
  values?: string[];
  personal?: string;
}

export interface CatalogueDataset {
  id: string;
  label: string;
  about?: string;
  time: string;
  list?: string[];
  fields: CatalogueField[];
  hidden?: string[];
  limited?: boolean;
}

export interface Catalogue {
  datasets: CatalogueDataset[];
  aggs: string[];
  ops: Record<FieldType, string[]>;
  buckets: string[];
  presets: string[];
  limits: {
    max_rows: number;
    max_columns: number;
    max_group_by: number;
    max_measures: number;
    max_filters: number;
    max_sort: number;
    max_in: number;
  };
}

export interface PlanFilter {
  field: string;
  op: string;
  value?: unknown;
}

export interface PlanPeriod {
  from?: string;
  to?: string;
  preset?: string;
  days?: number;
  field?: string;
}

export interface Plan {
  dataset: string;
  columns: string[];
  filters: PlanFilter[];
  period: PlanPeriod | null;
  group_by: string[];
  measures: { field: string; agg: string }[];
  sort: { field: string; dir: "asc" | "desc" }[];
  limit: number | null;
  title: string;
}

export type PlanCheck = { ok: true; plan: Plan } | { ok: false; reason: string };

const DATE = /^\d{4}-\d{2}-\d{2}$/;

function isDate(v: unknown): v is string {
  if (typeof v !== "string" || !DATE.test(v)) return false;
  const d = new Date(`${v}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === v;
}

const isNumber = (v: unknown) =>
  (typeof v === "number" && Number.isFinite(v)) || (typeof v === "string" && v.trim() !== "" && Number.isFinite(Number(v)));

const list = (v: unknown): unknown[] | null => (v === undefined || v === null ? [] : Array.isArray(v) ? v : null);

/** The column a group or a measure makes, as the database names it. */
export function groupColumn(g: string): string {
  const [field, bucket] = g.split(":");
  return bucket ? `${field}_${bucket}` : field;
}

export function measureColumn(m: { field: string; agg: string }): string {
  return m.field === "*" ? "count" : `${m.agg}_${m.field}`;
}

/** Checks [raw] against [cat]; the plan tidied, or why it can't be run. */
export function checkPlan(raw: unknown, cat: Catalogue): PlanCheck {
  const no = (reason: string): PlanCheck => ({ ok: false, reason });
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return no("The answer was not a report plan.");
  const p = raw as Record<string, unknown>;
  const ds = cat.datasets.find((d) => d.id === p.dataset);
  if (!ds) {
    return no(`There is no dataset "${String(p.dataset ?? "")}". Use one of: ${cat.datasets.map((d) => d.id).join(", ")}.`);
  }
  const fields = new Map(ds.fields.map((f) => [f.id, f]));
  const unknown = (id: unknown) => `${ds.label} has no field "${String(id ?? "")}".`;
  const L = cat.limits;

  const columns = list(p.columns), groups = list(p.group_by), measures = list(p.measures);
  const filters = list(p.filters), sort = list(p.sort);
  if (!columns || !groups || !measures || !filters || !sort) {
    return no("columns, group_by, measures, filters and sort must be lists.");
  }
  if (groups.length > L.max_group_by) return no(`Group by at most ${L.max_group_by} fields.`);
  if (measures.length > L.max_measures) return no(`At most ${L.max_measures} figures.`);
  if (columns.length > L.max_columns) return no(`At most ${L.max_columns} columns.`);
  if (filters.length > L.max_filters) return no(`At most ${L.max_filters} filters.`);
  if (sort.length > L.max_sort) return no(`Sort by at most ${L.max_sort} columns.`);

  const out: string[] = [];
  const outFields = new Map<string, string>();
  const plan: Plan = {
    dataset: ds.id,
    columns: [],
    filters: [],
    period: null,
    group_by: [],
    measures: [],
    sort: [],
    limit: null,
    title: "",
  };

  for (const g of groups) {
    if (typeof g !== "string") return no("Each group by is a field name.");
    const [id, bucketRaw] = g.split(":");
    const f = fields.get(id);
    if (!f) return no(unknown(id));
    let bucket = bucketRaw;
    if (f.type === "time") {
      bucket = bucket ?? "day";
      if (!cat.buckets.includes(bucket)) return no(`Group "${f.label}" by day, week, month or year.`);
    } else if (bucket) {
      return no("Only dates can be grouped by day, week, month or year.");
    }
    const tidy = bucket ? `${id}:${bucket}` : id;
    const col = groupColumn(tidy);
    if (out.includes(col)) return no(`"${f.label}" is grouped twice.`);
    out.push(col);
    outFields.set(id, outFields.get(id) ?? col);
    plan.group_by.push(tidy);
  }

  for (const m of measures) {
    if (!m || typeof m !== "object") return no("Each figure is { field, agg }.");
    const field = String((m as Record<string, unknown>).field ?? "*");
    const agg = String((m as Record<string, unknown>).agg ?? "count");
    if (!cat.aggs.includes(agg)) return no(`"${agg}" is not a way to sum up (${cat.aggs.join(", ")}).`);
    if (field === "*") {
      if (agg !== "count") return no(`${agg} needs a field.`);
    } else {
      const f = fields.get(field);
      if (!f) return no(unknown(field));
      if ((agg === "sum" || agg === "avg") && f.type !== "number") {
        return no(`"${f.label}" is not a number, so it can't be added up or averaged.`);
      }
      if ((agg === "min" || agg === "max") && f.type !== "number" && f.type !== "time") {
        return no(`Lowest and highest need a number or a date ("${f.label}" is neither).`);
      }
    }
    const col = measureColumn({ field, agg });
    if (out.includes(col)) return no(`"${col}" is asked for twice.`);
    out.push(col);
    if (field !== "*" && !outFields.has(field)) outFields.set(field, col);
    plan.measures.push({ field, agg });
  }

  if (plan.group_by.length === 0 && plan.measures.length === 0) {
    for (const c of columns) {
      const f = fields.get(String(c));
      if (!f) return no(unknown(c));
      if (!out.includes(f.id)) {
        out.push(f.id);
        outFields.set(f.id, f.id);
        plan.columns.push(f.id);
      }
    }
    if (plan.columns.length === 0) {
      for (const c of ds.list ?? []) {
        if (fields.has(c) && !out.includes(c)) {
          out.push(c);
          outFields.set(c, c);
        }
      }
    }
  }
  if (out.length === 0) return no("The report has no columns.");

  for (const raw of filters) {
    if (!raw || typeof raw !== "object") return no("Each filter is { field, op, value }.");
    const r = raw as Record<string, unknown>;
    const f = fields.get(String(r.field ?? ""));
    if (!f) return no(unknown(r.field));
    const op = String(r.op ?? "eq");
    if (!(cat.ops[f.type] ?? []).includes(op)) return no(`"${op}" can't be used on "${f.label}".`);
    const v = r.value;
    if (op !== "is_null" && op !== "not_null") {
      if (f.type === "text") {
        if (op === "in" || op === "not_in") {
          if (!Array.isArray(v) || v.length === 0 || v.length > L.max_in) {
            return no(`"${f.label}" needs a list of 1 to ${L.max_in} values.`);
          }
        } else if (!["string", "number", "boolean"].includes(typeof v)) {
          return no(`"${f.label}" needs a value.`);
        }
      } else if (f.type === "number") {
        if (op === "between" || op === "in") {
          if (!Array.isArray(v) || v.length === 0 || v.length > L.max_in || (op === "between" && v.length !== 2) ||
            !v.every(isNumber)) {
            return no(`"${f.label}" needs ${op === "between" ? "two numbers" : "a list of numbers"} for "${op}".`);
          }
        } else if (!isNumber(v)) {
          return no(`"${f.label}" needs a number for "${op}".`);
        }
      } else if (f.type === "time") {
        if (op === "between") {
          if (!Array.isArray(v) || v.length !== 2 || !v.every(isDate)) return no(`"${f.label}" needs two dates (yyyy-mm-dd).`);
        } else if (!isDate(v)) {
          return no(`"${f.label}" needs a date (yyyy-mm-dd).`);
        }
      } else if (!(v === true || v === false || v === "true" || v === "false")) {
        return no(`"${f.label}" needs yes (true) or no (false).`);
      }
    }
    plan.filters.push(op === "is_null" || op === "not_null" ? { field: f.id, op } : { field: f.id, op, value: v });
  }

  if (p.period !== undefined && p.period !== null) {
    if (typeof p.period !== "object" || Array.isArray(p.period)) return no("The period is {from, to} or {preset}.");
    const per = p.period as Record<string, unknown>;
    const field = typeof per.field === "string" && per.field ? per.field : ds.time;
    if (fields.get(field)?.type !== "time") return no(`${ds.label} has no date "${field}".`);
    if (typeof per.preset === "string" && per.preset) {
      if (!cat.presets.includes(per.preset)) return no(`Unknown period "${per.preset}".`);
      const period: PlanPeriod = { preset: per.preset, field };
      if (per.preset === "last_n_days") {
        const n = Number(per.days);
        if (!Number.isInteger(n) || n < 1 || n > 366) return no('"Last N days" needs N from 1 to 366.');
        period.days = n;
      }
      plan.period = period;
    } else if (per.from !== undefined || per.to !== undefined) {
      if (!isDate(per.from) || !isDate(per.to)) return no("The period's dates must be written yyyy-mm-dd.");
      if (per.to < per.from) return no("The period ends before it starts.");
      plan.period = { from: per.from, to: per.to, field };
    }
  }

  for (const raw of sort) {
    if (!raw || typeof raw !== "object") return no("Each sort is { field, dir }.");
    const r = raw as Record<string, unknown>;
    const dir = String(r.dir ?? "asc").toLowerCase();
    if (dir !== "asc" && dir !== "desc") return no("Sort is asc or desc.");
    const id = String(r.field ?? "");
    const col = out.includes(id) ? id : outFields.get(id);
    if (!col) return no(`Can't sort by "${id}": it isn't a column of the report.`);
    plan.sort.push({ field: col, dir });
  }

  if (p.limit !== undefined && p.limit !== null && p.limit !== "") {
    const n = Number(p.limit);
    if (!Number.isInteger(n) || n < 1) return no("limit must be a whole number, at least 1.");
    plan.limit = n >= L.max_rows ? null : n;
  }
  plan.title = typeof p.title === "string" ? p.title.trim().slice(0, 120) : "";
  return { ok: true, plan };
}

// ---- Asking ----------------------------------------------------------------------------------

/** What the AI is told about the data: names, types and allowed words only. */
export function catalogueForPrompt(cat: Catalogue): unknown {
  return {
    datasets: cat.datasets.map((d) => ({
      id: d.id,
      label: d.label,
      about: d.about,
      default_date: d.time,
      fields: d.fields.map((f) => ({ id: f.id, label: f.label, type: f.type, ...(f.values ? { values: f.values } : {}) })),
    })),
    aggs: cat.aggs,
    ops: cat.ops,
    date_groups: cat.buckets,
    presets: cat.presets,
    limits: cat.limits,
  };
}

export const REPORT_SYSTEM = `You turn an admin's request for a report into a JSON report plan for GET.ride, a ride-hailing app in Malaysia.
Answer with ONE JSON object and nothing else. Never write SQL. You are never shown any data.
The plan:
{
  "dataset": one dataset id from the catalogue,
  "title": a short title in plain words,
  "filters": [{"field": a field id, "op": one of the ops for the field's type, "value": ...}],
  "period": {"preset": a preset} or {"preset": "last_n_days", "days": N} or {"from": "yyyy-mm-dd", "to": "yyyy-mm-dd"} or null for all time; add "field" to use another date than the dataset's default_date,
  "group_by": [field ids; a date field may be "field:day", "field:week", "field:month" or "field:year"],
  "measures": [{"field": a field id or "*", "agg": one of the aggs}],
  "columns": [field ids, only for a plain list with no group_by and no measures],
  "sort": [{"field": a field id, or a measure as "<agg>_<field>", or "count", "dir": "asc" or "desc"}],
  "limit": a whole number, or null
}
Rules:
- Use only the dataset ids, field ids, ops, aggs, date groups and presets in the catalogue. If a field the request needs is not there, leave it out and use what is there.
- "value" for "in" / "not_in" is a list; for "between" a list of two; dates are "yyyy-mm-dd" in Malaysia time.
- Count rows with {"field": "*", "agg": "count"}. Sum or average only number fields.
- "Top N" or "highest first" is a sort desc with limit N. "Per day / week / month" is a date group.
- Periods: "last 7 days" is last_7_days, "this month" is this_month, "last month" is last_month, "2026" is from 2026-01-01 to 2026-12-31.
- Fields with "values" take those exact words.`;

/** The request as the AI gets it: the catalogue, today and the words. */
export function reportPrompt(request: string, cat: Catalogue, today: string, rejected?: string): string {
  return [
    `Today in Malaysia is ${today}.`,
    `Catalogue:\n${JSON.stringify(catalogueForPrompt(cat))}`,
    `The admin asks:\n${request.trim().slice(0, 1000)}`,
    ...(rejected ? [`Your last plan was refused: ${rejected} Answer again with a plan that fits the catalogue.`] : []),
  ].join("\n\n");
}

/** Today's date in Malaysia (UTC+8, no summer time). */
export function malaysiaToday(now: Date): string {
  return new Date(now.getTime() + 8 * 3600_000).toISOString().slice(0, 10);
}

// ---- In plain words --------------------------------------------------------------------------

const OP_WORDS: Record<string, string> = {
  eq: "is",
  neq: "is not",
  in: "is one of",
  not_in: "is none of",
  contains: "contains",
  gt: "is more than",
  gte: "is at least",
  lt: "is less than",
  lte: "is at most",
  between: "is between",
  is_null: "is empty",
  not_null: "is filled in",
};

const PRESET_WORDS: Record<string, string> = {
  today: "Today",
  yesterday: "Yesterday",
  last_7_days: "The last 7 days",
  last_30_days: "The last 30 days",
  this_week: "This week",
  last_week: "Last week",
  this_month: "This month",
  last_month: "Last month",
  month_to_date: "This month so far",
  this_year: "This year",
  last_year: "Last year",
  previous_day: "The day before",
  previous_week: "The week before",
  previous_month: "The month before",
};

const AGG_WORDS: Record<string, string> = {
  count: "count of",
  count_distinct: "different",
  sum: "total",
  avg: "average",
  min: "lowest",
  max: "highest",
};

function shortDate(iso: string): string {
  const [y, m, d] = iso.split("-").map(Number);
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  return `${d} ${months[m - 1] ?? ""} ${y}`;
}

const lowerFirst = (s: string) => s.charAt(0).toLowerCase() + s.slice(1);

export function periodWords(p: PlanPeriod | null | undefined): string {
  if (!p) return "All time";
  if (p.preset === "last_n_days") return `The last ${p.days} whole days`;
  if (p.preset) return PRESET_WORDS[p.preset] ?? p.preset;
  if (p.from && p.to) return p.from === p.to ? shortDate(p.from) : `${shortDate(p.from)} to ${shortDate(p.to)}`;
  return "All time";
}

/** The plan as label / words lines, for the email and the Excel file's second sheet. */
export function describePlan(
  plan: Plan,
  cat: Catalogue,
  opts: { resolved?: { from: string; to: string } | null; columns?: { id: string; label: string }[] } = {},
): [string, string][] {
  const resolved = opts.resolved;
  const ds = cat.datasets.find((d) => d.id === plan.dataset);
  const label = (id: string) => {
    if (id === "*") return "rows";
    const [f, bucket] = id.split(":");
    const l = ds?.fields.find((x) => x.id === f)?.label ?? f;
    return bucket ? `${l} (${bucket})` : l;
  };
  const value = (v: unknown) => Array.isArray(v) ? v.map(String).join(", ") : String(v);
  const lines: [string, string][] = [["Data", ds?.label ?? plan.dataset]];
  const period = periodWords(plan.period);
  lines.push([
    "Period",
    `${period}${resolved && plan.period?.preset ? ` (${periodWords({ from: resolved.from, to: resolved.to })})` : ""}${
      plan.period ? `, by ${label(plan.period.field ?? ds?.time ?? "")}` : ""
    }, Malaysia time`,
  ]);
  if (plan.filters.length) {
    lines.push(["Only", plan.filters.map((f) => `${label(f.field)} ${OP_WORDS[f.op] ?? f.op}${f.value === undefined ? "" : ` ${value(f.value)}`}`).join("; ")]);
  }
  if (plan.group_by.length) lines.push(["Group by", plan.group_by.map(label).join(", ")]);
  if (plan.measures.length) {
    lines.push([
      "Figures",
      plan.measures.map((m) => m.field === "*" ? "Count" : `${AGG_WORDS[m.agg] ?? m.agg} ${lowerFirst(label(m.field))}`)
        .map((s) => s[0].toUpperCase() + s.slice(1)).join(", "),
    ]);
  } else if (plan.columns.length) {
    lines.push(["Columns", plan.columns.map(label).join(", ")]);
  }
  if (plan.sort.length) {
    lines.push(["Sort", plan.sort.map((s) => `${opts.columns?.find((c) => c.id === s.field)?.label ?? s.field}, ${s.dir === "desc" ? "highest first" : "lowest first"}`).join("; ")]);
  }
  if (plan.limit) lines.push(["Rows", `The first ${plan.limit}`]);
  if (ds?.hidden?.length) lines.push(["Hidden", `Not in this report: ${ds.hidden.join(", ")}`]);
  return lines;
}
