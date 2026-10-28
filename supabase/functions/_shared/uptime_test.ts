import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.19";

import type { EmailMessage, EmailProvider } from "./email.ts";
import { alertText, checkDatabase, checkHttp, classify, flushAlerts, handleUptime, telegramSend } from "./uptime.ts";

const PROJECT = "https://x.supabase.co";

/** A clock that moves [step] ms each time it is read. */
function clock(step: number) {
  let t = 0;
  return () => (t += step);
}

function answering(status: number | Error, seen: string[] = []): typeof fetch {
  return ((url: string | URL | Request) => {
    seen.push(String(url));
    return status instanceof Error ? Promise.reject(status) : Promise.resolve(new Response("ok", { status }));
  }) as typeof fetch;
}

Deno.test("what an answer means", () => {
  assertEquals(classify(200, 120, 3000), "up");
  assertEquals(classify(404, 120, 3000), "up", "the server is there");
  assertEquals(classify(401, 3200, 3000), "slow");
  assertEquals(classify(502, 100, 3000), "down");
  assertEquals(classify(null, 100, 3000), "down");
  assertEquals(classify(200, 100, 3000, "TimeoutError"), "down");
});

Deno.test("a web address, timed; {project} filled in", async () => {
  const seen: string[] = [];
  const r = await checkHttp({ id: "functions", kind: "http", url: "{project}/functions/v1/uptime-check?ping=1", slowMs: 500 },
    PROJECT, answering(200, seen), clock(100));
  assertEquals(seen, ["https://x.supabase.co/functions/v1/uptime-check?ping=1"]);
  assertEquals(r, { id: "functions", status: "up", ms: 100, detail: "HTTP 200 in 100 ms" });

  const slow = await checkHttp({ id: "website", kind: "http", url: "https://getride.my", slowMs: 500 }, PROJECT, answering(200), clock(800));
  assertEquals(slow.status, "slow");
  const err = await checkHttp({ id: "website", kind: "http", url: "https://getride.my" }, PROJECT, answering(503), clock(10));
  assertEquals(err.status, "down");
  const gone = await checkHttp({ id: "website", kind: "http", url: "https://getride.my" }, PROJECT,
    answering(Object.assign(new Error("x"), { name: "TypeError" })), clock(10));
  assertEquals([gone.status, gone.detail], ["down", "Couldn't connect (TypeError)"]);
  const timeout = await checkHttp({ id: "w", kind: "http", url: "https://getride.my" }, PROJECT,
    answering(Object.assign(new Error("t"), { name: "TimeoutError" })), clock(10));
  assertEquals(timeout.detail, "No answer in 10 s");
  assertEquals((await checkHttp({ id: "p", kind: "http", url: null }, PROJECT, answering(200))).detail, "No address");
});

Deno.test("the database check", async () => {
  assertEquals((await checkDatabase({ id: "database", kind: "database" }, () => Promise.resolve(), clock(35))).status, "up");
  const bad = await checkDatabase({ id: "database", kind: "database" }, () => Promise.reject(new Error("too many connections")), clock(5));
  assertEquals(bad.status, "down");
  assertStringIncludes(bad.detail!, "too many connections");
});

Deno.test("Telegram: sent, or why not without the token", async () => {
  const seen: string[] = [];
  assertEquals(await telegramSend("123:SECRET", "-100", "hi", answering(200, seen)), "sent");
  assertEquals(seen[0], "https://api.telegram.org/bot123:SECRET/sendMessage");
  const refused = (() =>
    Promise.resolve(new Response(JSON.stringify({ ok: false, description: "chat not found for 123:SECRET" }), { status: 400 }))) as typeof fetch;
  const why = await telegramSend("123:SECRET", "-100", "hi", refused);
  assertStringIncludes(why, "Telegram refused (400)");
  assertEquals(why.includes("SECRET"), false);
});

Deno.test("alert text", () => {
  assertEquals(alertText({ kind: "down", title: "getride.my is down", body: "Timed out." }),
    "get.ride monitor · DOWN\ngetride.my is down\nTimed out.");
  assertStringIncludes(alertText({ kind: "resolved", title: "x", body: "y" }), "RESOLVED");
  assertStringIncludes(alertText({ kind: "backup_failed", title: "Backup failed", body: "y" }), "FAILED");
});

function mailer(sent: EmailMessage[], ok = true): EmailProvider {
  return {
    id: "fake",
    label: "Fake",
    maxRecipients: 50,
    send(m) {
      sent.push(m);
      return Promise.resolve(ok ? { ok: true, id: "e1" } : { ok: false, error: "Resend refused (403): domain" });
    },
  };
}

Deno.test("waiting alerts go out and each send is recorded", async () => {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const sent: EmailMessage[] = [];
  const tg: string[] = [];
  const n = await flushAlerts({
    rpc(name, args) {
      calls.push([name, args]);
      if (name === "uptime_alerts_due") {
        return Promise.resolve({
          telegramChats: ["-1001", "-1002"],
          emails: ["ops@example.com"],
          emailFrom: "GET.ride <reports@getride.my>",
          alerts: [
            { id: "a1", kind: "down", title: "Admin is down", body: "HTTP 502", telegram: true, email: true },
            { id: "a2", kind: "resolved", title: "Admin is back up", body: "Resolved", telegram: false, email: true },
          ],
        });
      }
      return Promise.resolve(null);
    },
    telegramToken: () => Promise.resolve("123:T"),
    email: () => Promise.resolve(mailer(sent)),
    fetchFn: answering(200, tg),
  });
  assertEquals(n, 2);
  assertEquals(tg.length, 2, "both chats");
  assertEquals(sent.map((m) => m.subject), ["get.ride monitor: Admin is down", "get.ride monitor: Admin is back up"]);
  assertEquals(calls.filter((c) => c[0] === "uptime_alert_sent").map((c) => c[1]), [
    { p_id: "a1", p_telegram: "sent", p_email: "sent" },
    { p_id: "a2", p_telegram: null, p_email: "sent" },
  ]);
});

Deno.test("no token or key: the reason is recorded", async () => {
  const calls: Array<Record<string, unknown>> = [];
  await flushAlerts({
    rpc(name, args) {
      if (name === "uptime_alert_sent") calls.push(args);
      return Promise.resolve(name === "uptime_alerts_due"
        ? { telegramChats: ["-1"], emails: ["a@b.co"], emailFrom: null, alerts: [{ id: "a1", kind: "test", title: "t", body: "b", telegram: true, email: true }] }
        : null);
    },
    telegramToken: () => Promise.resolve(null),
    email: () => Promise.resolve(mailer([])),
  });
  assertEquals(calls, [{ p_id: "a1", p_telegram: "No Telegram bot token in Admin > API Keys", p_email: "No sender address" }]);
});

Deno.test("the function: ping, callers, a round", async () => {
  const recorded: unknown[] = [];
  const deps = {
    projectUrl: PROJECT,
    callerOk: (r: Request) => Promise.resolve(r.headers.get("x-push-secret") === "s"),
    rpc(name: string, args: Record<string, unknown>) {
      if (name === "uptime_targets_for") {
        return Promise.resolve([
          { id: "website", kind: "http", url: "https://getride.my", slowMs: 3000 },
          { id: "database", kind: "database", slowMs: 3000 },
        ]);
      }
      if (name === "uptime_record") recorded.push(args);
      if (name === "uptime_alerts_due") return Promise.resolve({ telegramChats: [], emails: [], emailFrom: null, alerts: [] });
      return Promise.resolve(null);
    },
    ping: () => Promise.resolve(),
    telegramToken: () => Promise.resolve(null),
    email: () => Promise.resolve(null),
    fetchFn: answering(200),
  };
  const ping = await handleUptime(new Request("https://f/uptime-check?ping=1"), deps);
  assertEquals(await ping.json(), { ok: true });
  const no = await handleUptime(new Request("https://f/uptime-check", { method: "POST", body: "{}" }), deps);
  assertEquals(no.status, 401);
  const round = await handleUptime(new Request("https://f/uptime-check", {
    method: "POST",
    headers: { "x-push-secret": "s" },
    body: JSON.stringify({ action: "check" }),
  }), deps);
  assertEquals(await round.json(), { checked: 2, sent: 0 });
  const r = recorded[0] as { p_source: string; p_results: Array<{ id: string; status: string }> };
  assertEquals(r.p_source, "cloud");
  assertEquals(r.p_results.map((x) => `${x.id}:${x.status}`), ["website:up", "database:up"]);
  const flush = await handleUptime(new Request("https://f/uptime-check", {
    method: "POST",
    headers: { "x-push-secret": "s" },
    body: JSON.stringify({ action: "flush" }),
  }), deps);
  assertEquals(await flush.json(), { checked: 0, sent: 0 });
});
