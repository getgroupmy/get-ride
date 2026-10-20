import { assertEquals } from "jsr:@std/assert@1.0.19";
import { type DispatchAccountDeps, e164, handleDispatchAccount, parseRequest } from "./dispatch_account.ts";

const STAND = "00000000-0000-0000-0000-0000000251e1";
const GROUP = "00000000-0000-0000-0000-0000000251f3";

function deps(over: Partial<DispatchAccountDeps> = {}) {
  const calls: string[] = [];
  const d: DispatchAccountDeps = {
    caller: (a) => Promise.resolve(a === "Bearer good" ? "admin-1" : null),
    mayGrant: () => Promise.resolve(true),
    userByPhone: (p) => Promise.resolve(p === "+60123456789" ? "user-1" : null),
    createUser: (p) => {
      calls.push(`create ${p}`);
      return Promise.resolve("user-new");
    },
    grant: (c, u, r) => {
      calls.push(`grant ${c} ${u} ${r.kind}`);
      return Promise.resolve({});
    },
    ...over,
  };
  return { d, calls };
}

Deno.test("phone numbers are digits with a plus, 8 to 15 long", () => {
  assertEquals(e164("+60 12-345 6789"), "+60123456789");
  assertEquals(e164("1234"), null);
  assertEquals(e164(42), null);
});

Deno.test("a request needs its kind, a name, a phone and where", () => {
  assertEquals(parseRequest({ kind: "staff", name: "Aina", phone: "+60123456789", stand_ids: [] }), null);
  assertEquals(parseRequest({ kind: "fleet_owner", name: "Sun", phone: "+60123456789" }), null);
  assertEquals(parseRequest({ kind: "admin", name: "X", phone: "+60123456789", stand_ids: [STAND] }), null);
  const r = parseRequest({
    kind: "staff",
    name: " Aina ",
    phone: "012 345 67890",
    stand_ids: [STAND],
    perms: { assign: true, admin: true },
  });
  assertEquals(r?.name, "Aina");
  assertEquals(r?.perms, {
    assign: true,
    broadcast: false,
    fixed_fare: false,
    cancel: false,
    reassign: false,
    reports: false,
  });
});

Deno.test("an existing account is given the role; a new number gets an account first", async () => {
  const { d, calls } = deps();
  const old = await handleDispatchAccount(
    { kind: "stand_admin", name: "Pavilion", phone: "+60 12-345 6789", stand_ids: [STAND] },
    "Bearer good",
    d,
  );
  assertEquals(old, { status: 200, body: { user_id: "user-1", created: false } });
  const fresh = await handleDispatchAccount(
    { kind: "fleet_owner", name: "Sunlight", phone: "+60 19-000 0000", group_id: GROUP },
    "Bearer good",
    d,
  );
  assertEquals(fresh, { status: 200, body: { user_id: "user-new", created: true } });
  assertEquals(calls, [
    "grant admin-1 user-1 stand_admin",
    "create +60190000000",
    "grant admin-1 user-new fleet_owner",
  ]);
});

Deno.test("no token, no right: nothing is made", async () => {
  const { d, calls } = deps({ mayGrant: () => Promise.resolve(false) });
  const body = { kind: "staff", name: "Rizal", phone: "+60 19-000 0000", stand_ids: [STAND] };
  assertEquals((await handleDispatchAccount(body, null, d)).status, 401);
  assertEquals((await handleDispatchAccount(body, "Bearer good", d)).status, 403);
  assertEquals(calls, []);
});

Deno.test("the database's refusals come back by name", async () => {
  const { d } = deps({ grant: () => Promise.reject(new Error("DISPATCH_ALREADY_ADMIN")) });
  const r = await handleDispatchAccount(
    { kind: "staff", name: "Rizal", phone: "+60 12-345 6789", stand_ids: [STAND] },
    "Bearer good",
    d,
  );
  assertEquals(r, { status: 409, body: { error: "DISPATCH_ALREADY_ADMIN" } });
});
