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
 * Each also as a POST with the same parameters in a JSON body ([geoParams]), which the
 * app sends: one URL, so a browser asks its CORS preflight once and keeps it (PERF-74).
 *
 * provider "nas" is the office NAS (migration 0319, geo_nas.ts): asked through its tunnel with
 * the secret header, waiting at most its timeoutMs; 503 at once while it is offline, 403 where
 * the admin's rules switch that part off, 502 when it is slower than its timeout. The profile
 * leaves it out while it is off. A "nas" map slot is { engine: "maplibre", style, key: "",
 * keyless: true }.
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
  googleMapType,
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
import {
  isTimeout,
  NAS,
  nasDistanceRequest,
  type NasLink,
  nasPart,
  nasReverseRequest,
  nasRouteRequest,
  nasSearchRequest,
  nasTileSource,
  parseNasDistances,
  parseNasReverse,
  parseNasRoute,
  parseNasSearch,
  profileUsesNas,
  withNas,
} from "./geo_nas.ts";

export interface GeoDeps {
  /** map_config and api_providers from app_settings. */
  settings(): Promise<{ config: unknown; apiProviders: unknown }>;
  /** One provider request; the parsed JSON body, or throws. */
  call(req: HttpRequest): Promise<unknown>;
  /** Counts a call against [bucket]'s minute; false when over [limit] or when it can't be counted. */
  take(bucket: string, limit: number): Promise<boolean>;
  /**
   * Both of a keyed lookup's buckets in one round trip (geo_take2, migration 0235): which one
   * refused, or null when both allow it; refuses when it can't be counted. Without it, two [take]s.
   */
  takePair?(userBucket: string, userLimit: number, ipBucket: string, ipLimit: number): Promise<"user" | "ip" | null>;
  /**
   * The signed-in caller's user id, or null (the anon key, a bad token).
   * Asked only by the actions that spend a provider key.
   */
  caller(): Promise<string | null>;
  /**
   * One call counted; a failed one with [detail], what went wrong, for Admin → Maps → Usage.
   * Never awaited: it finishes after the answer is sent ([background]).
   */
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
  /** Google tile sessions refused lately, kept per function instance (see [RefusedSessions]). */
  refusedSessions?: RefusedSessions;
  /**
   * The office NAS (migration 0319): where it is, whether it is up, and which
   * parts are on at [point] (the Default rule when null); null when none is
   * paired. Asked only when a profile names it.
   */
  nas?(point: [number, number] | null): Promise<NasLink | null>;
  /** One call to the NAS counted for Admin → Office NAS → Maps (nas_maps_count). Never awaited. */
  nasCount?(kind: Kind, ok: boolean, ms: number, timedOut: boolean): Promise<void>;
  /**
   * Keeps [p] (a count, a cache write) running after the answer is sent, as
   * EdgeRuntime.waitUntil does; [p] never rejects. Without it, [p] is left to finish alone.
   */
  background?(p: Promise<unknown>): void;
}

/**
 * Google tile sessions Google refused lately (403 PERMISSION_DENIED,
 * SERVICE_DISABLED …), by slot, map type, region and key, for [ms] (10
 * minutes): a profile asked meanwhile answers with the app's own map at
 * once, giving the same reason, instead of waiting on Google to refuse
 * again. In memory per function instance; nothing of Google's is kept.
 */
export class RefusedSessions {
  constructor(readonly ms = 10 * 60_000, private readonly now: () => number = Date.now) {}
  private readonly refused = new Map<string, { reason: string; at: number }>();

  static id(slot: "light" | "dark" | "satellite", key: string, region: string, look: GoogleLook): string {
    return `${slot}:${googleMapType(slot, look)}:${region}:${key}`;
  }

  /** Why [id] was refused, while that is under [ms] old; else null. */
  reason(id: string): string | null {
    const r = this.refused.get(id);
    if (!r) return null;
    if (this.now() - r.at < this.ms) return r.reason;
    this.refused.delete(id);
    return null;
  }

  remember(id: string, reason: string): void {
    // A handful of slots × looks × regions; drop the stale ones as new arrive.
    for (const [k, r] of this.refused) if (this.now() - r.at >= this.ms) this.refused.delete(k);
    this.refused.set(id, { reason, at: this.now() });
  }
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

/** The actions that spend a provider key, and so need a signed-in user. */
const KEYED = new Set(["details", "validate", "search", "locate", "reverse", "route", "distance"]);

/**
 * Whether a keyed lookup may go ahead: a signed-in user ([caller], asked
 * when the request came in) under their own limit, and their address under
 * its own, both in one round trip when [GeoDeps.takePair] is there. The app
 * falls back to OpenStreetMap when it is refused, so a page open without a
 * sign-in (the shared ride) still finds its way.
 */
async function mayLookUp(deps: GeoDeps, ip: string, caller: Promise<string | null>): Promise<GeoAnswer | null> {
  const uid = await caller;
  if (!uid) return bad("sign_in_required", 401);
  if (deps.takePair) {
    // Fails closed: a limit that can't be counted refuses.
    const refused = await deps.takePair(`user:${uid}`, USER_RATE_LIMIT, `ip:${ip}`, RATE_LIMIT)
      .catch(() => "user" as const);
    return refused ? bad("rate_limited", 429) : null;
  }
  if (!(await deps.take(`user:${uid}`, USER_RATE_LIMIT))) return bad("rate_limited", 429);
  if (!(await deps.take(`ip:${ip}`, RATE_LIMIT))) return bad("rate_limited", 429);
  return null;
}

/** A database RPC as supabase-js answers it. */
export type Rpc = (
  fn: string,
  args: Record<string, unknown>,
) => PromiseLike<{ data: unknown; error: { code?: string; message?: string } | null }>;

/** Whether [error] says the function isn't there (PostgREST's PGRST202, Postgres' 42883). */
export function isMissingFunction(error: { code?: string; message?: string } | null): boolean {
  if (!error) return false;
  return error.code === "PGRST202" || error.code === "42883" ||
    /could not find the function|function .* does not exist/i.test(error.message ?? "");
}

/**
 * [GeoDeps.take] and [GeoDeps.takePair] over the database: geo_take2
 * (migration 0235) for both buckets in one round trip, or two geo_take calls
 * while that migration is not run, so the function can be deployed first.
 * A missing geo_take2 is not asked again for [retryMs]. Both fail closed: a
 * limit that can't be counted refuses.
 */
export function rateTakers(rpc: Rpc, retryMs = 10 * 60_000, now: () => number = Date.now) {
  let missingAt = Number.NEGATIVE_INFINITY;
  const take = async (bucket: string, limit: number): Promise<boolean> => {
    try {
      const { data, error } = await rpc("geo_take", { p_bucket: bucket, p_limit: limit });
      return !error && data === true;
    } catch {
      return false;
    }
  };
  const takePair = async (
    userBucket: string,
    userLimit: number,
    ipBucket: string,
    ipLimit: number,
  ): Promise<"user" | "ip" | null> => {
    if (now() - missingAt >= retryMs) {
      try {
        const { data, error } = await rpc("geo_take2", {
          p_user_bucket: userBucket,
          p_user_limit: userLimit,
          p_ip_bucket: ipBucket,
          p_ip_limit: ipLimit,
        });
        if (!error) return data === null ? null : data === "ip" ? "ip" : "user";
        if (!isMissingFunction(error)) return "user";
        missingAt = now();
      } catch {
        return "user";
      }
    }
    if (!(await take(userBucket, userLimit))) return "user";
    return (await take(ipBucket, ipLimit)) ? null : "ip";
  };
  return { take, takePair };
}

/**
 * The request's parameters: its query string, and on a POST the fields of
 * its JSON body (strings, numbers, booleans) over them. The app POSTs to the
 * function's bare URL so a browser's CORS preflight is asked once and kept,
 * not once per query (PERF-74); a GET with a query string still works. Null
 * when a POST's body is not a JSON object.
 */
export async function geoParams(req: Request): Promise<URLSearchParams | null> {
  const params = new URL(req.url).searchParams;
  if (req.method !== "POST") return params;
  const text = await req.text().catch(() => null);
  if (text == null || text.length > 16_384) return null;
  if (text.trim() === "") return params;
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    return null;
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) return null;
  for (const [k, v] of Object.entries(body)) {
    if (typeof v === "string" || typeof v === "number" || typeof v === "boolean") params.set(k, String(v));
  }
  return params;
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
  // Counts and cache writes go on after the answer is sent.
  const later = (p: Promise<unknown>) => {
    const settled = p.catch(() => {});
    deps.background?.(settled);
  };
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

  // Who is asking and the settings at once (PERF-73): only the rate limit waits on the user.
  const caller = KEYED.has(action) ? deps.caller().catch(() => null) : Promise.resolve(null);
  const { config, apiProviders } = await deps.settings();
  let profile = profileOf(config, role, device);
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
    const why: Partial<Record<"light" | "dark" | "satellite", string>> = {};
    // The office NAS only while it is on (migration 0319); asked only when the profile names it.
    let nas: NasLink | null = null;
    if (profileUsesNas(profile)) {
      nas = await (deps.nas?.(null) ?? Promise.resolve(null)).catch(() => null);
      for (const slot of ["light", "dark"] as const) {
        if (profile.tiles[slot] === NAS && !nas?.tiles) why[slot] = nas?.online ? "The NAS map is off" : "The office NAS is offline";
      }
      profile = withNas(profile, nas);
    }
    const tile = async (slot: "light" | "dark" | "satellite"): Promise<TileSource | null> => {
      const provider = profile.tiles[slot];
      if (provider === NAS) return nasTileSource(slot, nas);
      if (provider === "app") return null;
      const k = key(provider, "tiles");
      let session: string | null = null;
      if (provider === "google" && k) {
        const region = countries[0] ?? "my";
        const id = RefusedSessions.id(slot, k, region, look);
        const known = deps.refusedSessions?.reason(id);
        if (known) {
          // Refused moments ago: don't wait on Google to refuse again.
          why[slot] = known;
        } else {
          session = await deps.googleSession(slot, k, region, look).catch((e) => {
            why[slot] = e instanceof Error ? e.message : "Google refused the tile session";
            deps.refusedSessions?.remember(id, why[slot]!);
            return null;
          });
        }
      }
      const source = tileSource(provider, slot, k, session, amazonRegion, look);
      if (!source && !why[slot]) why[slot] = k ? "Not answered" : "No key";
      return source;
    };
    // The three slots at once: a refused Google session costs one round trip, not three.
    const [light, dark, satellite] = await Promise.all([tile("light"), tile("dark"), tile("satellite")]);
    // In slot order, as when they were asked one after another.
    const refused: Record<string, string> = {};
    for (const slot of ["light", "dark", "satellite"] as const) if (why[slot]) refused[slot] = why[slot]!;
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
          tiles: { light, dark, satellite, traffic },
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
    const refusal = await mayLookUp(deps, ip, caller);
    if (refusal) return refusal;
    const session = sessionToken(params.get("session"));
    try {
      const body = await askGoogle(
        googleDetailsRequest(id, lang, k, session),
        googleLegacyDetailsRequest(id, lang, k, session),
      );
      const place = parseDetails(body);
      later(
        deps.count("google", "search", place != null, false, place ? undefined : "Place details: no place for that id"),
      );
      return { status: 200, body: { place } };
    } catch (e) {
      later(deps.count("google", "search", false, false, `Place details: ${errorDetail(e)}`));
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
    const refusal = await mayLookUp(deps, ip, caller);
    if (refusal) return refusal;
    try {
      const body = await deps.call(addressValidationRequest(address, countries[0] ?? "my", k));
      const checked = parseAddressValidation(body);
      later(deps.count("google", "search", checked != null, false, checked ? undefined : "Address check: no answer"));
      return { status: 200, body: { checked } };
    } catch (e) {
      later(deps.count("google", "search", false, false, `Address check: ${errorDetail(e)}`));
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
  if (provider === NAS) {
    const refusal = await mayLookUp(deps, ip, caller);
    if (refusal) return refusal;
    return await askNas(kind, params, lang, deps, later);
  }
  const k = key(provider, kind);
  if (!k) return bad("No key for that provider.", 503);
  const refusal = await mayLookUp(deps, ip, caller);
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
    // The same ~11 m, the same answer: GPS jitter of a few metres between
    // fixes would otherwise miss the cache on every call.
    ck = cacheKey(provider, kind, [lat.toFixed(4), lng.toFixed(4), lang]);
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
      later(deps.count(provider, kind, true, true));
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
    later(deps.count(provider, kind, !empty, false, empty ? "Answered, but found nothing" : undefined));
    if (ttl > 0 && !empty) later(deps.cachePut(ck, answer, ttl));
    return { status: 200, body: answer };
  } catch (e) {
    later(deps.count(provider, kind, false, false, errorDetail(e)));
    return bad("The provider did not answer.", 502);
  }
}

/** "lat,lng;lat,lng" → points, or null when one isn't a point. */
function pointList(v: string | null, max: number): [number, number][] | null {
  const out: [number, number][] = [];
  for (const p of (v ?? "").split(";").filter((x) => x.trim() !== "").slice(0, max)) {
    const [a, b] = p.split(",");
    const la = coord(a, 90), ln = coord(b, 180);
    if (la == null || ln == null) return null;
    out.push([la, ln]);
  }
  return out;
}

/**
 * One lookup on the office NAS (migration 0319): the rule where it is asked
 * (the first point), its own timeout, and its answer as any provider's.
 * Counted under provider "nas" in Admin → Maps → Usage, and for Admin →
 * Office NAS → Maps (served instead of a paid provider, failed, timed out).
 */
async function askNas(
  kind: Kind,
  params: URLSearchParams,
  lang: string,
  deps: GeoDeps,
  later: (p: Promise<unknown>) => void,
): Promise<GeoAnswer> {
  let point: [number, number] | null = null;
  let req: (link: NasLink) => HttpRequest;
  let parse: (body: unknown) => Record<string, unknown>;
  if (kind === "search") {
    const q = (params.get("q") ?? "").trim().slice(0, 120);
    if (q.length < 3) return { status: 200, body: { places: [] } };
    const lat = coord(params.get("lat"), 90), lng = coord(params.get("lng"), 180);
    if (lat != null && lng != null) point = [lat, lng];
    req = (l) => nasSearchRequest(l, q, lang, lat ?? undefined, lng ?? undefined);
    parse = (b) => ({ places: parseNasSearch(b) });
  } else if (kind === "reverse") {
    const lat = coord(params.get("lat"), 90), lng = coord(params.get("lng"), 180);
    if (lat == null || lng == null) return bad("Give lat and lng.");
    point = [lat, lng];
    req = (l) => nasReverseRequest(l, lat, lng, lang);
    parse = (b) => ({ place: parseNasReverse(b, lat, lng) });
  } else if (kind === "distance") {
    const from = pointList(params.get("from"), 1)?.[0] ?? null;
    const to = pointList(params.get("to"), 10);
    if (!from || !to?.length) return bad("Give from=lat,lng and to=lat,lng;lat,lng.");
    point = from;
    req = (l) => nasDistanceRequest(l, from, to);
    parse = (b) => {
      const distances = parseNasDistances(b, to.length);
      if (!distances) throw new Error("not a table");
      return { distances };
    };
  } else {
    const points = pointList(params.get("points"), 12);
    if (!points || points.length < 2) return bad("Give points=lat,lng;lat,lng.");
    point = points[0];
    req = (l) => nasRouteRequest(l, points);
    parse = (b) => ({ route: parseNasRoute(b) });
  }

  const link = await (deps.nas?.(point) ?? Promise.resolve(null)).catch(() => null);
  if (!link?.online) {
    later(deps.count(NAS, kind, false, false, link ? "The office NAS is offline" : "No office NAS is connected"));
    return bad("The office NAS is offline.", 503);
  }
  if (!link[nasPart(kind)]) return bad("The office NAS is off here.", 403);

  const started = Date.now();
  try {
    const answer = parse(await deps.call(req(link)));
    const ms = Date.now() - started;
    const list = answer.places ?? answer.distances;
    const empty = Array.isArray(list)
      ? (answer.distances ? list.every((d) => d == null) : list.length === 0)
      : Object.values(answer)[0] == null;
    later(deps.count(NAS, kind, !empty, false, empty ? "Answered, but found nothing" : undefined));
    if (deps.nasCount) later(deps.nasCount(kind, !empty, ms, false));
    return { status: 200, body: answer };
  } catch (e) {
    const timedOut = isTimeout(e);
    const detail = timedOut ? `No answer within ${(link.timeoutMs / 1000).toFixed(1)} s` : errorDetail(e);
    later(deps.count(NAS, kind, false, false, detail));
    if (deps.nasCount) later(deps.nasCount(kind, false, Date.now() - started, timedOut));
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
