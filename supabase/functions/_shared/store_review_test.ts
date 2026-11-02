/**
 * pin-login's review action (0333), with the database and Auth stood in.
 *
 *     deno test supabase/functions/_shared/store_review_test.ts
 */
import { assertEquals } from "jsr:@std/assert@1.0.19";

import type { PinLoginSession } from "./pin_login.ts";
import {
  handleStoreReviewLogin,
  isStoreReviewBody,
  parseStoreReviewRequest,
  type StoreReviewCheck,
  type StoreReviewDeps,
} from "./store_review.ts";

const DEMO = "a0000333-5707-4e00-8000-000000000333";
const SESSION: PinLoginSession = { access_token: "at", refresh_token: "rt", expires_in: 3600 };

/** The switch [on] with the number 60608080; Auth knows only the demo account. */
function fakes(on = true, over: Partial<StoreReviewDeps> = {}) {
  const log: string[] = [];
  let authPassword = "";
  const deps: StoreReviewDeps = {
    check: (req, ip, agent) => {
      log.push(`check ${req.phone} ${ip} ${req.platform} ${req.device} ${req.appVersion} ${agent}`);
      const right = req.phone === "+60608080";
      const r: StoreReviewCheck = !on
        ? { ok: false, outcome: "off" }
        : right
        ? { ok: true, outcome: "allowed", user_id: DEMO }
        : { ok: false, outcome: "wrong_number" };
      return Promise.resolve(r);
    },
    authPhone: (id) => Promise.resolve(id === DEMO ? "99960608080" : null),
    setPassword: (_id, pw) => {
      log.push("set");
      authPassword = pw;
      return Promise.resolve();
    },
    signIn: (phone, pw) => {
      log.push(`sign-in ${phone}`);
      return Promise.resolve(pw === authPassword ? SESSION : null);
    },
    accountPassword: (id) => Promise.resolve(`server-${id}`),
    ...over,
  };
  return { deps, log };
}

const BODY = { action: "review", phone: "+60608080", platform: "android", device: "Pixel 8", app_version: "1.9.0" };

Deno.test("parses only a review action with a number", () => {
  assertEquals(parseStoreReviewRequest(BODY), {
    phone: "+60608080",
    platform: "android",
    device: "Pixel 8",
    appVersion: "1.9.0",
  });
  assertEquals(parseStoreReviewRequest({ phone: "+60608080" }), null);
  assertEquals(parseStoreReviewRequest({ action: "review", phone: "123" }), null);
  assertEquals(parseStoreReviewRequest({ action: "review" }), null);
  assertEquals(isStoreReviewBody(BODY), true);
  assertEquals(isStoreReviewBody({ phone: "+60123456789", pin: "123456" }), false);
});

Deno.test("on, the number signs in to the demo account, setting its password once", async () => {
  const f = fakes();
  const r = await handleStoreReviewLogin(BODY, "198.51.100.7", "okhttp", f.deps);
  assertEquals(r, { status: 200, body: { session: SESSION } });
  assertEquals(f.log, [
    "check +60608080 198.51.100.7 android Pixel 8 1.9.0 okhttp",
    "sign-in 99960608080",
    "set",
    "sign-in 99960608080",
  ]);
  f.log.length = 0;
  const again = await handleStoreReviewLogin(BODY, "198.51.100.8", null, f.deps);
  assertEquals(again.status, 200);
  // The password stays, so the other test phones stay signed in.
  assertEquals(f.log.includes("set"), false);
});

Deno.test("off, or another number: refused alike, nothing signed in", async () => {
  for (const [on, body] of [[false, BODY], [true, { ...BODY, phone: "+60608081" }]] as const) {
    const f = fakes(on);
    const r = await handleStoreReviewLogin(body, "x", null, f.deps);
    assertEquals(r, { status: 403, body: { error: "review_off" } });
    assertEquals(f.log.some((l) => l.startsWith("sign-in")), false);
  }
});

Deno.test("rate limited and an unreachable database say so", async () => {
  const limited = fakes(true, {
    check: () => Promise.resolve({ ok: false, outcome: "rate_limited", retry_after: 120 }),
  });
  assertEquals(await handleStoreReviewLogin(BODY, "x", null, limited.deps), {
    status: 429,
    body: { error: "rate_limited", retry_after: 120 },
  });
  const down = fakes(true, { check: () => Promise.reject(new Error("down")) });
  assertEquals((await handleStoreReviewLogin(BODY, "x", null, down.deps)).status, 503);
  assertEquals((await handleStoreReviewLogin({ action: "review" }, "x", null, down.deps)).status, 400);
});

Deno.test("an allowed answer without an account id signs nobody in", async () => {
  const f = fakes(true, { check: () => Promise.resolve({ ok: true, outcome: "allowed", user_id: null }) });
  assertEquals((await handleStoreReviewLogin(BODY, "x", null, f.deps)).status, 403);
});
