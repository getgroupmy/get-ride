/**
 * pin-login's rules, with the database and Auth stood in.
 *
 *     deno test supabase/functions/_shared/pin_login_test.ts
 */
import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1.0.19";

import {
  clientIp,
  handlePinLogin,
  parsePinLoginRequest,
  type PinLoginDeps,
  type PinLoginSession,
  randomPassword,
  refusalOf,
} from "./pin_login.ts";

const UID = "00000000-0000-0000-0000-000000000001";
const SESSION: PinLoginSession = { access_token: "at", refresh_token: "rt", expires_in: 3600 };

/** One account (+60123456789, PIN 246810) and Auth's password for it. */
function fakes(over: Partial<PinLoginDeps> = {}) {
  const log: string[] = [];
  let authPassword = "teksi-pin-v1-246810";
  let n = 0;
  const deps: PinLoginDeps = {
    check: (phone, pin, ip) => {
      log.push(`check ${phone} ${ip}`);
      return Promise.resolve(phone === "+60123456789" && pin === "246810" ? UID : null);
    },
    authPhone: (id) => Promise.resolve(id === UID ? "60123456789" : null),
    setPassword: (_id, pw) => {
      log.push("set");
      authPassword = pw;
      return Promise.resolve();
    },
    signIn: (_phone, pw) => {
      log.push("sign-in");
      return Promise.resolve(pw === authPassword ? SESSION : null);
    },
    randomPassword: () => `random-${++n}`,
    ...over,
  };
  return { deps, log, password: () => authPassword };
}

Deno.test("the right PIN: a fresh password, a session, and no PIN-derived password left", async () => {
  const f = fakes();
  const r = await handlePinLogin({ phone: "+60123456789", pin: "246810" }, "198.51.100.7", f.deps);
  assertEquals(r.status, 200);
  assertEquals(r.body, { session: SESSION });
  assertEquals(f.log, ["check +60123456789 198.51.100.7", "set", "sign-in"]);
  assertEquals(f.password(), "random-1");
});

Deno.test("a wrong PIN or an unknown number: the same answer, nothing changed", async () => {
  for (const body of [{ phone: "+60123456789", pin: "111111" }, { phone: "+60199999999", pin: "246810" }]) {
    const f = fakes();
    const r = await handlePinLogin(body, "198.51.100.7", f.deps);
    assertEquals(r, { status: 401, body: { error: "wrong_pin" } });
    assertEquals(f.password(), "teksi-pin-v1-246810");
  }
});

Deno.test("a wrong PIN says how many tries are left, for an account with a PIN", async () => {
  const { deps } = fakes({
    attemptsLeft: (phone) => Promise.resolve(phone === "+60123456789" ? 2 : null),
  });
  assertEquals(await handlePinLogin({ phone: "+60123456789", pin: "111111" }, "1.2.3.4", deps), {
    status: 401,
    body: { error: "wrong_pin", attempts_left: 2 },
  });
  assertEquals(await handlePinLogin({ phone: "+60199999999", pin: "111111" }, "1.2.3.4", deps), {
    status: 401,
    body: { error: "wrong_pin" },
  });
  const failing = fakes({ attemptsLeft: () => Promise.reject(new Error("down")) });
  assertEquals((await handlePinLogin({ phone: "+60123456789", pin: "111111" }, "1.2.3.4", failing.deps)).body, {
    error: "wrong_pin",
  });
});

Deno.test("the database's lockout and rate limit pass through with their wait", async () => {
  const locked = fakes({ check: () => Promise.reject(new Error("PIN_LOCKED:840")) });
  assertEquals(await handlePinLogin({ phone: "+60123456789", pin: "246810" }, "x", locked.deps), {
    status: 423,
    body: { error: "locked", retry_after: 840 },
  });
  const limited = fakes({ check: () => Promise.reject(new Error("RATE_LIMITED:30")) });
  assertEquals(await handlePinLogin({ phone: "+60123456789", pin: "246810" }, "x", limited.deps), {
    status: 429,
    body: { error: "rate_limited", retry_after: 30 },
  });
  const down = fakes({ check: () => Promise.reject(new Error("connection refused")) });
  assertEquals((await handlePinLogin({ phone: "+60123456789", pin: "246810" }, "x", down.deps)).status, 503);
});

Deno.test("no Auth login behind the profile: sign in by SMS instead", async () => {
  const f = fakes({ authPhone: () => Promise.resolve(null) });
  assertEquals(await handlePinLogin({ phone: "+60123456789", pin: "246810" }, "x", f.deps), {
    status: 409,
    body: { error: "needs_otp" },
  });
  assertEquals(f.log.includes("set"), false);
});

Deno.test("a sign-in that lost a race for the password is tried once more", async () => {
  let first = true;
  const f = fakes();
  const signIn = f.deps.signIn;
  f.deps.signIn = (phone, pw) => {
    if (first) {
      first = false;
      return Promise.resolve(null); // another sign-in replaced it meanwhile
    }
    return signIn(phone, pw);
  };
  const r = await handlePinLogin({ phone: "+60123456789", pin: "246810" }, "x", f.deps);
  assertEquals(r.status, 200);
  assertEquals(f.log.filter((l) => l === "set").length, 2);
});

Deno.test("requests: a phone and exactly six digits", () => {
  assertEquals(parsePinLoginRequest({ phone: " +60123456789 ", pin: "246810" }), {
    phone: "+60123456789",
    pin: "246810",
  });
  for (
    const bad of [null, "x", {}, { phone: "+60123456789", pin: "24681" }, { phone: "+60123456789", pin: "abcdef" }, {
      phone: "12",
      pin: "246810",
    }, { phone: 60123456789, pin: "246810" }]
  ) {
    assertEquals(parsePinLoginRequest(bad), null);
  }
});

Deno.test("the caller's address: Cloudflare's, then the proxies', never empty", () => {
  assertEquals(
    clientIp(new Headers({ "cf-connecting-ip": "203.0.113.5", "x-forwarded-for": "1.1.1.1" })),
    "203.0.113.5",
  );
  assertEquals(clientIp(new Headers({ "x-forwarded-for": "198.51.100.2, 10.0.0.1" })), "198.51.100.2");
  assertEquals(clientIp(new Headers()), "unknown");
});

Deno.test("refusals and passwords", () => {
  assertEquals(refusalOf("PIN_LOCKED:12"), { error: "locked", retry_after: 12 });
  assertEquals(refusalOf("RATE_LIMITED:5"), { error: "rate_limited", retry_after: 5 });
  assertEquals(refusalOf("other"), null);
  const a = randomPassword(), b = randomPassword();
  assert(a.length >= 40);
  assertNotEquals(a, b);
  assert(!/teksi-pin/.test(a));
});
