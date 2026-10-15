/**
 * The `geo` function's requests (Admin → Settings → Maps, migration 0200),
 * with everything outside it (the database, the providers, the clock)
 * passed in, so it is tested without a network.
 *
 *   GET ?action=profile&role=rider&device=android
 *       → { profile: { tiles: { light, dark, satellite, traffic }, search, reverse, routing,
 *                      direct: { nominatim, osrm } } }
 *         A tile slot is null to keep the app's own; traffic { off: true } for none.
 *   GET ?action=search&provider=here&role=…&device=…&q=…[&lat=&lng=][&countries=my][&lang=en]
 *       → { places: [{ name, address, lat, lng }] }
 *   GET ?action=reverse&provider=…&role=…&device=…&lat=…&lng=…
 *       → { place: { name, address, lat, lng, country, state, city, suburb } | null }
 *   GET ?action=route&provider=…&role=…&device=…&points=lat,lng;lat,lng[;…]
 *       → { route: { distanceKm, durationMin, points: [[lat, lng], …] } | null }
 *   GET ?action=fallbacks
 *       → { slots: ["google_tiles", …] }  the key slots with a secret synced from GitHub
 *         (names only, never a key), so Admin → Settings → Maps doesn't call them missing.
 *
 * A provider is only asked for a role and device whose profile lists it.
 * 429 { error: "rate_limited" } past the per-address limit.
 */
import {
  cacheKey,
  cacheSeconds,
  DIRECT,
  FALLBACK_SECRETS,
  googleSessionBody,
  type HttpRequest,
  isDevice,
  isRole,
  type Kind,
  keySlot,
  parseReverse,
  parseRoute,
  parseSearch,
  profileOf,
  resolveKey,
  reverseRequest,
  routeRequest,
  searchRequest,
  type TileSource,
  tileSource,
  trafficTileUrl,
} from "./geo.ts";

export interface GeoDeps {
  /** map_config and api_providers from app_settings. */
  settings(): Promise<{ config: unknown; apiProviders: unknown }>;
  /** One provider request; the parsed JSON body, or throws. */
  call(req: HttpRequest): Promise<unknown>;
  /** Counts a call against [bucket]'s minute; false when over [limit]. */
  take(bucket: string, limit: number): Promise<boolean>;
  count(provider: string, kind: Kind | "tiles", ok: boolean, cached: boolean): Promise<void>;
  cacheGet(key: string): Promise<unknown | null>;
  cachePut(key: string, value: unknown, seconds: number): Promise<void>;
  /** A Google Map Tiles session for [slot], reused until near its expiry. */
  googleSession(slot: "light" | "dark" | "satellite", key: string, region: string): Promise<string | null>;
  /** ISO alpha-2 → alpha-3 ("my" → "MYS"), or null. */
  iso3(cc: string): string | null;
  /** The function's own secret for a key slot, when Admin → API Keys has none. */
  fallbackKey?(slot: string): string | null;
}

/** Proxied lookups per caller address per minute. */
export const RATE_LIMIT = 120;

export interface GeoAnswer {
  status: number;
  body: unknown;
}

const bad = (error: string, status = 400): GeoAnswer => ({ status, body: { error } });

function coord(v: string | null, max: number): number | null {
  if (v == null || v.trim() === "") return null;
  const n = Number(v);
  return Number.isFinite(n) && Math.abs(n) <= max ? n : null;
}

/** The base URL an Admin → API Keys entry gives a self-hosted Nominatim or OSRM, else null. */
function directUrl(apiProviders: unknown, ref: string | undefined): string | null {
  const v = resolveKey(apiProviders, ref);
  return v && /^https:\/\/[^\s]+$/.test(v) ? v.replace(/\/+$/, "") : null;
}

export async function handleGeo(params: URLSearchParams, ip: string, deps: GeoDeps): Promise<GeoAnswer> {
  const action = params.get("action") ?? "";
  if (action === "fallbacks") {
    return { status: 200, body: { slots: Object.keys(FALLBACK_SECRETS).filter((s) => !!deps.fallbackKey?.(s)) } };
  }
  const role = params.get("role") ?? "";
  const device = params.get("device") ?? "";
  if (!isRole(role) || !isDevice(device)) return bad("Give role (rider|partner) and device (android|ios|web|desktop).");

  const { config, apiProviders } = await deps.settings();
  const profile = profileOf(config, role, device);
  const keys = ((config as { keys?: Record<string, string> } | null)?.keys) ?? {};
  // Admin → API Keys first; the function's own secret (synced from GitHub) when that slot is empty.
  const key = (provider: string, use: "tiles" | Kind) =>
    resolveKey(apiProviders, keys[keySlot(provider, use)]) ?? deps.fallbackKey?.(keySlot(provider, use)) ?? null;
  const countries = (params.get("countries") ?? "my").toLowerCase().split(",").map((c) => c.trim())
    .filter((c) => /^[a-z]{2}$/.test(c)).slice(0, 5);
  const lang = /^[a-z]{2}(-[A-Za-z]{2})?$/.test(params.get("lang") ?? "") ? params.get("lang")! : "en";

  if (action === "profile") {
    const tile = async (slot: "light" | "dark" | "satellite"): Promise<TileSource | null> => {
      const provider = profile.tiles[slot];
      if (provider === "app") return null;
      const k = key(provider, "tiles");
      let session: string | null = null;
      if (provider === "google" && k) {
        session = await deps.googleSession(slot, k, countries[0] ?? "my").catch(() => null);
      }
      return tileSource(provider, slot, k, session);
    };
    const t = profile.tiles.traffic;
    let traffic: unknown = null;
    if (t === "none") {
      traffic = { off: true };
    } else if (t !== "app") {
      const url = trafficTileUrl(t, key(t, "tiles"));
      const other = t === "tomtom" ? "here" : "tomtom";
      traffic = url ? { url, fallback: trafficTileUrl(other, key(other, "tiles")) } : null;
    }
    return {
      status: 200,
      body: {
        profile: {
          tiles: { light: await tile("light"), dark: await tile("dark"), satellite: await tile("satellite"), traffic },
          search: profile.search,
          reverse: profile.reverse,
          routing: profile.routing,
          direct: {
            nominatim: directUrl(apiProviders, keys.nominatim),
            osrm: directUrl(apiProviders, keys.osrm),
          },
        },
      },
    };
  }

  const kind: Kind | null = action === "search" ? "search" : action === "reverse" ? "reverse" : action === "route"
    ? "routing"
    : null;
  if (!kind) return bad("Unknown action.");
  const provider = params.get("provider") ?? "";
  if (DIRECT.has(provider) || !profile[kind].includes(provider)) {
    return bad("That provider is not set for this profile.", 403);
  }
  const k = key(provider, kind);
  if (!k) return bad("No key for that provider.", 503);
  if (!(await deps.take(`ip:${ip}`, RATE_LIMIT))) return bad("rate_limited", 429);

  let req: HttpRequest | null = null;
  let ck = "";
  let parse: (body: unknown) => unknown;
  if (kind === "search") {
    const q = (params.get("q") ?? "").trim().slice(0, 120);
    if (q.length < 3) return { status: 200, body: { places: [] } };
    const lat = coord(params.get("lat"), 90) ?? undefined, lng = coord(params.get("lng"), 180) ?? undefined;
    req = searchRequest(provider, {
      q,
      lat,
      lng,
      countries,
      countries3: countries.map((c) => deps.iso3(c)).filter((c): c is string => !!c),
      lang,
    }, k);
    // Near the same ~1 km, the same answer.
    ck = cacheKey(provider, kind, [q, lat == null ? "" : lat.toFixed(2), lng == null ? "" : lng.toFixed(2), countries.join(","), lang]);
    parse = (b) => ({ places: parseSearch(provider, b) });
  } else if (kind === "reverse") {
    const lat = coord(params.get("lat"), 90), lng = coord(params.get("lng"), 180);
    if (lat == null || lng == null) return bad("Give lat and lng.");
    req = reverseRequest(provider, lat, lng, lang, k);
    ck = cacheKey(provider, kind, [lat, lng, lang]);
    parse = (b) => ({ place: parseReverse(provider, b, lat, lng) });
  } else {
    const points = (params.get("points") ?? "").split(";").slice(0, 12).map((p) => {
      const [a, b] = p.split(",");
      const la = coord(a, 90), ln = coord(b, 180);
      return la == null || ln == null ? null : [la, ln] as [number, number];
    });
    if (points.length < 2 || points.some((p) => p == null)) return bad("Give points=lat,lng;lat,lng.");
    req = routeRequest(provider, points as [number, number][], k);
    ck = cacheKey(provider, kind, (points as [number, number][]).flat());
    parse = (b) => ({ route: parseRoute(provider, b) });
  }
  if (!req) return bad("That provider can't do this.", 400);

  const ttl = cacheSeconds(provider, kind);
  if (ttl > 0) {
    const hit = await deps.cacheGet(ck).catch(() => null);
    if (hit != null) {
      await deps.count(provider, kind, true, true).catch(() => {});
      return { status: 200, body: hit };
    }
  }
  try {
    const answer = parse(await deps.call(req)) as Record<string, unknown>;
    const empty = answer.places ? (answer.places as unknown[]).length === 0 : Object.values(answer)[0] == null;
    await deps.count(provider, kind, !empty, false).catch(() => {});
    if (ttl > 0 && !empty) await deps.cachePut(ck, answer, ttl).catch(() => {});
    return { status: 200, body: answer };
  } catch {
    await deps.count(provider, kind, false, false).catch(() => {});
    return bad("The provider did not answer.", 502);
  }
}

/** Google's createSession answer → the session and when it expires (ms). */
export function parseGoogleSession(body: unknown): { session: string; expiresAt: number } | null {
  const b = body as { session?: unknown; expiry?: unknown } | null;
  const session = typeof b?.session === "string" ? b.session : null;
  const expiry = Number(b?.expiry);
  if (!session || !Number.isFinite(expiry)) return null;
  return { session, expiresAt: expiry * 1000 };
}

export { googleSessionBody };
