/**
 * The provider list lives in three places that must agree: the admin form
 * (gatewayProviders in commerce_logic.dart), the database
 * (payment_gateway_secret_fields() in the 0252 migration) and the adapters
 * here. Same ids in the same order, the same secret fields, the same
 * "charging" state.
 *
 *     deno test --allow-read=lib,supabase supabase/functions/_shared/payments/registry_test.ts
 */
import { assert, assertEquals } from "jsr:@std/assert@1.0.19";

import { ADAPTER_LIST } from "./registry.ts";

const root = new URL("../../../../", import.meta.url);
const read = (path: string) => Deno.readTextFileSync(new URL(path, root));

/** id → { secrets, charging } from the Dart catalogue. */
function dartCatalogue(): Map<string, { secrets: string[]; charging: string }> {
  const src = read("lib/src/admin/screens/commerce/commerce_logic.dart");
  const start = src.indexOf("const gatewayProviders = <GatewayProvider>[");
  const body = src.slice(start, src.indexOf("\n];", start));
  const out = new Map<string, { secrets: string[]; charging: string }>();
  const blocks = body.split(/\n {2}GatewayProvider\(/).slice(1);
  for (const b of blocks) {
    const id = /^'([^']+)'/.exec(b)![1];
    const charging = /charging: ChargeSupport\.(\w+)/.exec(b)?.[1] ?? "checked";
    const secrets = [...b.matchAll(/CredentialField\('(\w+)'[^\n]*secret: true/g)].map((m) => m[1]);
    out.set(id, { secrets, charging });
  }
  return out;
}

/** id → secret fields from payment_gateway_secret_fields(). */
function sqlSecretFields(): Map<string, string[]> {
  const src = read("supabase/migrations/0252_payment_gateways.sql");
  const fn = src.slice(src.indexOf("function public.payment_gateway_secret_fields"), src.indexOf("else array[]::text[]"));
  const out = new Map<string, string[]>();
  for (const m of fn.matchAll(/when '([^']+)'\s+then array\[([^\]]*)\]/g)) {
    out.set(m[1], [...m[2].matchAll(/'(\w+)'/g)].map((x) => x[1]));
  }
  return out;
}

Deno.test("the admin form, the database and the adapters list the same providers", () => {
  const dart = dartCatalogue();
  assertEquals([...dart.keys()], ADAPTER_LIST.map((a) => a.id));
  const sql = sqlSecretFields();
  assertEquals([...sql.keys()].sort(), ADAPTER_LIST.map((a) => a.id).sort());
});

Deno.test("…with the same secret fields", () => {
  const dart = dartCatalogue();
  const sql = sqlSecretFields();
  for (const a of ADAPTER_LIST) {
    assertEquals(dart.get(a.id)!.secrets, a.secretFields, `${a.id}: Dart vs adapter`);
    assertEquals(sql.get(a.id), a.secretFields, `${a.id}: SQL vs adapter`);
    for (const f of a.requiredSecrets) assert(a.secretFields.includes(f), `${a.id}: ${f} is not a secret field`);
  }
});

Deno.test("…and the same charging state", () => {
  const dart = dartCatalogue();
  for (const a of ADAPTER_LIST) {
    const expected = !a.ready ? "none" : a.verified ? "checked" : "unchecked";
    assertEquals(dart.get(a.id)!.charging, expected, a.id);
  }
});

Deno.test("an adapter that isn't verified says what wasn't confirmed", () => {
  for (const a of ADAPTER_LIST) {
    if (!a.verified) assert(a.notes.length > 0, a.id);
  }
});

Deno.test("dashboardUrls agree with the Dart catalogue", () => {
  const src = read("lib/src/admin/screens/commerce/commerce_logic.dart");
  for (const a of ADAPTER_LIST) {
    const block = src.slice(src.indexOf(`GatewayProvider('${a.id}'`), src.indexOf("]),", src.indexOf(`GatewayProvider('${a.id}'`)));
    assertEquals(block.includes("dashboardUrls: true"), a.dashboardUrls === true, a.id);
  }
});
