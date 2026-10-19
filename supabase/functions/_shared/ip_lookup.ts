/**
 * The `ip-lookup` function's handling, with the rate check, the provider and
 * the clock passed in, so it is tested without a network or a database.
 *
 *   POST {} / GET
 *       → { public_ip, isp_provider, isp_org, ip_city, ip_region, ip_country }
 *         The caller's address from the proxy headers and what ipwho.is says
 *         about it. A private address, a refused or unreachable rate check,
 *         or a provider that fails or takes longer than 2.5 s gives the
 *         address with the rest null.
 *   POST { "ip_only": true } / ?ip_only=1
 *       → { public_ip }
 *         Only the address, straight from the headers: no rate check and no
 *         provider. The device blacklist check uses it on the sign-in path.
 *
 * ipwho.is answers are kept in memory per instance for 24 h (at most 5,000
 * addresses), and a kept answer is given before the rate check, so a repeat
 * caller costs neither a database write nor a provider request. On a miss
 * the database's rate check and the provider run together, behind a
 * per-instance count that refuses before either is asked.
 */

export interface IpInfo {
  public_ip: string | null;
  isp_provider: string | null;
  isp_org: string | null;
  ip_city: string | null;
  ip_region: string | null;
  ip_country: string | null;
}

export const EMPTY: IpInfo = {
  public_ip: null,
  isp_provider: null,
  isp_org: null,
  ip_city: null,
  ip_region: null,
  ip_country: null,
};

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

/** How long ipwho.is gets before the address is answered without it. */
export const PROVIDER_TIMEOUT_MS = 2500;

/** How long a provider answer is kept, and for how many addresses. */
export const CACHE_TTL_MS = 24 * 60 * 60 * 1000;
export const CACHE_MAX = 5000;

/** A body larger than this is not read for `ip_only` (it is never needed). */
const MAX_BODY_BYTES = 4096;

export function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

/**
 * The caller's address from the proxy headers: Cloudflare's own first (a
 * client cannot set it through Cloudflare), as request_client_ip (0137) does.
 */
export function resolveCallerIp(req: Request): string | null {
  const candidates = [
    req.headers.get("cf-connecting-ip"),
    req.headers.get("x-real-ip"),
    req.headers.get("x-forwarded-for"),
  ];
  for (const raw of candidates) {
    if (!raw) continue;
    // x-forwarded-for may be a comma-separated list; the client is the first.
    const first = raw.split(",")[0]?.trim();
    if (first) return first;
  }
  return null;
}

export function isPrivateIp(ip: string): boolean {
  return (
    ip.startsWith("10.") ||
    ip.startsWith("192.168.") ||
    ip.startsWith("127.") ||
    ip.startsWith("::1") ||
    ip.startsWith("fe80:") ||
    /^172\.(1[6-9]|2[0-9]|3[0-1])\./.test(ip)
  );
}

/**
 * Provider answers by address, oldest first: an expired entry is dropped when
 * read, and the oldest one when a new address would go past [max].
 */
export class IpInfoCache {
  #entries = new Map<string, { info: IpInfo; at: number }>();

  constructor(readonly max = CACHE_MAX, readonly ttlMs = CACHE_TTL_MS) {}

  get size(): number {
    return this.#entries.size;
  }

  get(ip: string, now: number): IpInfo | null {
    const hit = this.#entries.get(ip);
    if (!hit) return null;
    if (now - hit.at >= this.ttlMs) {
      this.#entries.delete(ip);
      return null;
    }
    return hit.info;
  }

  set(ip: string, info: IpInfo, now: number): void {
    this.#entries.delete(ip);
    while (this.#entries.size >= this.max) {
      const oldest = this.#entries.keys().next().value;
      if (oldest === undefined) break;
      this.#entries.delete(oldest);
    }
    this.#entries.set(ip, { info, at: now });
  }
}

/** ipwho.is (free, HTTPS, no key); null when it fails or is too slow. */
export async function lookupIpWhoIs(
  ip: string,
  fetchFn: typeof fetch = fetch,
  timeoutMs = PROVIDER_TIMEOUT_MS,
): Promise<IpInfo | null> {
  try {
    const res = await fetchFn(`https://ipwho.is/${encodeURIComponent(ip)}`, {
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!res.ok) {
      await res.body?.cancel();
      return null;
    }
    const d = await res.json();
    if (d?.success === false) return null;
    return {
      public_ip: typeof d?.ip === "string" ? d.ip : ip,
      isp_provider: d?.connection?.isp ?? null,
      isp_org: d?.connection?.org ?? d?.connection?.domain ?? null,
      ip_city: d?.city ?? null,
      ip_region: d?.region ?? null,
      ip_country: d?.country ?? null,
    };
  } catch {
    return null;
  }
}

/** Whether the caller asked for the address only (`?ip_only=1` or `{"ip_only": true}`). */
export async function wantsIpOnly(req: Request): Promise<boolean> {
  const q = new URL(req.url).searchParams.get("ip_only");
  if (q !== null) {
    await req.body?.cancel();
    return q === "1" || q === "true";
  }
  if (!req.body) return false;
  const length = Number(req.headers.get("content-length") ?? "0");
  if (!Number.isFinite(length) || length > MAX_BODY_BYTES) {
    await req.body.cancel();
    return false;
  }
  try {
    const text = await req.text();
    if (text.length > MAX_BODY_BYTES) return false;
    const body = JSON.parse(text);
    return body?.ip_only === true || body?.ip_only === 1 || body?.ip_only === "1";
  } catch {
    return false;
  }
}

export interface IpLookupDeps {
  /** True when this address may look up now; false when it is over the limit or the check failed. */
  rateTake(ip: string): Promise<boolean>;
  lookup(ip: string): Promise<IpInfo | null>;
  cache: IpInfoCache;
  /** This instance's own per-address count, checked before anything else. */
  local?: LocalRateLimit;
  now(): number;
}

/**
 * A per-instance count of lookups by address in a sliding window, so a
 * caller over the limit is refused before the database or the provider is
 * asked. The database's limit still counts across instances.
 */
export class LocalRateLimit {
  #hits = new Map<string, number[]>();

  constructor(readonly limit = 30, readonly windowMs = 10 * 60 * 1000, readonly maxKeys = 5000) {}

  take(key: string, now: number): boolean {
    const recent = (this.#hits.get(key) ?? []).filter((t) => now - t < this.windowMs);
    if (recent.length >= this.limit) {
      this.#hits.set(key, recent);
      return false;
    }
    recent.push(now);
    this.#hits.delete(key);
    while (this.#hits.size >= this.maxKeys) {
      const oldest = this.#hits.keys().next().value;
      if (oldest === undefined) break;
      this.#hits.delete(oldest);
    }
    this.#hits.set(key, recent);
    return true;
  }
}

export async function handleIpLookup(req: Request, deps: IpLookupDeps): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST" && req.method !== "GET") {
    await req.body?.cancel();
    return json({ error: "method_not_allowed" }, 405);
  }

  const ipOnly = await wantsIpOnly(req);
  const ip = resolveCallerIp(req);

  if (ipOnly) return json({ public_ip: ip }, 200);

  if (!ip) {
    return json({ ...EMPTY }, 200);
  }
  if (isPrivateIp(ip)) {
    // Can't resolve ISP for a private/loopback address.
    return json({ ...EMPTY, public_ip: ip }, 200);
  }

  const kept = deps.cache.get(ip, deps.now());
  if (kept) return json(kept, 200);

  // Over this instance's own count, nothing is asked of the database or
  // the provider at all.
  if (deps.local && !deps.local.take(ip, deps.now())) {
    return json({ ...EMPTY, public_ip: ip }, 200);
  }

  // The database's limit and the provider are asked together (PERF-76):
  // the limit's round trip no longer comes before the lookup. Fails closed:
  // when the limit refuses or can't be checked, the provider's answer is
  // dropped, neither given nor kept.
  const [allowed, info] = await Promise.all([
    deps.rateTake(ip).catch(() => false),
    deps.lookup(ip).catch(() => null),
  ]);
  if (!allowed || !info) {
    return json({ ...EMPTY, public_ip: ip }, 200);
  }

  deps.cache.set(ip, info, deps.now());
  return json(info, 200);
}
