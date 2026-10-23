import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.19";

import { type CallResult, callProvider, jsonObjectIn, serviceOf } from "./ai_providers.ts";
import { type AskDeps, handleAsk, NO_AI } from "./ai_report_ask.ts";
import { subAdminCatalogue } from "./ai_report_fixture.ts";

const AUTH = "Bearer user-token";
const config = {
  provider: "gemini" as const,
  keys: { gemini: [{ id: "k1", label: "One", key: "secret-1", enabled: true }, { id: "k2", label: "Two", key: "secret-2", enabled: true }] },
};

function deps(answers: (string | null)[], over: Partial<AskDeps> = {}) {
  const prompts: string[] = [];
  const audits: Record<string, unknown>[] = [];
  const keys: string[] = [];
  const d: AskDeps = {
    catalogue: () => Promise.resolve(subAdminCatalogue),
    userId: () => Promise.resolve("u1"),
    rateTake: () => Promise.resolve(0),
    aiConfig: () => Promise.resolve(config),
    coolingKeys: () => Promise.resolve(new Set<string>()),
    email: () => Promise.resolve({ keySet: false, from: "GET.ride Reports <reports@getride.my>" }),
    audit: (_u, detail) => {
      audits.push(detail);
      return Promise.resolve();
    },
    call: (_p, prompt, key) => {
      prompts.push(prompt);
      keys.push(key);
      const content = answers.shift() ?? null;
      return Promise.resolve<CallResult>({ content, httpStatus: content ? 200 : 500, error: content ? null : "HTTP 500" });
    },
    now: () => new Date("2026-10-23T02:00:00Z"),
    ...over,
  };
  return { d, prompts, audits, keys };
}

Deno.test("only a Reports admin may ask", async () => {
  assertEquals((await handleAsk("POST", null, { request: "x" }, deps([]).d)).status, 401);
  assertEquals((await handleAsk("POST", AUTH, { request: "rides" }, deps([], { catalogue: () => Promise.resolve(null) }).d)).status, 401);
  const r = await handleAsk("POST", AUTH, { request: "rides" }, deps([], { catalogue: () => Promise.resolve("forbidden") }).d);
  assertEquals(r.status, 403);
});

Deno.test("a plan that fits comes back checked; the AI saw no data and no personal fields", async () => {
  const t = deps([JSON.stringify({ dataset: "rides", group_by: ["service"], measures: [{ field: "*", agg: "count" }], period: { preset: "last_7_days" } })]);
  const r = await handleAsk("POST", AUTH, { request: "Rides per service last week" }, t.d);
  assertEquals(r.status, 200);
  assertEquals((r.body as { plan: { group_by: string[] } }).plan.group_by, ["service"]);
  assert(!t.prompts[0].includes("driver_name"));
  assertStringIncludes(t.prompts[0], "Today in Malaysia is 2026-10-23.");
  assertEquals(t.audits[0].ok, true);
});

Deno.test("a plan with an unknown field is refused, the AI asked once more with the reason", async () => {
  const t = deps([
    "```json\n" + JSON.stringify({ dataset: "rides", columns: ["driver_phone"] }) + "\n```",
    JSON.stringify({ dataset: "rides", columns: ["status"] }),
  ]);
  const r = await handleAsk("POST", AUTH, { request: "Drivers' phones" }, t.d);
  assertEquals((r.body as { plan: { columns: string[] } }).plan.columns, ["status"]);
  assertEquals(t.prompts.length, 2);
  assertStringIncludes(t.prompts[1], 'Your last plan was refused: Rides has no field "driver_phone".');

  const twice = deps([JSON.stringify({ dataset: "people" }), JSON.stringify({ dataset: "people" })]);
  const no = await handleAsk("POST", AUTH, { request: "everyone" }, twice.d);
  assertEquals((no.body as { error: string }).error, "not_understood");
  assertStringIncludes((no.body as { reason: string }).reason, 'no dataset "people"');
});

Deno.test("a failing key falls back to the next; no keys says how to set one up", async () => {
  const t = deps([null, JSON.stringify({ dataset: "sos" })]);
  const r = await handleAsk("POST", AUTH, { request: "SOS incidents" }, t.d);
  assertEquals(r.status, 200);
  assertEquals(t.keys, ["secret-1", "secret-2"]);
  const none = await handleAsk("POST", AUTH, { request: "SOS incidents" }, deps([], { aiConfig: () => Promise.resolve({}) }).d);
  assertEquals((none.body as { reason: string }).reason, NO_AI);
  const limited = await handleAsk("POST", AUTH, { request: "SOS incidents" }, deps([], { rateTake: () => Promise.resolve(90) }).d);
  assertEquals(limited.status, 429);
  const unchecked = await handleAsk("POST", AUTH, { request: "SOS incidents" }, deps([], { rateTake: () => Promise.resolve(null) }).d);
  assertEquals(unchecked.status, 503);
});

Deno.test("GET says whether the AI and the email are set up, never a key", async () => {
  const r = await handleAsk("GET", AUTH, null, deps([]).d);
  assertEquals(r.body, {
    ai: { ready: true },
    email: { ready: false, key_set: false, from: "GET.ride Reports <reports@getride.my>", sender_ok: true },
  });
  assert(!JSON.stringify(r.body).includes("secret-"));
});

Deno.test("the shared provider code: the setting, the answer's JSON, the requests", async () => {
  assertEquals(serviceOf({ provider: "claude", keys: { claude: [{ id: "a", label: "", key: " ", enabled: true }] } }).keys, []);
  assertEquals(serviceOf(null).provider, "gemini");
  assertEquals(jsonObjectIn("Here:\n```json\n{\"a\": 1}\n```"), { a: 1 });
  assertEquals(jsonObjectIn("[1, 2]"), null);
  const seen: string[] = [];
  const fake = (url: string | URL | Request, init?: RequestInit) => {
    const sent = JSON.parse(String(init?.body));
    seen.push(`${String(url).split("?")[0]} ${sent.temperature ?? sent.generationConfig?.temperature}`);
    const u = String(url);
    const body = u.includes("anthropic")
      ? { content: [{ text: "{}" }] }
      : u.includes("googleapis")
      ? { candidates: [{ content: { parts: [{ text: "{}" }] } }] }
      : { choices: [{ message: { content: "{}" } }] };
    return Promise.resolve(new Response(JSON.stringify(body)));
  };
  const opts = { systemInstruction: "s", temperature: 0, maxTokens: 10 };
  for (const p of ["gemini", "claude", "chatgpt"] as const) {
    assertEquals((await callProvider(p, "q", "k", "m", opts, fake as typeof fetch)).content, "{}");
  }
  assertEquals(seen, [
    "https://generativelanguage.googleapis.com/v1beta/models/m:generateContent 0",
    "https://api.anthropic.com/v1/messages 0",
    "https://api.openai.com/v1/chat/completions 0",
  ]);
});
