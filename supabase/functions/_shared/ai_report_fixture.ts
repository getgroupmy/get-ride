/**
 * Test fixture: the Reports catalogue exactly as migration 0280 defines it
 * (read from the migration, so the checks here and the database's can't
 * drift), as a full admin's and as a sub-admin's without People pages.
 */
import type { Catalogue } from "./ai_report_plan.ts";

const root = new URL("../../../", import.meta.url);
const sql = Deno.readTextFileSync(new URL("supabase/migrations/0280_ai_reports.sql", root));
const raw = JSON.parse(/\$cat\$([\s\S]*?)\$cat\$/.exec(sql)![1]);

function forScope(people: { users: boolean; partners: boolean }): Catalogue {
  return {
    ...raw,
    datasets: raw.datasets.map((d: Record<string, unknown>) => {
      const fields = (d.fields as { personal?: string; label: string }[]);
      const ok = (f: { personal?: string }) => !f.personal || people[f.personal as "users" | "partners"];
      const { view: _v, area: _a, ...rest } = d;
      return { ...rest, fields: fields.filter(ok), hidden: fields.filter((f) => !ok(f)).map((f) => f.label) };
    }),
  } as Catalogue;
}

export const fullCatalogue = forScope({ users: true, partners: true });
export const subAdminCatalogue = forScope({ users: false, partners: false });
