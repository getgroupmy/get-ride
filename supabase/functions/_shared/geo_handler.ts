/**
 * The `geo` function's requests (Admin → Settings → Maps, migration 0200),
 * with everything outside it (the database, the providers, the clock)
 * passed in, so it is tested without a network.
 *
 *   GET ?action=profile&role=rider&device=android
 *       → { profile: { tiles: { light, dark, satellite, traffic }, search, reverse, routing, distance,
 *                      direct: { nominatim, osrm } } }
 *         A tile slot is null to keep the app's own; traffic { off: true } for none,
 *         { google: true } for Google's own traffic on its JavaScript map (web).
 *         A google_js slot is { engine: "google_js", key, mapType } instead of tiles.
 *   GET ?action=search&provider=here&role=…&device=…&q=…[&lat=&lng=][&countries=my][&lang=en]
 *       → { places: [{ name, address, lat, lng }] }
 *   GET ?action=reverse&provider=…&role=…&device=…&lat=…&lng=…
 *       → { place: { name, address, lat, lng, country, state, city, suburb } | null }
 *   GET ?action=route&provider=…&role=…&device=…&points=lat,lng;lat,lng[;…]
 *       → { route: { distanceKm, durationMin, points: [[lat, lng], …] } | null }
 *   GET ?action=distance&provider=…&role=…&device=…&from=lat,lng&to=lat,lng;lat,lng[;…]
 *       → { distances: [km | null, …] }  road distance to each place search result (up to 10)
 *   GET ?action=locate&provider=…&role=…&device=…&q=…[&lat=&lng=]  as search, by the profile's
 *       locate list and never Autocomplete: where a suggestion is (migration 0208); counted as search
 *   Google's place search, routes and distances use the newer API, the older one, or the newer then the
 *   older when it refuses, as map_config.googleApi says ("new" | "old" | "new_old").
 *   Amazon Location (provider "amazon", tiles "amazon_js") is asked in map_config.amazonRegion
 *   ("ap-southeast-5" Malaysia or "ap-southeast-1" Singapore), where it answers with GrabMaps
 *   data; an amazon_js slot is { engine: "maplibre", style, key } instead of tiles.
 *   Google place search is Text Search, or Autocomplete when map_config.googleSearch is
 *   "autocomplete" (migration 0207): its places then have { id, types, km } and no position
 *   (lat, lng null), and the app asks for the one picked, with the same &session=:
 *   GET ?action=details&provider=google&role=…&device=…&id=<place id>&session=…
 *       → { place: { name, address, lat, lng, types } | null }
 *   GET ?action=validate&role=…&device=…&address=…  (smart address C, map_config.smartAddress
 *       "c" or "all": Google's Address Validation)
 *       → { checked: { address, lat, lng, complete } | null }
 *   GET ?action=expand&url=https://maps.app.goo.gl/…
 *       → { url: "https://www.google.com/maps/place/…" }  a share link pasted into place
 *         search, followed only through Google's own hosts (at most 6 hops)
 *   GET ?action=fallbacks
 *       → { slots: ["google_tiles", …] }  the key slots with a secret synced from GitHub
 *         (names only, never a key), so Admin → Settings → Maps doesn't call them missing.
 *
 * A provider is only asked for a role and device whose profile lists it.
 * 429 { error: "rate_limited" } past the per-address limit, or the per-user one.
 * 401 { error: "sign_in_required" }: search, locate, reverse, route, distance,
 * details and validate spend a provider key, so they need a signed-in user
 * (profile's tiles and expand don't).
 */
import {
  addressValidationRequest,
  amazonRegionOf,
  cacheKey,
  cacheSeconds,
  DIRECT,
  distanceRequest,
  FALLBACK_SECRETS,
  googleAutocompleteRequest,
  googleDetailsRequest,
  googleDirectionsRequest,
  googleDistanceMatrixRequest,
  googleLegacyAutocompleteRequest,
  googleLegacyDetailsRequest,
  googleLegacyRefusal,
  googleLegacySearchRequest,
  googleLookOf,
  type GoogleLook,
  googleSessionBody,
  type HttpRequest,
  isGoogleMapsHost,
  isShortMapLink,
  nextMapHop,
  isDevice,
  isRole,
  type Kind,
  keySlot,
  parseAddressValidation,
  parseAutocomplete,
  parseDetails,
  parseDistances,
  parseReverse,
  parseRoute,
  parseSearch,
  profileOf,
  resolveKey,
  reverseRequest,
  routeRequest,
  searchRequest,
  sessionToken,
  type TileSource,
  tileSource,
  trafficTileUrl,
} from "./geo.ts";

export interface GeoDeps {
  /** map_config and api_providers from app_settings. */
  settings(): Promise<{ config: unknown; apiProviders: unknown }>;
  /** One provider request; the parsed JSON body, or throws. */
  call(req: HttpRequest): Promise<unknown>;
  /** Counts a call against [bucket]'s minute; false when over [limit] or when it can't be counted. */
  take(bucket: string, limit: number): Promise<boolean>;
  /**
   * The signed-in caller's user id, or null (the anon key, a bad token).
   * Asked only by the actions that spend a provider key.
   */
  caller(): Promise<string | null>;
  /** One call counted; a failed one with [detail], what went wrong, for Admin → Maps → Usage. */
  count(provider: string, kind: Kind | "tiles", ok: boolean, cached: boolean, detail?: string): Promise<void>;
  cacheGet(key: string): Promise<unknown | null>;
  cachePut(key: string, value: unknown, seconds: number): Promise<void>;
  /** A Google Map Tiles session for [slot] as [look] has it, reused until near its expiry. */
  googleSession(
    slot: "light" | "dark" | "satellite",
    key: string,
    region: string,
    look: GoogleLook,
  ): Promise<string | null>;
  /** ISO alpha-2 → alpha-3 ("my" → "MYS"), or null. */
  iso3(cc: string): string | null;
  /** The function's own secret for a key slot, when Admin → API Keys has none. */
  fallbackKey?(slot: string): string | null;
  /** Where [url] redirects to (its Location), without following it; null when it doesn't. */
  redirect?(url: string): Promise<string | null>;
}

/** Proxied lookups per caller address per minute. */
export const RATE_LIMIT = 120;
/** Keyed lookups per signed-in user per minute: typing a search asks a few times a second at most. */
export const USER_RATE_LIMIT = 60;

export interface GeoAnswer {
  status: number;
  body: unknown;
}

const bad = (error: string, status = 400): GeoAnswer => ({ status, body: { error } });

/**
 * Whether a keyed lookup may go ahead: a signed-in user under their own
 * limit, and their address under its own. The app falls back to
 * OpenStreetMap when it is refused, so a page open without a sign-in (the
 * shared ride) still finds its way.
 */
async function mayLookUp(deps: GeoDeps, ip: string): Promise<GeoAnswer | null> {
  const uid = await deps.caller().catch(() => null);
  if (!uid) return bad("sign_in_required", 401);
  if (!(await deps.take(`user:${uid}`, USER_RATE_LIMIT))) return bad("rate_limited", 429);
  if (!(await deps.take(`ip:${ip}`, RATE_LIMIT))) return bad("rate_limited", 429);
  return null;
}

function coord(v: string | null, max: number): number | null {
  if (v == null || v.trim() === "") return null;
  const n = Number(v);
  return Number.isFinite(n) && Math.abs(n) <= max ? n : null;
}

/** Google place search as Text Search ("text", the default) or Autocomplete. */
export function googleSearchOf(config: unknown): "text" | "autocomplete" {
  return (config as { googleSearch?: unknown } | null)?.googleSearch === "autocomplete" ? "autocomplete" : "text";
}

/** The smart address option: "normal", "a", "b", "c" or "all" (A, B and C). */
export function smartAddressOf(config: unknown): "normal" | "a" | "b" | "c" | "all" {
  const v = (config as { smartAddress?: unknown } | null)?.smartAddress;
  return v === "a" || v === "b" || v === "c" || v === "all" ? v : "normal";
}

/** Which Google API answers place search and routes: "new", "old" or "new_old" (the default). */
export function googleApiOf(config: unknown): "new" | "old" | "new_old" {
  const v = (config as { googleApi?: unknown } | null)?.googleApi;
  return v === "new" || v === "old" ? v : "new_old";
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
  if (action === "expand") {
    const url = (params.get("url") ?? "").trim();
    if (!isShortMapLink(url) || !deps.redirect) return bad("Not a Google Maps share link.");
    if (!(await deps.take(`ip:${ip}`, RATE_LIMIT))) return bad("rate_limited", 429);
    let at = url;
    for (let hop = 0; hop < 6; hop++) {
      const location = await deps.redirect(at).catch(() => null);
      if (!location) break;
      const next = nextMapHop(location, at);
      if (!next) return bad("That link leads outside Google Maps.", 422);
      at = next;
    }
    if (!isGoogleMapsHost(new URL(at).hostname)) return bad("That link did not open a place.", 422);
    return { status: 200, body: { url: at } };
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
  const amazonRegion = amazonRegionOf(config);
  const look = googleLookOf(config);

  if (action === "profile") {
    // Why a set map slot fell back to the app's own (Admin → Maps → Test shows it; the app ignores it).
    const refused: Record<string, string> = {};
    const tile = async (slot: "light" | "dark" | "satellite"): Promise<TileSource | null> => {
      const provider = profile.tiles[slot];
      if (provider === "app") return null;
      const k = key(provider, "tiles");
      let session: string | null = null;
      if (provider === "google" && k) {
        session = await deps.googleSession(slot, k, countries[0] ?? "my", look).catch((e) => {
          refused[slot] = e instanceof Error ? e.message : "Google refused the tile session";
          return null;
        });
      }
      const source = tileSource(provider, slot, k, session, amazonRegion, look);
      if (!source && !refused[slot]) refused[slot] = k ? "Not answered" : "No key";
      return source;
    };
    const t = profile.tiles.traffic;
    let traffic: unknown = null;
    if (t === "none") {
      traffic = { off: true };
    } else if (t === "google") {
      traffic = { google: true };
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
          refused,
          search: profile.search,
          reverse: profile.reverse,
          routing: profile.routing,
          distance: profile.distance,
          locate: profile.locate,
          googleSearch: googleSearchOf(config),
          smartAddress: smartAddressOf(config),
          direct: {
            nominatim: directUrl(apiProviders, keys.nominatim),
            osrm: directUrl(apiProviders, keys.osrm),
          },
        },
      },
    };
  }

  // Google: the newer request, the older one, or the newer then the older, as for search.
  const askGoogle = async (newer: HttpRequest, older: HttpRequest | null) => {
    const api = googleApiOf(config);
    const order = api === "old" && older ? [older] : api === "new" || !older ? [newer] : [newer, older];
    let error: unknown = null;
    for (const r of order) {
      try {
        const body = await deps.call(r);
        const refused = googleLegacyRefusal(body);
        if (refused) throw new Error(refused);
        return body;
      } catch (e) {
        error = e;
      }
    }
    throw error;
  };

  if (action === "details") {
    if (!profile.search.includes("google")) return bad("That provider is not set for this profile.", 403);
    const id = (params.get("id") ?? "").trim();
    if (!/^[A-Za-z0-9_-]{10,300}$/.test(id)) return bad("Give id.");
    const k = key("google", "search");
    if (!k) return bad("No key for that provider.", 503);
    const refusal = await mayLookUp(deps, ip);
    if (refusal) return refusal;
    const session = sessionToken(params.get("session"));
    try {
      const body = await askGoogle(
        googleDetailsRequest(id, lang, k, session),
        googleLegacyDetailsRequest(id, lang, k, session),
      );
      const place = parseDetails(body);
      await deps.count("google", "search", place != null, false, place ? undefined : "Place details: no place for that id")
        .catch(() => {});
      return { status: 200, body: { place } };
    } catch (e) {
      await deps.count("google", "search", false, false, `Place details: ${errorDetail(e)}`).catch(() => {});
      return bad("The provider did not answer.", 502);
    }
  }

  if (action === "validate") {
    const smart = smartAddressOf(config);
    if (smart !== "c" && smart !== "all") return bad("Address checking is off.", 403);
    const address = (params.get("address") ?? "").trim().slice(0, 200);
    if (address.length < 5) return bad("Give address.");
    const k = resolveKey(apiProviders, keys.google_address) ?? deps.fallbackKey?.("google_address") ?? null;
    if (!k) return bad("No key for that provider.", 503);
    const refusal = await mayLookUp(deps, ip);
    if (refusal) return refusal;
    try {
      const body = await deps.call(addressValidationRequest(address, countries[0] ?? "my", k));
      const checked = parseAddressValidation(body);
      await deps.count("google", "search", checked != null, false, checked ? undefined : "Address check: no answer")
        .catch(() => {});
      return { status: 200, body: { checked } };
    } catch (e) {
      await deps.count("google", "search", false, false, `Address check: ${errorDetail(e)}`).catch(() => {});
      return bad("The provider did not answer.", 502);
    }
  }

  const kinds: Record<string, Kind> = {
    search: "search",
    locate: "search",
    reverse: "reverse",
    route: "routing",
    distance: "distance",
  };
  const kind: Kind | null = kinds[action] ?? null;
  if (!kind) return bad("Unknown action.");
  const locate = action === "locate";
  const provider = params.get("provider") ?? "";
  if (DIRECT.has(provider) || !(locate ? profile.locate : profile[kind]).includes(provider)) {
    return bad("That provider is not set for this profile.", 403);
  }
  const k = key(provider, kind);
  if (!k) return bad("No key for that provider.", 503);
  const refusal = await mayLookUp(deps, ip);
  if (refusal) return refusal;

  // Google: the newer API, the older one, or the newer first and the older
  // when it refuses (Admin → Settings → Maps, migration 0203).
  let req: HttpRequest | null = null;
  let older: HttpRequest | null = null;
  let ck = "";
  let parse: (body: unknown) => unknown;
  if (kind === "search") {
    const q = (params.get("q") ?? "").trim().slice(0, 120);
    if (q.length < 3) return { status: 200, body: { places: [] } };
    const lat = coord(params.get("lat"), 90) ?? undefined, lng = coord(params.get("lng"), 180) ?? undefined;
    const sp = {
      q,
      lat,
      lng,
      countries,
      countries3: countries.map((c) => deps.iso3(c)).filter((c): c is string => !!c),
      lang,
      amazonRegion,
    };
    req = searchRequest(provider, sp, k);
    if (provider === "google") older = googleLegacySearchRequest(sp, k);
    const autocomplete = !locate && provider === "google" && googleSearchOf(config) === "autocomplete";
    if (autocomplete) {
      const session = sessionToken(params.get("session"));
      req = googleAutocompleteRequest(sp, k, session);
      older = googleLegacyAutocompleteRequest(sp, k, session);
    }
    // Near the same ~1 km, the same answer.
    ck = cacheKey(provider, kind, [q, lat == null ? "" : lat.toFixed(2), lng == null ? "" : lng.toFixed(2), countries.join(","), lang]);
    parse = (b) => ({ places: autocomplete ? parseAutocomplete(b) : parseSearch(provider, b) });
  } else if (kind === "reverse") {
    const lat = coord(params.get("lat"), 90), lng = coord(params.get("lng"), 180);
    if (lat == null || lng == null) return bad("Give lat and lng.");
    req = reverseRequest(provider, lat, lng, lang, k, amazonRegion);
    ck = cacheKey(provider, kind, [lat, lng, lang]);
    parse = (b) => ({ place: parseReverse(provider, b, lat, lng) });
  } else if (kind === "distance") {
    const point = (p: string) => {
      const [a, b] = p.split(",");
      const la = coord(a, 90), ln = coord(b, 180);
      return la == null || ln == null ? null : [la, ln] as [number, number];
    };
    const from = point(params.get("from") ?? "");
    const to = (params.get("to") ?? "").split(";").filter((p) => p.trim() !== "").slice(0, 10).map(point);
    if (!from || !to.length || to.some((p) => p == null)) return bad("Give from=lat,lng and to=lat,lng;lat,lng.");
    const dest = to as [number, number][];
    req = distanceRequest(provider, from, dest, k, amazonRegion);
    if (provider === "google") older = googleDistanceMatrixRequest(from, dest, k);
    // The user's own spot to ~100 m; the places as given.
    ck = cacheKey(provider, kind, [from[0].toFixed(3), from[1].toFixed(3), ...dest.flat()]);
    parse = (b) => {
      const distances = parseDistances(provider, b, dest.length);
      if (!distances) throw new Error("not a matrix");
      return { distances };
    };
  } else {
    const points = (params.get("points") ?? "").split(";").slice(0, 12).map((p) => {
      const [a, b] = p.split(",");
      const la = coord(a, 90), ln = coord(b, 180);
      return la == null || ln == null ? null : [la, ln] as [number, number];
    });
    if (points.length < 2 || points.some((p) => p == null)) return bad("Give points=lat,lng;lat,lng.");
    req = routeRequest(provider, points as [number, number][], k, amazonRegion);
    if (provider === "google") older = googleDirectionsRequest(points as [number, number][], k);
    ck = cacheKey(provider, kind, (points as [number, number][]).flat());
    parse = (b) => ({ route: parseRoute(provider, b) });
  }
  const googleApi = googleApiOf(config);
  if (older && googleApi === "old") [req, older] = [older, null];
  if (googleApi === "new") older = null;
  if (!req) return bad("That provider can't do this.", 400);

  const ttl = cacheSeconds(provider, kind);
  if (ttl > 0) {
    const hit = await deps.cacheGet(ck).catch(() => null);
    if (hit != null) {
      await deps.count(provider, kind, true, true).catch(() => {});
      return { status: 200, body: hit };
    }
  }
  const ask = async (r: HttpRequest) => {
    const body = await deps.call(r);
    const refused = googleLegacyRefusal(body);
    if (refused) throw new Error(refused);
    return body;
  };
  try {
    let body: unknown;
    try {
      body = await ask(req);
    } catch (e) {
      if (!older) throw e;
      try {
        body = await ask(older);
      } catch (e2) {
        throw new Error(`${errorDetail(e)}; then the older API: ${errorDetail(e2)}`);
      }
    }
    const answer = parse(body) as Record<string, unknown>;
    const list = answer.places ?? answer.distances;
    const empty = Array.isArray(list)
      ? (answer.distances ? list.every((d) => d == null) : list.length === 0)
      : Object.values(answer)[0] == null;
    await deps.count(provider, kind, !empty, false, empty ? "Answered, but found nothing" : undefined).catch(() => {});
    if (ttl > 0 && !empty) await deps.cachePut(ck, answer, ttl).catch(() => {});
    return { status: 200, body: answer };
  } catch (e) {
    await deps.count(provider, kind, false, false, errorDetail(e)).catch(() => {});
    return bad("The provider did not answer.", 502);
  }
}

/** What went wrong, short (the request's own errors never carry the key). */
export function errorDetail(e: unknown): string {
  const m = e instanceof Error ? e.message : String(e ?? "");
  if (/timed? ?out|TimeoutError|aborted/i.test(m) || (e instanceof Error && e.name === "TimeoutError")) {
    return "No answer within 8 s";
  }
  return (m || "Failed").slice(0, 300);
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
