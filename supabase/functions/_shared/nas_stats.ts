/**
 * Visitor stats (migration 0321): the pure half of the `nas-stats` function
 * behind Admin › Settings › Office NAS › Visitor stats. It reads today's
 * numbers from Umami on the office NAS (deploy/nas-stats), which answers on
 * https://stats.getride.my through a Cloudflare Tunnel, and says "NAS off"
 * when it can't be reached: nothing else depends on it.
 *
 * Admin → API Keys keeps the key as "Umami" (provider "umami", service
 * "api"): the address, a space, then a view-only Umami user's name and
 * password ("https://stats.getride.my getride:PASSWORD"), or an API token
 * instead of the name and password.
 *
 *   POST {url}/api/auth/login { username, password }      → { token }
 *   GET  {url}/api/websites/{id}/stats?startAt&endAt       → { pageviews, visitors, visits, … }
 *   GET  {url}/api/websites/{id}/metrics?type=url|referrer → [{ x, y }]
 *
 * (Umami 2 sends each number as { value, prev }, later versions as a plain
 * number; Umami 3 calls the "url" metric "path". Both are read.)
 *
 *     deno test supabase/functions/_shared/nas_stats_test.ts
 */

export const UMAMI_PROVIDER = "umami";
export const UMAMI_SERVICE = "api";
/** How long the function waits for the NAS, per request. */
export const UMAMI_TIMEOUT_MS = 6000;
export const DEFAULT_TIME_ZONE = "Asia/Kuala_Lumpur";

export interface UmamiKey {
  /** https://host[/path], no trailing slash. */
  url: string;
  username?: string;
  password?: string;
  token?: string;
}

/** The stored value, split up; null when it isn't one. */
export function parseUmamiKey(value: string | null | undefined): UmamiKey | null {
  const m = /^(https:\/\/\S+?)\/*\s+(\S.*)$/.exec((value ?? "").trim());
  if (!m) return null;
  const url = m[1];
  if (!/^https:\/\/[^\s/:]+(:\d{1,5})?(\/\S*)?$/.test(url)) return null;
  const rest = m[2].trim();
  const colon = rest.indexOf(":");
  if (colon > 0) {
    const username = rest.slice(0, colon);
    const password = rest.slice(colon + 1);
    if (!password || /\s/.test(username)) return null;
    return { url, username, password };
  }
  if (/\s/.test(rest) || rest.length < 16) return null;
  return { url, token: rest };
}

interface KeyEntry {
  value?: unknown;
  disabled?: unknown;
}

/** The first usable Umami key in Admin → API Keys, or null. */
export function umamiKey(apiProviders: unknown): UmamiKey | null {
  const list = Array.isArray(apiProviders) ? apiProviders : (apiProviders as { providers?: unknown })?.providers;
  if (!Array.isArray(list)) return null;
  const p = list.find((x) => x?.id === UMAMI_PROVIDER);
  const s = (p?.services ?? []).find((x: { id?: string }) => x?.id === UMAMI_SERVICE);
  for (const k of (Array.isArray(s?.keys) ? s.keys as KeyEntry[] : [])) {
    if (k?.disabled === true || typeof k?.value !== "string") continue;
    const key = parseUmamiKey(k.value);
    if (key) return key;
  }
  return null;
}

/** Today, midnight to now, in [timeZone], as Umami's millisecond bounds. */
export function dayRange(now: Date, timeZone = DEFAULT_TIME_ZONE): { startAt: number; endAt: number } {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-US", {
      timeZone,
      hourCycle: "h23",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    }).formatToParts(now).map((p) => [p.type, p.value]),
  );
  const asUtc = Date.UTC(+parts.year, +parts.month - 1, +parts.day, +parts.hour, +parts.minute, +parts.second);
  const offset = asUtc - Math.floor(now.getTime() / 1000) * 1000;
  const midnight = Date.UTC(+parts.year, +parts.month - 1, +parts.day) - offset;
  return { startAt: midnight, endAt: now.getTime() };
}

/** A number from Umami 2 ({ value }) or later (a plain number). */
export function statValue(v: unknown): number {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  const inner = (v as { value?: unknown } | null)?.value;
  return typeof inner === "number" && Number.isFinite(inner) ? inner : 0;
}

export interface Metric {
  x: string;
  y: number;
}

function metrics(v: unknown): Metric[] {
  if (!Array.isArray(v)) return [];
  return v
    .map((m) => ({ x: typeof m?.x === "string" ? m.x : "", y: statValue(m?.y) }))
    .filter((m) => m.y > 0)
    .sort((a, b) => b.y - a.y);
}

/** Where visitors came from, in words the owner knows. */
export function sourceName(referrer: string): string {
  const host = referrer.trim().toLowerCase().replace(/^https?:\/\//, "").replace(/^www\./, "").split(/[/?#]/)[0];
  if (!host) return "Direct";
  const known: Array<[RegExp, string]> = [
    [/(^|\.)(wa\.me|whatsapp\.com)$/, "WhatsApp"],
    [/(^|\.)(facebook\.com|fb\.com|fb\.me|messenger\.com)$/, "Facebook"],
    [/(^|\.)instagram\.com$/, "Instagram"],
    [/(^|\.)tiktok\.com$/, "TikTok"],
    [/(^|\.)(t\.co|twitter\.com|x\.com)$/, "X"],
    [/(^|\.)(t\.me|telegram\.org)$/, "Telegram"],
    [/(^|\.)google\.[a-z.]+$/, "Google"],
    [/(^|\.)bing\.com$/, "Bing"],
    [/(^|\.)getride\.my$/, "get.ride"],
  ];
  for (const [re, name] of known) if (re.test(host)) return name;
  return host;
}

export interface Today {
  visitors: number;
  pageviews: number;
  visits: number;
  installViews: number;
  topPage: string | null;
  topSource: string | null;
}

export function summarize(stats: unknown, urls: unknown, referrers: unknown): Today {
  const s = (stats ?? {}) as Record<string, unknown>;
  const pages = metrics(urls);
  const sources = new Map<string, number>();
  for (const r of metrics(referrers)) sources.set(sourceName(r.x), (sources.get(sourceName(r.x)) ?? 0) + r.y);
  const top = [...sources.entries()].sort((a, b) => b[1] - a[1])[0];
  return {
    visitors: statValue(s.visitors),
    pageviews: statValue(s.pageviews),
    visits: statValue(s.visits),
    installViews: pages.filter((p) => /^\/install(\/|$)/.test(p.x)).reduce((n, p) => n + p.y, 0),
    topPage: pages[0]?.x || null,
    topSource: top ? top[0] : null,
  };
}

export type StatsState = "on" | "paused" | "not_set" | "nas_off" | "refused";

export interface StatsReply {
  state: StatsState;
  today?: Today;
  /** What is missing (not_set) or what went wrong (nas_off, refused). */
  reason?: string;
  at: string;
}

export interface StatsDeps {
  /** app_settings 'nas_stats' and 'api_providers'. */
  settings(): Promise<{ stats: unknown; apiProviders: unknown }>;
  fetch(url: string, init: RequestInit): Promise<Response>;
  now(): Date;
  /** Records the outcome on nas_services ('stats'); never throws. */
  beat(status: string, detail: Record<string, unknown>): Promise<void>;
}

class Refused extends Error {}

async function getJson(deps: StatsDeps, url: string, init: RequestInit): Promise<unknown> {
  const res = await deps.fetch(url, { ...init, signal: AbortSignal.timeout(UMAMI_TIMEOUT_MS) });
  if (res.status === 401 || res.status === 403) {
    await res.body?.cancel();
    throw new Refused(`HTTP ${res.status}`);
  }
  if (!res.ok) {
    await res.body?.cancel();
    throw new Error(`HTTP ${res.status}`);
  }
  return await res.json();
}

/** Today's numbers, or why there are none. */
export async function readStats(deps: StatsDeps): Promise<StatsReply> {
  const at = deps.now().toISOString();
  const { stats, apiProviders } = await deps.settings();
  const cfg = (stats ?? {}) as { on?: unknown; websiteId?: unknown };
  if (cfg.on === false) return { state: "paused", at };
  const key = umamiKey(apiProviders);
  const website = typeof cfg.websiteId === "string" && /^[0-9a-f-]{36}$/i.test(cfg.websiteId) ? cfg.websiteId : null;
  if (!key || !website) {
    return { state: "not_set", reason: !key ? "key" : "website", at };
  }
  try {
    let token = key.token;
    if (!token) {
      const login = await getJson(deps, `${key.url}/api/auth/login`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ username: key.username, password: key.password }),
      }) as { token?: unknown };
      if (typeof login?.token !== "string") throw new Refused("no token");
      token = login.token;
    }
    const headers = { Authorization: `Bearer ${token}`, Accept: "application/json" };
    const { startAt, endAt } = dayRange(deps.now());
    const base = `${key.url}/api/websites/${website}`;
    const q = `startAt=${startAt}&endAt=${endAt}`;
    const [s, urls, refs] = await Promise.all([
      getJson(deps, `${base}/stats?${q}`, { headers }),
      getJson(deps, `${base}/metrics?${q}&type=url`, { headers })
        .catch((e) => e instanceof Refused ? Promise.reject(e) : getJson(deps, `${base}/metrics?${q}&type=path`, { headers })),
      getJson(deps, `${base}/metrics?${q}&type=referrer`, { headers }),
    ]);
    const today = summarize(s, urls, refs);
    await deps.beat("ok", { visitors: today.visitors, pageviews: today.pageviews });
    return { state: "on", today, at };
  } catch (e) {
    const refused = e instanceof Refused;
    const reason = refused ? "The Umami name, password or token was refused." : String((e as Error)?.message ?? e).slice(0, 200);
    await deps.beat(refused ? "refused" : "off", { reason });
    return { state: refused ? "refused" : "nas_off", reason, at };
  }
}
