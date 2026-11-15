/**
 * Fare estimates from Waze, through GET.route servers (the Waze route
 * scraper, run on the office NAS behind a Cloudflare Tunnel; see the
 * GET.route repository's deploy/nas/README.md).
 *
 * Admin › Settings › Fare AI provider sets the order estimates are asked in
 * (`fare_ai_provider.chain`, _shared/fare_chain.ts); the "waze" step asks the
 * servers in `wazeServers`. A server is
 *
 *   { id, label, url: "https://route1.getride.my", key, enabled,
 *     area?: { country, state, city, suburb } }
 *
 * Several servers (one container each on the office NAS) split the load by
 * area: a server with an area serves trips whose pickup is in it (the
 * admin's Country / States / Cities / Suburbs, matched like commission
 * rules: the smallest mapped outline holding the pickup at each level). The
 * most specific match is asked first, then servers with no area, then the
 * other areas' servers as a backup.
 *
 * and is asked GET <url>/routes/search?from=lat,lng&to=lat,lng&max_routes=1
 * with the key in X-Route-Key. A trip with stops is asked one leg at a time
 * and the legs added up. The answer becomes the same estimate an AI gives
 * (distance_km, duration_min, summary, tolls), so the apps need no change.
 *
 * Pure apart from the injected fetch; see waze_route_test.ts.
 *
 *     deno test supabase/functions/_shared/waze_route_test.ts
 */

/** The `provider` an estimate and its log row carry. */
export const WAZE_PROVIDER = "waze";

/** A place by name; a blank level means "any". */
export interface Area {
  country: string;
  state: string;
  city: string;
  suburb: string;
}

export interface WazeServer {
  id: string;
  label: string;
  url: string;
  key: string;
  enabled: boolean;
  /** Absent: any area. */
  area?: Area;
}

export interface LatLng {
  latitude: number;
  longitude: number;
}

export interface WazeTollBooth {
  id: string;
  name?: string;
  charge: number;
}

export interface WazeEstimate {
  distance_km: number;
  duration_min: number;
  summary?: string;
  toll_count: number;
  toll_total: number;
  tolls: WazeTollBooth[];
}

export interface WazeResult {
  estimate: WazeEstimate | null;
  httpStatus: number | null;
  error: string | null;
  /** The servers' answers, for the response log (trimmed by the caller). */
  raw: string | null;
}

/** A server URL GET.ride may call: https, no credentials, no query. */
export function cleanServerUrl(v: unknown): string | null {
  if (typeof v !== "string") return null;
  let u: URL;
  try {
    u = new URL(v.trim());
  } catch {
    return null;
  }
  if (u.protocol !== "https:" || u.username || u.password || u.search || u.hash) return null;
  return u.origin + u.pathname.replace(/\/+$/, "");
}

/** The enabled servers of a saved config that have a URL and a key, in order. */
export function wazeServersOf(config: { wazeServers?: unknown } | null | undefined): WazeServer[] {
  const raw = Array.isArray(config?.wazeServers) ? config!.wazeServers as unknown[] : [];
  const out: WazeServer[] = [];
  raw.forEach((s, i) => {
    if (!s || typeof s !== "object") return;
    const o = s as Record<string, unknown>;
    const url = cleanServerUrl(o.url);
    const key = typeof o.key === "string" ? o.key.trim() : "";
    if (o.enabled === false || !url || !key) return;
    const id = typeof o.id === "string" && o.id.trim() ? o.id.trim() : `waze-${i + 1}`;
    const label = typeof o.label === "string" && o.label.trim() ? o.label.trim() : `Waze server ${i + 1}`;
    const area = areaOf(o.area);
    out.push({ id, label, url, key, enabled: true, ...(area ? { area } : {}) });
  });
  return out;
}

const str = (v: unknown) => (typeof v === "string" ? v.trim() : "");

/** A saved area, or null when it names nothing. A level below a blank one is dropped. */
export function areaOf(raw: unknown): Area | null {
  if (!raw || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  const levels = [str(o.country), str(o.state), str(o.city), str(o.suburb)];
  const gap = levels.indexOf("");
  if (gap !== -1) levels.fill("", gap);
  if (!levels[0]) return null;
  return { country: levels[0], state: levels[1], city: levels[2], suburb: levels[3] };
}

/** One row of the regions_at(lat, lng) database function. */
export interface RegionRow {
  region_table: string;
  country?: string | null;
  state?: string | null;
  city?: string | null;
  suburb?: string | null;
  inside?: boolean | null;
  area?: number | null;
}

/** The place a point is in: at each level the smallest mapped outline
 * holding it (commission_resolve_rate's rule, migration 0216). */
export function placeFromRegions(rows: RegionRow[] | null | undefined): Area {
  const place: Area = { country: "", state: "", city: "", suburb: "" };
  const best = new Map<string, RegionRow>();
  for (const r of rows ?? []) {
    if (!r?.inside) continue;
    const cur = best.get(r.region_table);
    const a = Number.isFinite(Number(r.area)) && r.area !== null ? Number(r.area) : Infinity;
    const b = cur && Number.isFinite(Number(cur.area)) && cur.area !== null ? Number(cur.area) : Infinity;
    if (!cur || a < b) best.set(r.region_table, r);
  }
  const c = best.get("countries"), s = best.get("states"), ci = best.get("cities"), su = best.get("suburbs");
  if (c) place.country = str(c.country);
  if (s) {
    place.state = str(s.state);
    place.country ||= str(s.country);
  }
  if (ci) {
    place.city = str(ci.city);
    place.state ||= str(ci.state);
    place.country ||= str(ci.country);
  }
  if (su) {
    place.suburb = str(su.suburb);
    place.city ||= str(su.city);
    place.state ||= str(su.state);
    place.country ||= str(su.country);
  }
  return place;
}

const norm = (v: string) => v.trim().replace(/\s+/g, " ").toLowerCase();

/** How well a server's area fits a place: 1 (country) to 4 (suburb) for a
 * match, 0 for a server with no area, -1 when the place is elsewhere. */
export function areaMatch(area: Area | undefined, place: Area): number {
  if (!area) return 0;
  const want = [area.country, area.state, area.city, area.suburb];
  const have = [place.country, place.state, place.city, place.suburb];
  let level = 0;
  for (let i = 0; i < 4; i++) {
    if (!want[i]) break;
    if (!have[i] || norm(want[i]) !== norm(have[i])) return -1;
    level = i + 1;
  }
  return level;
}

/** The order to ask the servers in for a trip starting at [place]: the
 * most specific area match first, then servers for any area, then other
 * areas' servers as a backup. Ties keep the admin's order. */
export function orderServersFor(servers: WazeServer[], place: Area): WazeServer[] {
  const rank = (s: WazeServer) => {
    const m = areaMatch(s.area, place);
    return m > 0 ? 10 - m : m === 0 ? 10 : 20;
  };
  return servers
    .map((s, i) => ({ s, i, r: rank(s) }))
    .sort((a, b) => a.r - b.r || a.i - b.i)
    .map((x) => x.s);
}

/** True when any server is tied to an area (only then is the pickup looked up). */
export const anyArea = (servers: WazeServer[]) => servers.some((s) => !!s.area);

const ll = (p: LatLng) => `${p.latitude.toFixed(6)},${p.longitude.toFixed(6)}`;

/** The GET.route URL for one leg. */
export function legUrl(server: { url: string }, from: LatLng, to: LatLng): string {
  const q = new URLSearchParams({ from: ll(from), to: ll(to), max_routes: "1" });
  return `${server.url}/routes/search?${q}`;
}

interface WazeRoute {
  name?: string | null;
  duration_seconds?: number | null;
  distance_meters?: number | null;
  toll?: { price?: number | null; road_name?: string | null } | null;
}

/** The route GET.route put first (the fastest), or null. */
function firstRoute(body: unknown): WazeRoute | null {
  const routes = (body as { routes?: unknown } | null)?.routes;
  if (!Array.isArray(routes) || routes.length === 0) return null;
  const r = routes[0];
  return r && typeof r === "object" ? r as WazeRoute : null;
}

/** The legs' routes added up into one estimate, or null when a leg lacks
 * its distance or time. */
export function estimateFromLegs(legs: WazeRoute[]): WazeEstimate | null {
  let meters = 0, seconds = 0;
  const names: string[] = [];
  const tolls: WazeTollBooth[] = [];
  for (const r of legs) {
    const m = Number(r.distance_meters), s = Number(r.duration_seconds);
    if (!Number.isFinite(m) || m <= 0 || !Number.isFinite(s) || s <= 0) return null;
    meters += m;
    seconds += s;
    if (typeof r.name === "string" && r.name.trim() && !names.includes(r.name.trim())) names.push(r.name.trim());
    const price = Number(r.toll?.price);
    if (r.toll && Number.isFinite(price) && price > 0) {
      tolls.push({
        id: `toll-${tolls.length}`,
        name: typeof r.toll.road_name === "string" && r.toll.road_name ? r.toll.road_name : undefined,
        charge: Math.round(price * 100) / 100,
      });
    }
  }
  return {
    distance_km: Math.round(meters / 100) / 10,
    duration_min: Math.ceil(seconds / 60),
    summary: names.length ? `Via ${names.join(", then ")} (Waze live traffic)` : "Waze live traffic",
    toll_count: tolls.length,
    toll_total: Math.round(tolls.reduce((sum, t) => sum + t.charge, 0) * 100) / 100,
    tolls,
  };
}

export type Fetch = (url: string, init: RequestInit) => Promise<Response>;

/** How long the Waze step may take for one trip, every leg and server
 * included. The rider app waits 5 s for an estimate ("Calculating fare",
 * home_screen.dart aiEstimateTimeout) and then prices the plain route, so
 * Waze must leave the next step (AI, OSRM) time to answer. A cold container
 * that misses it keeps opening Chrome, so the next trip is fast. */
export const WAZE_TRIP_BUDGET_MS = 3_000;

/** Asks one server for the whole trip (one call per leg, in order), all of
 * it within [budgetMs]. A leg that fails fails the server, so the caller
 * moves on to the next one. */
export async function askWazeServer(
  server: WazeServer,
  points: LatLng[],
  fetchImpl: Fetch = fetch,
  budgetMs = WAZE_TRIP_BUDGET_MS,
): Promise<WazeResult> {
  const deadline = Date.now() + budgetMs;
  const legs: WazeRoute[] = [];
  const raws: string[] = [];
  let status: number | null = null;
  for (let i = 0; i + 1 < points.length; i++) {
    let text: string;
    const left = deadline - Date.now();
    if (left <= 0) {
      return { estimate: null, httpStatus: status, error: `No answer within ${budgetMs / 1000} s`, raw: raws.join("\n") || null };
    }
    try {
      const res = await fetchImpl(legUrl(server, points[i], points[i + 1]), {
        headers: { "X-Route-Key": server.key, accept: "application/json" },
        signal: AbortSignal.timeout(left),
      });
      status = res.status;
      text = await res.text();
      raws.push(text.substring(0, 2000));
      if (!res.ok) {
        let msg = `HTTP ${res.status}`;
        try {
          const e = JSON.parse(text)?.error;
          if (typeof e === "string" && e) msg += `: ${e}`;
        } catch { /* not JSON */ }
        return { estimate: null, httpStatus: status, error: msg, raw: raws.join("\n") };
      }
    } catch (e) {
      return {
        estimate: null,
        httpStatus: status,
        error: e instanceof Error && e.name === "TimeoutError"
          ? `No answer within ${budgetMs / 1000} s`
          : e instanceof Error ? `${e.name}: ${e.message}` : String(e),
        raw: raws.length ? raws.join("\n") : null,
      };
    }
    let route: WazeRoute | null = null;
    try {
      route = firstRoute(JSON.parse(text));
    } catch { /* below */ }
    if (!route) return { estimate: null, httpStatus: status, error: "No route in the answer", raw: raws.join("\n") };
    legs.push(route);
  }
  const estimate = estimateFromLegs(legs);
  return {
    estimate,
    httpStatus: status,
    error: estimate ? null : "Route without distance or time",
    raw: raws.join("\n"),
  };
}

// ---- health (waze-server-health, migration 0411) ------------------------------------------------

/** How long the scheduled check waits for a server's /health. */
export const WAZE_HEALTH_TIMEOUT_MS = 15_000;

export interface HealthVerdict {
  state: "ok" | "down";
  detail: string | null;
}

/** What a server's /health answer means. GET.route sends `waze` (when its
 * last Waze call worked or failed) only with the right key, so a missing
 * `waze` is a refused key. A last call that failed after the last one that
 * worked means Waze is refusing the server (tokens, Chrome), not the NAS. */
export function healthVerdict(httpStatus: number | null, body: unknown, failure?: string): HealthVerdict {
  if (httpStatus === null) return { state: "down", detail: failure ?? "Health check: couldn't reach the server." };
  if (httpStatus < 200 || httpStatus >= 300) return { state: "down", detail: `Health check: HTTP ${httpStatus}.` };
  const b = (body && typeof body === "object" ? body : {}) as Record<string, unknown>;
  if (b.status !== "ok") return { state: "down", detail: "Health check: the server answered but not with status ok." };
  const w = b.waze;
  if (!w || typeof w !== "object") return { state: "down", detail: "Health check: the key was refused." };
  const { last_ok_at, last_error_at, last_error } = w as Record<string, unknown>;
  const ok = typeof last_ok_at === "string" ? Date.parse(last_ok_at) : NaN;
  const err = typeof last_error_at === "string" ? Date.parse(last_error_at) : NaN;
  if (Number.isFinite(err) && (!Number.isFinite(ok) || err > ok)) {
    const why = typeof last_error === "string" && last_error ? last_error.slice(0, 200) : "unknown error";
    return { state: "down", detail: `Waze is refusing this server: ${why}` };
  }
  return { state: "ok", detail: null };
}
