/**
 * Test traffic (migration 0241): the cached tester check.
 *
 *     deno test supabase/functions/_shared/test_traffic_test.ts
 */
import { assertEquals } from "jsr:@std/assert@1.0.19";

import { rpcTestAccountLookup, testAccountCheck } from "./test_traffic.ts";

Deno.test("a listed tester is test traffic; anyone else is real", async () => {
  const isTest = testAccountCheck(async (uid) => uid === "tester");
  assertEquals(await isTest("tester"), true);
  assertEquals(await isTest("rider"), false);
});

Deno.test("nobody signed in is real traffic, without a lookup", async () => {
  let asked = 0;
  const isTest = testAccountCheck(async () => {
    asked++;
    return true;
  });
  assertEquals(await isTest(null), false);
  assertEquals(await isTest(undefined), false);
  assertEquals(await isTest(""), false);
  assertEquals(asked, 0);
});

Deno.test("an answer is kept for the ttl, then asked again", async () => {
  let t = 0;
  let asked = 0;
  const isTest = testAccountCheck(async () => {
    asked++;
    return true;
  }, { ttlMs: 1000, now: () => t });
  await isTest("tester");
  t = 999;
  await isTest("tester");
  assertEquals(asked, 1);
  t = 1000;
  await isTest("tester");
  assertEquals(asked, 2);
});

Deno.test("a failed lookup is real traffic and is not remembered", async () => {
  let fail = true;
  let asked = 0;
  const isTest = testAccountCheck(async () => {
    asked++;
    if (fail) throw new Error("function is_test_account does not exist");
    return true;
  });
  assertEquals(await isTest("tester"), false);
  fail = false;
  assertEquals(await isTest("tester"), true);
  assertEquals(asked, 2);
});

Deno.test("the rpc lookup asks is_test_account with the id and reads a strict true", async () => {
  const calls: unknown[] = [];
  const lookup = rpcTestAccountLookup(async (fn, args) => {
    calls.push([fn, args]);
    return { data: args.p_uid === "tester" ? true : "true", error: null };
  });
  assertEquals(await lookup("tester"), true);
  assertEquals(await lookup("rider"), false);
  assertEquals(calls, [["is_test_account", { p_uid: "tester" }], ["is_test_account", { p_uid: "rider" }]]);
  const failing = rpcTestAccountLookup(async () => ({ data: null, error: { message: "denied" } }));
  const isTest = testAccountCheck(failing);
  assertEquals(await isTest("tester"), false);
});
