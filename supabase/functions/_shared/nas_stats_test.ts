import { assertEquals } from "jsr:@std/assert@1.0.19";

import { dayRange, parseUmamiKey, readStats, sourceName, statValue, summarize, umamiKey } from "./nas_stats.ts";

const SITE = "3f2504e0-4f89-11d3-9a0c-0305e82c3301";
const providers = (value: string, disabled = false) => [
  { id: "umami", services: [{ id: "api", keys: [{ value, disabled }] }] },
];

Deno.test("the key: address, then a name and password or a token", () => {
  assertEquals(parseUmamiKey("https://stats.getride.my getride:pa:ss word"), {
    url: "https://stats.getride.my",
    username: "getride",
    password: "pa:ss word",
  });
  assertEquals(parseUmamiKey(" https://stats.getride.my/  abcdefghijklmnopqrstuvwxyz "), {
    url: "https://stats.getride.my",
    token: "abcdefghijklmnopqrstuvwxyz",
  });
  assertEquals(parseUmamiKey("http://stats.getride.my a:b"), null, "https only");
  assertEquals(parseUmamiKey("https://stats.getride.my short"), null, "a token is long");
  assertEquals(parseUmamiKey("https://stats.getride.my"), null);
  assertEquals(umamiKey(providers("https://stats.getride.my a:b"))?.username, "a");
  assertEquals(umamiKey(providers("https://stats.getride.my a:b", true)), null, "a switched-off key");
  assertEquals(umamiKey({ providers: providers("https://s.example a:b") })?.url, "https://s.example");
  assertEquals(umamiKey(null), null);
});

Deno.test("today starts at midnight in Malaysia", () => {
  const now = new Date("2026-10-28T03:00:00Z"); // 11:00 in Kuala Lumpur
  const r = dayRange(now);
  assertEquals(new Date(r.startAt).toISOString(), "2026-10-27T16:00:00.000Z");
  assertEquals(r.endAt, now.getTime());
  const late = dayRange(new Date("2026-10-28T17:30:00Z")); // 01:30 the next day there
  assertEquals(new Date(late.startAt).toISOString(), "2026-10-28T16:00:00.000Z");
  assertEquals(new Date(dayRange(now, "UTC").startAt).toISOString(), "2026-10-28T00:00:00.000Z");
});

Deno.test("numbers from either Umami version; sources in plain words", () => {
  assertEquals(statValue({ value: 1284, prev: 900 }), 1284);
  assertEquals(statValue(312), 312);
  assertEquals(statValue("x"), 0);
  assertEquals(sourceName("wa.me"), "WhatsApp");
  assertEquals(sourceName("https://l.facebook.com/x"), "Facebook");
  assertEquals(sourceName("www.google.com.my"), "Google");
  assertEquals(sourceName(""), "Direct");
  assertEquals(sourceName("news.example.com"), "news.example.com");
  assertEquals(
    summarize(
      { visitors: { value: 1284 }, pageviews: 2001, visits: { value: 1400 } },
      [{ x: "/install/android", y: 200 }, { x: "/", y: 600 }, { x: "/install/ios", y: 112 }, { x: "/installer", y: 9 }],
      [{ x: "", y: 300 }, { x: "wa.me", y: 250 }, { x: "api.whatsapp.com", y: 100 }],
    ),
    { visitors: 1284, pageviews: 2001, visits: 1400, installViews: 312, topPage: "/", topSource: "WhatsApp" },
  );
  assertEquals(summarize(null, null, null).topPage, null);
});

function deps(opts: {
  stats?: unknown;
  key?: string;
  answer?: (url: string, init: RequestInit) => Response | Promise<Response>;
}) {
  const seen: string[] = [];
  const beats: string[] = [];
  return {
    seen,
    beats,
    deps: {
      settings: () =>
        Promise.resolve({
          stats: opts.stats ?? { on: true, websiteId: SITE },
          apiProviders: providers(opts.key ?? "https://stats.getride.my getride:secret"),
        }),
      fetch: (url: string, init: RequestInit) => {
        seen.push(`${init.method ?? "GET"} ${url.replace(/startAt=\d+&endAt=\d+/, "Q")}`);
        return Promise.resolve(opts.answer ? opts.answer(url, init) : new Response("{}"));
      },
      now: () => new Date("2026-10-28T03:00:00Z"),
      beat: (status: string) => {
        beats.push(status);
        return Promise.resolve();
      },
    },
  };
}

const json = (v: unknown, status = 200) => new Response(JSON.stringify(v), { status });

Deno.test("reads today's numbers with a login", async () => {
  const f = deps({
    answer: (url) => {
      if (url.endsWith("/api/auth/login")) return json({ token: "t1" });
      if (url.includes("/stats?")) return json({ visitors: { value: 10 }, pageviews: { value: 30 }, visits: { value: 12 } });
      if (url.includes("type=url")) return json({ error: "bad type" }, 400);
      if (url.includes("type=path")) return json([{ x: "/install/android", y: 4 }, { x: "/", y: 20 }]);
      return json([{ x: "wa.me", y: 5 }]);
    },
  });
  const r = await readStats(f.deps);
  assertEquals(r.state, "on");
  assertEquals(r.today, { visitors: 10, pageviews: 30, visits: 12, installViews: 4, topPage: "/", topSource: "WhatsApp" });
  assertEquals(f.seen[0], "POST https://stats.getride.my/api/auth/login");
  assertEquals(f.seen.includes(`GET https://stats.getride.my/api/websites/${SITE}/metrics?Q&type=path`), true,
    "Umami 3's name for the pages metric");
  assertEquals(f.beats, ["ok"]);
});

Deno.test("NAS off, a refused login, nothing set, paused", async () => {
  const off = deps({ answer: () => Promise.reject(new TypeError("connection refused")) });
  const r = await readStats(off.deps);
  assertEquals([r.state, off.beats], ["nas_off", ["off"]]);

  const tunnel = deps({ answer: () => new Response("Cloudflare: tunnel down", { status: 530 }) });
  assertEquals((await readStats(tunnel.deps)).state, "nas_off");

  const refused = deps({ answer: () => json({ error: "bad" }, 401) });
  assertEquals((await readStats(refused.deps)).state, "refused");

  const token = deps({ key: "https://stats.getride.my abcdefghijklmnopqrstuvwxyz", answer: () => json({}) });
  assertEquals((await readStats(token.deps)).state, "on");
  assertEquals(token.seen.some((s) => s.includes("/auth/login")), false, "a token needs no login");

  const noSite = deps({ stats: { on: true, websiteId: null } });
  assertEquals(await readStats(noSite.deps), { state: "not_set", reason: "website", at: "2026-10-28T03:00:00.000Z" });
  const noKey = deps({ key: "nope" });
  assertEquals((await readStats(noKey.deps)).reason, "key");
  const paused = deps({ stats: { on: false, websiteId: SITE } });
  assertEquals((await readStats(paused.deps)).state, "paused");
  assertEquals(paused.seen.length + noKey.seen.length + noSite.seen.length, 0, "nothing asked of the NAS");
});
