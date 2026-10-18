/**
 * Admin → Settings → Maps (migration 0200), the pure half of the `geo`
 * function: which tiles, place search, reverse geocoding and routing a
 * rider or partner gets on each kind of device, the provider's key for each,
 * and how each provider is asked and answered.
 *
 *   tiles     osm · google · mapbox · here · tomtom · maptiler (light, dark,
 *             satellite; esri for satellite), tomtom · here (traffic); on the
 *             web also google_js (Google's JavaScript map, drawn by the
 *             browser under the app's layers) and its google traffic; on
 *             Android and iOS google_native (Google's own map, the Maps SDK
 *             in the app, migration 0210), and google_js on desktop too;
 *             on iOS apple_native (Apple's own map, MapKit, 0214)
 *   search    nominatim · google · mapbox · here · tomtom · locationiq · maptiler · amazon
 *   reverse   the same
 *   routing   osrm · google · mapbox · here · tomtom · locationiq · amazon
 *   distance  the same, and straight (as the crow flies): each place search
 *             result's road distance from the user (migration 0205)
 *   locate    as search: where a Google Autocomplete suggestion is, roughly, so
 *             its road distance can be shown before it is picked (migration 0208)
 *
 * For search, reverse and locate the app asks OpenStreetMap (nominatim) last
 * when none of the set ones answers.
 *
 * 'app' (tiles) keeps what the app was built with. nominatim, osrm and straight are
 * called by the device itself (spread over every device's own address, as
 * OpenStreetMap's usage policy needs); the rest go through `geo`, which
 * holds the keys. Fetching is in geo/index.ts.
 *
 * amazon is Amazon Location Service (migration 0206): in its Malaysia and
 * Singapore regions it answers with GrabMaps data. Its map (amazon_js, web)
 * comes as vector tiles only, which the browser draws with MapLibre.
 */

/**
 * The key a caller's bearer token is remembered under (the `geo` function's
 * who-is-this cache): its SHA-256, hex. The token itself is never kept, so a
 * dump of the instance's memory holds no usable session.
 */
export async function tokenCacheKey(token: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

export const ROLES = ["rider", "partner"] as const;
export const DEVICES = ["android", "ios", "web", "desktop"] as const;
export type Role = (typeof ROLES)[number];
export type Device = (typeof DEVICES)[number];
export type Kind = "search" | "reverse" | "routing" | "distance";
export type TileSlot = "light" | "dark" | "satellite" | "traffic";

export interface Profile {
  tiles: Record<TileSlot, string>;
  search: string[];
  reverse: string[];
  routing: string[];
  distance: string[];
  locate: string[];
}

export interface MapConfig {
  profiles: Record<string, Profile>;
  keys: Record<string, string>;
}

/**
 * Providers the device calls itself (no key, OpenStreetMap's servers or the
 * admin's own), and straight, which it works out.
 */
export const DIRECT = new Set(["nominatim", "osrm", "straight"]);

const DEFAULT_PROFILE: Profile = {
  tiles: { light: "app", dark: "app", satellite: "app", traffic: "app" },
  search: ["nominatim"],
  reverse: ["nominatim"],
  routing: ["osrm"],
  distance: ["osrm"],
  locate: ["nominatim"],
};

/** [role].[device]'s profile in [config] (the stored one is already cleaned by the database). */
export function profileOf(config: unknown, role: string, device: string): Profile {
  const p = (config as MapConfig | null)?.profiles?.[`${role}.${device}`];
  if (!p || typeof p !== "object") return DEFAULT_PROFILE;
  const list = (v: unknown, d: string[]) => (Array.isArray(v) && v.length ? v.map(String) : d);
  return {
    tiles: { ...DEFAULT_PROFILE.tiles, ...(p.tiles ?? {}) },
    search: list(p.search, DEFAULT_PROFILE.search),
    reverse: list(p.reverse, DEFAULT_PROFILE.reverse),
    routing: list(p.routing, DEFAULT_PROFILE.routing),
    distance: list(p.distance, DEFAULT_PROFILE.distance),
    locate: list(p.locate, DEFAULT_PROFILE.locate),
  };
}

export function isRole(v: string): v is Role {
  return (ROLES as readonly string[]).includes(v);
}

export function isDevice(v: string): v is Device {
  return (DEVICES as readonly string[]).includes(v);
}

// ---- Keys ------------------------------------------------------------------------------------

/** The key slot in map_config.keys a provider uses for [use]. */
export function keySlot(provider: string, use: "tiles" | Kind): string {
  if (provider === "google_js") return "google_js";
  if (provider === "amazon_js") return "amazon_maps";
  if (provider !== "google") return provider;
  return {
    tiles: "google_tiles",
    search: "google_places",
    reverse: "google_geocoding",
    routing: "google_routes",
    distance: "google_routes",
  }[use];
}

interface KeyEntry {
  id?: string;
  value?: string;
  disabled?: boolean;
}

/**
 * The secret a reference names in Admin → API Keys (app_settings
 * 'api_providers'): "<provider>/<service>" takes the service's first active
 * key, "<provider>/<service>#<id>" that one key. Null when there is none.
 */
export function resolveKey(apiProviders: unknown, ref: string | undefined): string | null {
  if (!ref || !Array.isArray(apiProviders)) return null;
  const m = /^([a-z0-9_]+)\/([a-z0-9_]+)(?:#(.+))?$/.exec(ref);
  if (!m) return null;
  const [, providerId, serviceId, keyId] = m;
  const provider = apiProviders.find((p) => p?.id === providerId);
  const service = (provider?.services ?? []).find((s: { id?: string }) => s?.id === serviceId);
  const keys: KeyEntry[] = Array.isArray(service?.keys) ? service.keys : [];
  const usable = keys.filter((k) => k && k.disabled !== true && typeof k.value === "string" && k.value.trim() !== "");
  const key = keyId ? usable.find((k) => k.id === keyId) : usable[0];
  return key?.value?.trim() ?? null;
}

/**
 * The function's own secret for a key slot, used only when Admin → API Keys
 * has none for it: the Google keys kept as GitHub Actions secrets, copied to
 * the function by .github/workflows/sync-map-keys.yml. Routes use the Maps
 * key unless a Directions key is set.
 */
export const FALLBACK_SECRETS: Record<string, string[]> = {
  // A key of its own for Map Tiles API, else the Maps key.
  google_tiles: ["GOOGLE_MAP_TILES_API_KEY", "GOOGLE_MAP_API_KEY"],
  // A browser key, restricted to the site, for Google's JavaScript map.
  google_js: ["GOOGLE_MAPS_JS_API_KEY", "GOOGLE_MAP_API_KEY"],
  google_places: ["GOOGLE_PLACES_API_KEY"],
  google_address: ["GOOGLE_ADDRESS_VALIDATION_API_KEY", "GOOGLE_PLACES_API_KEY"],
  google_geocoding: ["GOOGLE_GEOCODING_API_KEY"],
  google_routes: ["GOOGLE_DIRECTIONS_API_KEY", "GOOGLE_MAP_API_KEY"],
};

/** The first fallback secret set for [slot], else null. */
export function fallbackKey(slot: string, env: (name: string) => string | undefined): string | null {
  for (const name of FALLBACK_SECRETS[slot] ?? []) {
    const v = env(name)?.trim();
    if (v) return v;
  }
  return null;
}

// ---- Amazon Location (GrabMaps) ------------------------------------------------------------

/** The regions Amazon Location serves GrabMaps from: Malaysia (default) and Singapore. */
export const AMAZON_REGIONS = ["ap-southeast-5", "ap-southeast-1"] as const;

/** map_config.amazonRegion, or Malaysia. */
export function amazonRegionOf(config: unknown): string {
  const v = (config as { amazonRegion?: unknown } | null)?.amazonRegion;
  return (AMAZON_REGIONS as readonly unknown[]).includes(v) ? v as string : AMAZON_REGIONS[0];
}

/** Its place search needs a point to rank by: the region's capital when the user's is unknown. */
const AMAZON_CENTRE: Record<string, [number, number]> = {
  "ap-southeast-5": [101.6869, 3.139],
  "ap-southeast-1": [103.8198, 1.3521],
};

const amazonHost = (api: "places" | "routes" | "maps", region: string) => `https://${api}.geo.${region}.amazonaws.com`;

/** The languages GrabMaps answers in; anything else gets English. */
const AMAZON_LANGS = new Set(["en", "id", "km", "lo", "ms", "my", "pt", "th", "tl", "vi", "zh"]);
const amazonLang = (lang: string) => {
  const l = lang.slice(0, 2).toLowerCase();
  return AMAZON_LANGS.has(l) ? l : "en";
};

const amazonPost = (
  api: "places" | "routes",
  region: string,
  path: string,
  key: string,
  body: unknown,
): HttpRequest => ({
  url: `${amazonHost(api, region)}/v2/${path}?key=${enc(key)}`,
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify(body),
});

// ---- Google Maps share links ---------------------------------------------------------------

/** Google's short and share link hosts (maps.app.goo.gl/AbC…), expanded for place search. */
const SHORT_HOSTS = new Set(["maps.app.goo.gl", "goo.gl", "share.google", "g.co"]);

/** www.google.com, maps.google.com, google.com.my … */
export function isGoogleMapsHost(host: string): boolean {
  return /^((www|maps)\.)?google\.[a-z]{2,3}(\.[a-z]{2})?$/.test(host.toLowerCase());
}

/** A Google Maps share link worth expanding: https, one of Google's short hosts. */
export function isShortMapLink(url: string): boolean {
  try {
    const u = new URL(url);
    if (u.protocol !== "https:" || !SHORT_HOSTS.has(u.hostname)) return false;
    return u.hostname !== "goo.gl" || u.pathname.startsWith("/maps");
  } catch {
    return false;
  }
}

/**
 * The next hop of a share link, when it stays on Google (short hosts, Maps,
 * or the cookie-consent page, whose `continue` is taken instead); null for
 * anywhere else, so `geo` never fetches a host it was not meant to.
 */
export function nextMapHop(location: string, from: string): string | null {
  let u: URL;
  try {
    u = new URL(location, from);
  } catch {
    return null;
  }
  if (u.protocol !== "https:") return null;
  if (u.hostname === "consent.google.com") {
    const cont = u.searchParams.get("continue");
    return cont ? nextMapHop(cont, from) : null;
  }
  return SHORT_HOSTS.has(u.hostname) || isGoogleMapsHost(u.hostname) ? u.toString() : null;
}

// ---- Tiles -----------------------------------------------------------------------------------

export interface TileSource {
  url: string;
  /** Darken on the device (OSM's tiles have no dark style). */
  darken: boolean;
  attribution: string;
  /**
   * "google_js": no tiles; the browser draws Google's JavaScript map with
   * [key], as [mapType] ("roadmap" | "satellite"), styled dark for 'dark'.
   * Older apps ignore it (no template) and keep their own tiles.
   */
  engine?: "google_js" | "google_native" | "apple_native" | "maplibre";
  key?: string;
  /** "hybrid" (satellite with roads and names) and "terrain" since migration 0211. */
  mapType?: GoogleMapType;
  /**
   * "maplibre": the MapLibre style the browser draws (Amazon's map, whose
   * tiles are vector only), with [key] added to each of its requests.
   */
  style?: string;
}

const ATTRIBUTION: Record<string, string> = {
  osm: "© OpenStreetMap contributors",
  esri: "Imagery © Esri",
  google: "Map data © Google",
  google_js: "Map data © Google",
  google_native: "Map data © Google",
  apple_native: "Apple Maps",
  google_xyz: "Map data © Google",
  mapbox: "© Mapbox © OpenStreetMap",
  here: "© HERE",
  tomtom: "© TomTom",
  maptiler: "© MapTiler © OpenStreetMap contributors",
  amazon_js: "© AWS, Grab, © OpenMapTiles, © OpenStreetMap contributors",
};

const enc = encodeURIComponent;

export type GoogleMapType = "roadmap" | "satellite" | "hybrid" | "terrain";

/**
 * How Google's map looks (migration 0211): satellite imagery alone or with
 * roads and names (hybrid), and the light map as the roadmap or terrain.
 */
export interface GoogleLook {
  satellite: "satellite" | "hybrid";
  map: "roadmap" | "terrain";
}

export const DEFAULT_LOOK: GoogleLook = { satellite: "satellite", map: "roadmap" };

export function googleLookOf(config: unknown): GoogleLook {
  const c = config as { googleSatellite?: unknown; googleMap?: unknown } | null;
  return {
    satellite: c?.googleSatellite === "hybrid" ? "hybrid" : "satellite",
    map: c?.googleMap === "terrain" ? "terrain" : "roadmap",
  };
}

/** [slot]'s Google map type: the dark map is always the (night) roadmap. */
export function googleMapType(slot: "light" | "dark" | "satellite", look: GoogleLook = DEFAULT_LOOK): GoogleMapType {
  if (slot === "satellite") return look.satellite;
  return slot === "light" ? look.map : "roadmap";
}

/**
 * The XYZ template for [provider]'s [slot] ('light' | 'dark' | 'satellite'),
 * with [key] in it (a map has to send it; restrict tile keys to the app in
 * the provider's console). [googleSession] is the Map Tiles API session for
 * that map type. Null when the provider has no such tiles or needs a key it
 * has not got.
 */
export function tileSource(
  provider: string,
  slot: "light" | "dark" | "satellite",
  key: string | null,
  googleSession?: string | null,
  amazonRegion: string = AMAZON_REGIONS[0],
  look: GoogleLook = DEFAULT_LOOK,
): TileSource | null {
  const a = ATTRIBUTION[provider] ?? "";
  const k = key ? enc(key) : "";
  // Google's own map in the phone app (migration 0210): the key is the one
  // the release build carries, so none is sent.
  if (provider === "google_native") {
    return { url: "", darken: false, attribution: a, engine: "google_native", mapType: googleMapType(slot, look) };
  }
  // Apple's own map in the iPhone app (migration 0214): no key. Apple has no
  // terrain map, so the light map is always its standard one.
  if (provider === "apple_native") {
    const mapType = slot === "satellite" ? look.satellite : "roadmap";
    return { url: "", darken: false, attribution: a, engine: "apple_native", mapType };
  }
  switch (provider) {
    case "osm":
      if (slot === "satellite") return null;
      return { url: "https://tile.openstreetmap.org/{z}/{x}/{y}.png", darken: slot === "dark", attribution: a };
    case "google_xyz": {
      // Google's own tile address, no key (migration 0211): for testing only,
      // as its terms allow tiles through the Maps APIs alone. The dark map is
      // the roadmap darkened on the device, as with OpenStreetMap.
      const lyrs = { roadmap: "m", terrain: "p", satellite: "s", hybrid: "y" }[googleMapType(slot, look)];
      return {
        url: `https://mt1.google.com/vt/lyrs=${lyrs}&x={x}&y={y}&z={z}`,
        darken: slot === "dark",
        attribution: a,
      };
    }
    case "esri":
      if (slot !== "satellite") return null;
      return {
        url: "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
        darken: false,
        attribution: a,
      };
  }
  if (!key) return null;
  switch (provider) {
    case "google_js":
      return {
        url: "",
        darken: false,
        attribution: a,
        engine: "google_js",
        key,
        mapType: googleMapType(slot, look),
      };
    case "amazon_js":
      if (slot === "satellite") return null;
      return {
        url: "",
        darken: false,
        attribution: a,
        engine: "maplibre",
        key,
        style: `${amazonHost("maps", amazonRegion)}/v2/styles/Standard/descriptor?color-scheme=` +
          (slot === "dark" ? "Dark" : "Light") + `&key=${k}`,
      };
    case "google":
      if (!googleSession) return null;
      return {
        url: `https://tile.googleapis.com/v1/2dtiles/{z}/{x}/{y}?session=${enc(googleSession)}&key=${k}`,
        darken: false,
        attribution: a,
      };
    case "mapbox": {
      const style = { light: "streets-v12", dark: "dark-v11", satellite: "satellite-streets-v12" }[slot];
      return {
        url: `https://api.mapbox.com/styles/v1/mapbox/${style}/tiles/256/{z}/{x}/{y}@2x?access_token=${k}`,
        darken: false,
        attribution: a,
      };
    }
    case "here": {
      const style = { light: "explore.day", dark: "explore.night", satellite: "satellite.day" }[slot];
      const format = slot === "satellite" ? "jpeg" : "png8";
      return {
        url: `https://maps.hereapi.com/v3/base/mc/{z}/{x}/{y}/${format}?style=${style}&size=256&apiKey=${k}`,
        darken: false,
        attribution: a,
      };
    }
    case "tomtom":
      return {
        url: slot === "satellite"
          ? `https://api.tomtom.com/map/1/tile/sat/main/{z}/{x}/{y}.jpg?key=${k}`
          : `https://api.tomtom.com/map/1/tile/basic/${slot === "dark" ? "night" : "main"}/{z}/{x}/{y}.png?key=${k}`,
        darken: false,
        attribution: a,
      };
    case "maptiler":
      return {
        url: slot === "satellite"
          ? `https://api.maptiler.com/maps/satellite/256/{z}/{x}/{y}@2x.jpg?key=${k}`
          : `https://api.maptiler.com/maps/${slot === "dark" ? "streets-v2-dark" : "streets-v2"}/256/{z}/{x}/{y}@2x.png?key=${k}`,
        darken: false,
        attribution: a,
      };
  }
  return null;
}

/** Live traffic overlay tiles (the same templates the build script uses). */
export function trafficTileUrl(provider: string, key: string | null): string | null {
  if (!key) return null;
  if (provider === "tomtom") {
    return `https://api.tomtom.com/traffic/map/4/tile/flow/relative0/{z}/{x}/{y}.png?key=${enc(key)}`;
  }
  if (provider === "here") return `https://traffic.maps.hereapi.com/v3/flow/mc/{z}/{x}/{y}/png?apiKey=${enc(key)}`;
  return null;
}

/** A dark style for Google's roadmap tiles (Map Tiles API session `styles`). */
export const GOOGLE_NIGHT_STYLES = [
  { stylers: [{ hue: "#242f3e" }, { invert_lightness: true }, { saturation: -30 }] },
  { featureType: "water", elementType: "geometry", stylers: [{ color: "#17263c" }] },
  { featureType: "road", elementType: "geometry", stylers: [{ color: "#38414e" }] },
  { elementType: "labels.text.fill", stylers: [{ color: "#9ca5b3" }] },
];

/**
 * The body to create a Google Map Tiles session for [slot]. Hybrid is the
 * satellite with the roadmap layer on it; terrain needs that layer too.
 */
export function googleSessionBody(
  slot: "light" | "dark" | "satellite",
  region: string,
  language = "en-US",
  look: GoogleLook = DEFAULT_LOOK,
) {
  const type = googleMapType(slot, look);
  return {
    mapType: type === "hybrid" ? "satellite" : type,
    language,
    region: region.toUpperCase(),
    ...(type === "hybrid" || type === "terrain" ? { layerTypes: ["layerRoadmap"] } : {}),
    ...(slot === "dark" ? { styles: GOOGLE_NIGHT_STYLES } : {}),
  };
}

// ---- Place search and reverse geocoding -----------------------------------------------------

export interface Place {
  name: string;
  address: string;
  lat: number;
  lng: number;
  /** Google's place types ("airport", "street_address" …), where it says. */
  types?: string[];
}

/**
 * One of Google's Autocomplete suggestions (migration 0207): no position
 * yet; the app asks `details` for it, with the same session, once picked.
 */
export interface Suggestion {
  name: string;
  address: string;
  lat: null;
  lng: null;
  /** Google's place id. */
  id: string;
  types: string[];
  /** As the crow flies from where the rider is, when Google says. */
  km: number | null;
}

export interface Area extends Place {
  country: string | null;
  state: string | null;
  city: string | null;
  suburb: string | null;
}

export interface HttpRequest {
  url: string;
  method?: "GET" | "POST";
  headers?: Record<string, string>;
  body?: string;
}

export interface SearchParams {
  q: string;
  lat?: number;
  lng?: number;
  /** ISO 3166 alpha-2, lower case ("my"). */
  countries: string[];
  /** The same countries as alpha-3 (HERE wants those). */
  countries3: string[];
  lang: string;
  /** Amazon Location's region (amazonRegionOf). */
  amazonRegion?: string;
}

const num = (v: unknown): number | null => {
  const n = typeof v === "number" ? v : typeof v === "string" ? Number(v) : NaN;
  return Number.isFinite(n) ? n : null;
};
const str = (v: unknown): string => (typeof v === "string" ? v.trim() : "");
const near = (p: { lat?: number; lng?: number }) => p.lat != null && p.lng != null;

export function searchRequest(provider: string, p: SearchParams, key: string): HttpRequest | null {
  const q = enc(p.q);
  const k = enc(key);
  const cc = p.countries.join(",");
  switch (provider) {
    case "google":
      return {
        url: "https://places.googleapis.com/v1/places:searchText",
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Goog-Api-Key": key,
          "X-Goog-FieldMask": "places.displayName,places.formattedAddress,places.location,places.types",
        },
        body: JSON.stringify({
          textQuery: p.q,
          maxResultCount: 8,
          languageCode: p.lang,
          ...(p.countries.length === 1 ? { regionCode: p.countries[0] } : {}),
          ...(near(p)
            ? { locationBias: { circle: { center: { latitude: p.lat, longitude: p.lng }, radius: 50000 } } }
            : {}),
        }),
      };
    case "mapbox":
      return {
        url: `https://api.mapbox.com/search/geocode/v6/forward?q=${q}&limit=8&language=${p.lang}` +
          (cc ? `&country=${cc}` : "") + (near(p) ? `&proximity=${p.lng},${p.lat}` : "") + `&access_token=${k}`,
      };
    case "here":
      return near(p)
        ? {
          url: `https://discover.search.hereapi.com/v1/discover?q=${q}&at=${p.lat},${p.lng}&limit=8&lang=${p.lang}` +
            (p.countries3.length ? `&in=countryCode:${p.countries3.join(",")}` : "") + `&apiKey=${k}`,
        }
        : {
          url: `https://geocode.search.hereapi.com/v1/geocode?q=${q}&limit=8&lang=${p.lang}` +
            (p.countries3.length ? `&in=countryCode:${p.countries3.join(",")}` : "") + `&apiKey=${k}`,
        };
    case "tomtom":
      return {
        url: `https://api.tomtom.com/search/2/search/${q}.json?limit=8&language=${p.lang}` +
          (cc ? `&countrySet=${cc.toUpperCase()}` : "") + (near(p) ? `&lat=${p.lat}&lon=${p.lng}` : "") + `&key=${k}`,
      };
    case "locationiq":
      return {
        url: `https://api.locationiq.com/v1/autocomplete?q=${q}&limit=8&accept-language=${p.lang}` +
          (cc ? `&countrycodes=${cc}` : "") +
          (near(p) ? `&viewbox=${p.lng! - 0.5},${p.lat! + 0.5},${p.lng! + 0.5},${p.lat! - 0.5}` : "") + `&key=${k}`,
      };
    case "maptiler":
      return {
        url: `https://api.maptiler.com/geocoding/${q}.json?limit=8&language=${p.lang}` +
          (cc ? `&country=${cc}` : "") + (near(p) ? `&proximity=${p.lng},${p.lat}` : "") + `&key=${k}`,
      };
    case "amazon": {
      const region = p.amazonRegion ?? AMAZON_REGIONS[0];
      return amazonPost("places", region, "search-text", key, {
        QueryText: p.q,
        MaxResults: 8,
        Language: amazonLang(p.lang),
        // One of BiasPosition, a box or a circle is required.
        BiasPosition: near(p) ? [p.lng, p.lat] : AMAZON_CENTRE[region] ?? AMAZON_CENTRE["ap-southeast-5"],
        ...(p.countries3.length ? { Filter: { IncludeCountries: p.countries3 } } : {}),
      });
    }
  }
  return null;
}

/**
 * Google's older APIs, asked when the newer one refuses (a key or project
 * with only the older API on): Places API Text Search for place search,
 * Directions API for routes. Their answers are read by parseSearch and
 * parseRoute like the newer ones'.
 */
export function googleLegacySearchRequest(p: SearchParams, key: string): HttpRequest {
  return {
    url: `https://maps.googleapis.com/maps/api/place/textsearch/json?query=${enc(p.q)}&language=${enc(p.lang)}` +
      (p.countries.length === 1 ? `&region=${p.countries[0]}` : "") +
      (near(p) ? `&location=${p.lat},${p.lng}&radius=50000` : "") + `&key=${enc(key)}`,
  };
}

export function googleDirectionsRequest(points: [number, number][], key: string): HttpRequest | null {
  if (points.length < 2) return null;
  const at = ([la, ln]: [number, number]) => `${la},${ln}`;
  const via = points.slice(1, -1);
  return {
    url: `https://maps.googleapis.com/maps/api/directions/json?origin=${at(points[0])}` +
      `&destination=${at(points[points.length - 1])}` +
      (via.length ? `&waypoints=${enc(via.map((p) => `via:${at(p)}`).join("|"))}` : "") +
      `&mode=driving&departure_time=now&key=${enc(key)}`,
  };
}

/**
 * The older Google APIs answer 200 with a `status` when they refuse
 * (REQUEST_DENIED, OVER_QUERY_LIMIT, …): that status, else null.
 */
export function googleLegacyRefusal(body: unknown): string | null {
  const status = (body as { status?: unknown } | null)?.status;
  return typeof status === "string" && status !== "OK" && status !== "ZERO_RESULTS" ? status : null;
}

function place(name: string, address: string, lat: unknown, lng: unknown, types?: unknown): Place | null {
  const la = num(lat), ln = num(lng);
  if (la == null || ln == null) return null;
  const addr = address || name;
  const n = name || addr.split(",")[0]?.trim() || "";
  if (!n) return null;
  const t = Array.isArray(types) ? types.filter((x): x is string => typeof x === "string") : [];
  return { name: n, address: addr, lat: la, lng: ln, ...(t.length ? { types: t } : {}) };
}

// deno-lint-ignore no-explicit-any
type J = any;

export function parseSearch(provider: string, body: J): Place[] {
  const out: (Place | null)[] = [];
  switch (provider) {
    case "google":
      // The older Text Search answers with `results`.
      for (const r of Array.isArray(body?.results) ? body.results : []) {
        const at = r?.geometry?.location;
        out.push(place(str(r?.name), str(r?.formatted_address), at?.lat, at?.lng, r?.types));
      }
      for (const p of body?.places ?? []) {
        const at = p?.location;
        out.push(place(str(p?.displayName?.text), str(p?.formattedAddress), at?.latitude, at?.longitude, p?.types));
      }
      break;
    case "mapbox":
      for (const f of body?.features ?? []) {
        const pr = f?.properties ?? {};
        out.push(place(str(pr.name), str(pr.full_address) || str(pr.place_formatted), pr.coordinates?.latitude, pr.coordinates?.longitude));
      }
      break;
    case "here":
      for (const it of body?.items ?? []) {
        out.push(place(str(it?.title), str(it?.address?.label), it?.position?.lat, it?.position?.lng));
      }
      break;
    case "tomtom":
      for (const r of body?.results ?? []) {
        const addr = str(r?.address?.freeformAddress);
        out.push(place(str(r?.poi?.name) || addr, addr, r?.position?.lat, r?.position?.lon));
      }
      break;
    case "locationiq":
      for (const r of Array.isArray(body) ? body : []) {
        out.push(place(str(r?.display_place), str(r?.display_name), r?.lat, r?.lon));
      }
      break;
    case "maptiler":
      for (const f of body?.features ?? []) {
        out.push(place(str(f?.text), str(f?.place_name), f?.center?.[1], f?.center?.[0]));
      }
      break;
    case "amazon":
      for (const r of body?.ResultItems ?? []) {
        out.push(place(str(r?.Title), str(r?.Address?.Label), r?.Position?.[1], r?.Position?.[0]));
      }
      break;
  }
  return out.filter((p): p is Place => p != null).slice(0, 8);
}

export function reverseRequest(
  provider: string,
  lat: number,
  lng: number,
  lang: string,
  key: string,
  amazonRegion: string = AMAZON_REGIONS[0],
): HttpRequest | null {
  const k = enc(key);
  switch (provider) {
    case "amazon":
      return amazonPost("places", amazonRegion, "reverse-geocode", key, {
        QueryPosition: [lng, lat],
        Language: amazonLang(lang),
      });
    case "google":
      return { url: `https://maps.googleapis.com/maps/api/geocode/json?latlng=${lat},${lng}&language=${lang}&key=${k}` };
    case "mapbox":
      return {
        url: `https://api.mapbox.com/search/geocode/v6/reverse?longitude=${lng}&latitude=${lat}&limit=1&language=${lang}&access_token=${k}`,
      };
    case "here":
      return { url: `https://revgeocode.search.hereapi.com/v1/revgeocode?at=${lat},${lng}&limit=1&lang=${lang}&apiKey=${k}` };
    case "tomtom":
      return { url: `https://api.tomtom.com/search/2/reverseGeocode/${lat},${lng}.json?language=${lang}&key=${k}` };
    case "locationiq":
      return {
        url: `https://us1.locationiq.com/v1/reverse?lat=${lat}&lon=${lng}&format=json&addressdetails=1&zoom=18&accept-language=${lang}&key=${k}`,
      };
    case "maptiler":
      return { url: `https://api.maptiler.com/geocoding/${lng},${lat}.json?limit=1&language=${lang}&key=${k}` };
  }
  return null;
}

function area(name: string, address: string, lat: number, lng: number, parts: Partial<Area>): Area | null {
  const addr = address || name;
  if (!addr) return null;
  return {
    name: name || addr.split(",")[0].trim(),
    address: addr,
    lat,
    lng,
    country: parts.country || null,
    state: parts.state || null,
    city: parts.city || null,
    suburb: parts.suburb || null,
  };
}

/** The first answer, at the point asked about ([lat], [lng]). */
export function parseReverse(provider: string, body: J, lat: number, lng: number): Area | null {
  switch (provider) {
    case "amazon": {
      const r = body?.ResultItems?.[0];
      if (!r) return null;
      const a = r.Address ?? {};
      return area(str(r.Title), str(a.Label), lat, lng, {
        country: str(a.Country?.Name),
        state: str(a.Region?.Name),
        city: str(a.Locality) || str(a.SubRegion?.Name),
        suburb: str(a.District) || str(a.SubDistrict),
      });
    }
    case "google": {
      const r = body?.results?.[0];
      if (!r) return null;
      const comp = (type: string) =>
        str((r.address_components ?? []).find((c: J) => (c?.types ?? []).includes(type))?.long_name);
      const address = str(r.formatted_address);
      return area(comp("premise") || comp("point_of_interest") || comp("route"), address, lat, lng, {
        country: comp("country"),
        state: comp("administrative_area_level_1"),
        city: comp("locality") || comp("administrative_area_level_2"),
        suburb: comp("sublocality") || comp("sublocality_level_1") || comp("neighborhood"),
      });
    }
    case "mapbox": {
      const pr = body?.features?.[0]?.properties;
      if (!pr) return null;
      const c = pr.context ?? {};
      return area(str(pr.name), str(pr.full_address) || str(pr.place_formatted), lat, lng, {
        country: str(c.country?.name),
        state: str(c.region?.name),
        city: str(c.place?.name),
        suburb: str(c.locality?.name) || str(c.neighborhood?.name),
      });
    }
    case "here": {
      const it = body?.items?.[0];
      if (!it) return null;
      const a = it.address ?? {};
      return area(str(it.title), str(a.label), lat, lng, {
        country: str(a.countryName),
        state: str(a.state),
        city: str(a.city),
        suburb: str(a.district),
      });
    }
    case "tomtom": {
      const a = body?.addresses?.[0]?.address;
      if (!a) return null;
      return area(str(a.streetName), str(a.freeformAddress), lat, lng, {
        country: str(a.country),
        state: str(a.countrySubdivisionName) || str(a.countrySubdivision),
        city: str(a.municipality),
        suburb: str(a.municipalitySubdivision),
      });
    }
    case "locationiq":
      return parseNominatim(body, lat, lng);
    case "maptiler": {
      const f = body?.features?.[0];
      if (!f) return null;
      const ctx = (prefix: string[]) =>
        str((f.context ?? []).find((c: J) => prefix.some((p) => String(c?.id ?? "").startsWith(p)))?.text);
      return area(str(f.text), str(f.place_name), lat, lng, {
        country: ctx(["country."]),
        state: ctx(["region.", "subregion."]),
        city: ctx(["municipality.", "place.", "county."]),
        suburb: ctx(["neighbourhood.", "neighborhood.", "locality.", "municipal_district."]),
      });
    }
  }
  return null;
}

/** Nominatim's (and LocationIQ's) reverse answer. */
export function parseNominatim(body: J, lat: number, lng: number): Area | null {
  if (!body || typeof body !== "object" || body.error) return null;
  const a = body.address ?? {};
  const pick = (keys: string[]) => keys.map((k) => str(a[k])).find((v) => v) ?? "";
  const display = str(body.display_name);
  return area(str(body.name), display, lat, lng, {
    country: pick(["country"]),
    state: pick(["state", "region"]),
    city: pick(["city", "town", "municipality", "village"]),
    suburb: pick(["suburb", "neighbourhood", "quarter", "city_district"]),
  });
}

// ---- Google Autocomplete, place details, Address Validation (migration 0207) ------------------

/** A session token the app made for one search (Google bills Autocomplete and the pick together). */
export function sessionToken(v: string | null): string | null {
  return v && /^[A-Za-z0-9_-]{8,64}$/.test(v) ? v : null;
}

/** Google's Autocomplete: the newer Places API (New), or the older one (googleLegacyAutocompleteRequest). */
export function googleAutocompleteRequest(p: SearchParams, key: string, session: string | null): HttpRequest {
  const at = near(p) ? { latitude: p.lat, longitude: p.lng } : null;
  return {
    url: "https://places.googleapis.com/v1/places:autocomplete",
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Goog-Api-Key": key },
    body: JSON.stringify({
      input: p.q,
      languageCode: p.lang,
      ...(p.countries.length ? { includedRegionCodes: p.countries } : {}),
      ...(at ? { locationBias: { circle: { center: at, radius: 50000 } }, origin: at } : {}),
      ...(session ? { sessionToken: session } : {}),
    }),
  };
}

export function googleLegacyAutocompleteRequest(p: SearchParams, key: string, session: string | null): HttpRequest {
  return {
    url: `https://maps.googleapis.com/maps/api/place/autocomplete/json?input=${enc(p.q)}&language=${enc(p.lang)}` +
      (p.countries.length ? `&components=${p.countries.map((c) => `country:${c}`).join("|")}` : "") +
      (near(p) ? `&location=${p.lat},${p.lng}&radius=50000&origin=${p.lat},${p.lng}` : "") +
      (session ? `&sessiontoken=${enc(session)}` : "") + `&key=${enc(key)}`,
  };
}

/** Either Autocomplete's answer as suggestions (at most 8). */
export function parseAutocomplete(body: J): Suggestion[] {
  const out: Suggestion[] = [];
  const types = (v: unknown) => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);
  const km = (v: unknown) => {
    const m = num(v);
    return m == null ? null : m / 1000;
  };
  for (const s of body?.suggestions ?? []) {
    const p = s?.placePrediction;
    const id = str(p?.placeId);
    const full = str(p?.text?.text);
    if (!id || !full) continue;
    out.push({
      name: str(p?.structuredFormat?.mainText?.text) || full.split(",")[0].trim(),
      address: str(p?.structuredFormat?.secondaryText?.text) || full,
      lat: null,
      lng: null,
      id,
      types: types(p?.types),
      km: km(p?.distanceMeters),
    });
  }
  for (const p of body?.predictions ?? []) {
    const id = str(p?.place_id);
    const full = str(p?.description);
    if (!id || !full) continue;
    out.push({
      name: str(p?.structured_formatting?.main_text) || full.split(",")[0].trim(),
      address: str(p?.structured_formatting?.secondary_text) || full,
      lat: null,
      lng: null,
      id,
      types: types(p?.types),
      km: km(p?.distance_meters),
    });
  }
  return out.slice(0, 8);
}

/** A picked suggestion's place: name, address and position. Newer API, or the older. */
export function googleDetailsRequest(id: string, lang: string, key: string, session: string | null): HttpRequest {
  return {
    url: `https://places.googleapis.com/v1/places/${enc(id)}?languageCode=${enc(lang)}` +
      (session ? `&sessionToken=${enc(session)}` : ""),
    headers: { "X-Goog-Api-Key": key, "X-Goog-FieldMask": "id,displayName,formattedAddress,location,types" },
  };
}

export function googleLegacyDetailsRequest(id: string, lang: string, key: string, session: string | null): HttpRequest {
  return {
    url: `https://maps.googleapis.com/maps/api/place/details/json?place_id=${enc(id)}&language=${enc(lang)}` +
      `&fields=name,formatted_address,geometry/location,types` + (session ? `&sessiontoken=${enc(session)}` : "") +
      `&key=${enc(key)}`,
  };
}

export function parseDetails(body: J): Place | null {
  const r = body?.result;
  if (r) {
    const at = r.geometry?.location;
    return place(str(r.name), str(r.formatted_address), at?.lat, at?.lng, r.types);
  }
  const at = body?.location;
  return place(str(body?.displayName?.text), str(body?.formattedAddress), at?.latitude, at?.longitude, body?.types);
}

/** Google's Address Validation for a picked street address ([region]: "MY"). */
export function addressValidationRequest(address: string, region: string, key: string): HttpRequest {
  return {
    url: `https://addressvalidation.googleapis.com/v1:validateAddress?key=${enc(key)}`,
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ address: { regionCode: region.toUpperCase(), addressLines: [address] } }),
  };
}

export interface CheckedAddress {
  address: string;
  lat: number | null;
  lng: number | null;
  /** Google found every part of it (verdict.addressComplete). */
  complete: boolean;
}

export function parseAddressValidation(body: J): CheckedAddress | null {
  const r = body?.result;
  const address = str(r?.address?.formattedAddress);
  if (!address) return null;
  return {
    address,
    lat: num(r?.geocode?.location?.latitude),
    lng: num(r?.geocode?.location?.longitude),
    complete: r?.verdict?.addressComplete === true,
  };
}

// ---- Routing -----------------------------------------------------------------------------------

export interface Route {
  distanceKm: number;
  durationMin: number;
  /** [lat, lng] pairs. */
  points: [number, number][];
}

export function routeRequest(
  provider: string,
  points: [number, number][],
  key: string,
  amazonRegion: string = AMAZON_REGIONS[0],
): HttpRequest | null {
  if (points.length < 2) return null;
  const k = enc(key);
  const lngLat = points.map(([la, ln]) => `${ln},${la}`).join(";");
  const [from, to] = [points[0], points[points.length - 1]];
  const via = points.slice(1, -1);
  switch (provider) {
    case "amazon":
      return amazonPost("routes", amazonRegion, "routes", key, {
        Origin: [from[1], from[0]],
        Destination: [to[1], to[0]],
        ...(via.length ? { Waypoints: via.map(([la, ln]) => ({ Position: [ln, la] })) } : {}),
        TravelMode: "Car",
        LegGeometryFormat: "Simple",
      });
    case "google": {
      const loc = ([la, ln]: [number, number]) => ({ location: { latLng: { latitude: la, longitude: ln } } });
      return {
        url: "https://routes.googleapis.com/directions/v2:computeRoutes",
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Goog-Api-Key": key,
          "X-Goog-FieldMask": "routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline",
        },
        body: JSON.stringify({
          origin: loc(from),
          destination: loc(to),
          ...(via.length ? { intermediates: via.map(loc) } : {}),
          travelMode: "DRIVE",
          routingPreference: "TRAFFIC_AWARE",
        }),
      };
    }
    case "mapbox":
      return {
        url: `https://api.mapbox.com/directions/v5/mapbox/driving/${lngLat}?geometries=geojson&overview=full&access_token=${k}`,
      };
    case "locationiq":
      return {
        url: `https://us1.locationiq.com/v1/directions/driving/${lngLat}?geometries=geojson&overview=full&key=${k}`,
      };
    case "here":
      return {
        url: `https://router.hereapi.com/v8/routes?transportMode=car&origin=${from[0]},${from[1]}` +
          `&destination=${to[0]},${to[1]}` + via.map(([la, ln]) => `&via=${la},${ln}`).join("") +
          `&return=summary,polyline&apiKey=${k}`,
      };
    case "tomtom":
      return {
        url: `https://api.tomtom.com/routing/1/calculateRoute/${points.map(([la, ln]) => `${la},${ln}`).join(":")}` +
          `/json?traffic=true&key=${k}`,
      };
  }
  return null;
}

export function parseRoute(provider: string, body: J): Route | null {
  switch (provider) {
    case "amazon": {
      const r = body?.Routes?.[0];
      const m = num(r?.Summary?.Distance), s = num(r?.Summary?.Duration);
      if (m == null || s == null) return null;
      const pts: [number, number][] = [];
      for (const leg of r?.Legs ?? []) {
        for (const c of leg?.Geometry?.LineString ?? []) pts.push([c[1], c[0]]);
      }
      return { distanceKm: m / 1000, durationMin: s / 60, points: pts };
    }
    case "google": {
      const r = body?.routes?.[0];
      // The older Directions API answers in legs.
      if (Array.isArray(r?.legs)) {
        let m = 0, s = 0;
        for (const leg of r.legs) {
          m += num(leg?.distance?.value) ?? 0;
          s += num(leg?.duration_in_traffic?.value) ?? num(leg?.duration?.value) ?? 0;
        }
        if (!r.legs.length) return null;
        return { distanceKm: m / 1000, durationMin: s / 60, points: decodePolyline(str(r?.overview_polyline?.points)) };
      }
      const m = num(r?.distanceMeters);
      const s = num(String(r?.duration ?? "").replace(/s$/, ""));
      if (m == null || s == null) return null;
      return { distanceKm: m / 1000, durationMin: s / 60, points: decodePolyline(str(r?.polyline?.encodedPolyline)) };
    }
    case "mapbox":
    case "locationiq":
    case "osrm": {
      const r = body?.routes?.[0];
      const m = num(r?.distance), s = num(r?.duration);
      if (m == null || s == null) return null;
      const coords: [number, number][] = (r?.geometry?.coordinates ?? []).map((c: number[]) => [c[1], c[0]]);
      return { distanceKm: m / 1000, durationMin: s / 60, points: coords };
    }
    case "here": {
      const sections = body?.routes?.[0]?.sections;
      if (!Array.isArray(sections) || !sections.length) return null;
      let m = 0, s = 0;
      const pts: [number, number][] = [];
      for (const sec of sections) {
        m += num(sec?.summary?.length) ?? 0;
        s += num(sec?.summary?.duration) ?? 0;
        pts.push(...decodeFlexiblePolyline(str(sec?.polyline)));
      }
      return { distanceKm: m / 1000, durationMin: s / 60, points: pts };
    }
    case "tomtom": {
      const r = body?.routes?.[0];
      const m = num(r?.summary?.lengthInMeters), s = num(r?.summary?.travelTimeInSeconds);
      if (m == null || s == null) return null;
      const pts: [number, number][] = [];
      for (const leg of r?.legs ?? []) {
        for (const p of leg?.points ?? []) pts.push([p.latitude, p.longitude]);
      }
      return { distanceKm: m / 1000, durationMin: s / 60, points: pts };
    }
  }
  return null;
}

// ---- Distances (place search results) ----------------------------------------------------------

/**
 * The road distance from [from] to each of [to], one request: a matrix of
 * one origin. Google's newer Routes API; googleDistanceMatrixRequest is the
 * older one.
 */
export function distanceRequest(
  provider: string,
  from: [number, number],
  to: [number, number][],
  key: string,
  amazonRegion: string = AMAZON_REGIONS[0],
): HttpRequest | null {
  if (!to.length) return null;
  const k = enc(key);
  const lngLat = [from, ...to].map(([la, ln]) => `${ln},${la}`).join(";");
  const json = { "Content-Type": "application/json" };
  switch (provider) {
    case "amazon": {
      const at = ([la, ln]: [number, number]) => ({ Position: [ln, la] });
      return amazonPost("routes", amazonRegion, "route-matrix", key, {
        Origins: [at(from)],
        Destinations: to.map(at),
        // GrabMaps takes only an unbounded matrix.
        RoutingBoundary: { Unbounded: true },
        TravelMode: "Car",
      });
    }
    case "google": {
      const wp = ([la, ln]: [number, number]) => ({
        waypoint: { location: { latLng: { latitude: la, longitude: ln } } },
      });
      return {
        url: "https://routes.googleapis.com/distanceMatrix/v2:computeRouteMatrix",
        method: "POST",
        headers: {
          ...json,
          "X-Goog-Api-Key": key,
          "X-Goog-FieldMask": "originIndex,destinationIndex,distanceMeters,condition",
        },
        body: JSON.stringify({ origins: [wp(from)], destinations: to.map(wp), travelMode: "DRIVE" }),
      };
    }
    case "mapbox":
      return {
        url: `https://api.mapbox.com/directions-matrix/v1/mapbox/driving/${lngLat}?sources=0&annotations=distance` +
          `&access_token=${k}`,
      };
    case "locationiq":
      return {
        url: `https://us1.locationiq.com/v1/matrix/driving/${lngLat}?sources=0&annotations=distance&key=${k}`,
      };
    case "here": {
      const pt = ([la, ln]: [number, number]) => ({ lat: la, lng: ln });
      return {
        url: `https://matrix.router.hereapi.com/v8/matrix?async=false&apiKey=${k}`,
        method: "POST",
        headers: json,
        body: JSON.stringify({
          origins: [pt(from)],
          destinations: to.map(pt),
          regionDefinition: { type: "world" },
          transportMode: "car",
          matrixAttributes: ["distances"],
        }),
      };
    }
    case "tomtom": {
      const pt = ([la, ln]: [number, number]) => ({ point: { latitude: la, longitude: ln } });
      return {
        url: `https://api.tomtom.com/routing/matrix/2?key=${k}`,
        method: "POST",
        headers: json,
        body: JSON.stringify({ origins: [pt(from)], destinations: to.map(pt), options: { travelMode: "car" } }),
      };
    }
  }
  return null;
}

/** Google's older Distance Matrix API, asked when the newer one refuses. */
export function googleDistanceMatrixRequest(from: [number, number], to: [number, number][], key: string): HttpRequest {
  const at = ([la, ln]: [number, number]) => `${la},${ln}`;
  return {
    url: `https://maps.googleapis.com/maps/api/distancematrix/json?origins=${at(from)}` +
      `&destinations=${enc(to.map(at).join("|"))}&mode=driving&key=${enc(key)}`,
  };
}

/**
 * Kilometres to each of [count] destinations, in order; null for one the
 * provider found no road to. Null when the answer isn't a matrix at all.
 */
export function parseDistances(provider: string, body: J, count: number): (number | null)[] | null {
  const out: (number | null)[] = Array(count).fill(null);
  const km = (m: unknown) => {
    const n = num(m);
    return n == null || n < 0 ? null : Math.round(n) / 1000;
  };
  switch (provider) {
    case "amazon": {
      const row = body?.RouteMatrix?.[0];
      if (!Array.isArray(row)) return null;
      for (let i = 0; i < count; i++) out[i] = row[i] == null || row[i].Error ? null : km(row[i].Distance);
      return out;
    }
    case "google": {
      // The older Distance Matrix API: rows[0].elements, one per destination.
      const elements = body?.rows?.[0]?.elements;
      if (Array.isArray(elements)) {
        elements.slice(0, count).forEach((e: J, i: number) => {
          out[i] = e?.status === "OK" ? km(e?.distance?.value) : null;
        });
        return out;
      }
      if (!Array.isArray(body)) return null;
      for (const e of body) {
        const i = num(e?.destinationIndex) ?? 0;
        // A zero distance is left out of the answer.
        if (i >= 0 && i < count && (e?.condition ?? "ROUTE_EXISTS") === "ROUTE_EXISTS") {
          out[i] = km(e?.distanceMeters ?? 0);
        }
      }
      return out;
    }
    case "mapbox":
    case "locationiq":
    case "osrm": {
      const row = body?.distances?.[0];
      if (!Array.isArray(row)) return null;
      // The first column is the origin itself.
      for (let i = 0; i < count; i++) out[i] = row[i + 1] == null ? null : km(row[i + 1]);
      return out;
    }
    case "here": {
      const d = body?.matrix?.distances;
      if (!Array.isArray(d)) return null;
      const errors = body?.matrix?.errorCodes;
      for (let i = 0; i < count; i++) {
        out[i] = Array.isArray(errors) && errors[i] ? null : km(d[i]);
      }
      return out;
    }
    case "tomtom": {
      const data = body?.data;
      if (!Array.isArray(data)) return null;
      for (const e of data) {
        const i = num(e?.destinationIndex) ?? -1;
        if (i >= 0 && i < count) out[i] = km(e?.routeSummary?.lengthInMeters);
      }
      return out;
    }
  }
  return null;
}

/** Google's encoded polyline (precision 5) as [lat, lng] pairs. */
export function decodePolyline(s: string): [number, number][] {
  const out: [number, number][] = [];
  let i = 0, lat = 0, lng = 0;
  const next = () => {
    let result = 0, shift = 0, b: number;
    do {
      b = s.charCodeAt(i++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20 && i < s.length);
    return result & 1 ? ~(result >> 1) : result >> 1;
  };
  while (i < s.length) {
    lat += next();
    lng += next();
    out.push([lat / 1e5, lng / 1e5]);
  }
  return out;
}

const FLEX = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/** HERE's flexible polyline as [lat, lng] pairs (a third dimension is read and dropped). */
export function decodeFlexiblePolyline(s: string): [number, number][] {
  if (!s) return [];
  let i = 0;
  const unsigned = (): number => {
    let result = 0, mult = 1;
    for (;;) {
      if (i >= s.length) throw new Error("truncated polyline");
      const v = FLEX.indexOf(s[i++]);
      if (v < 0) throw new Error("bad polyline character");
      result += (v & 0x1f) * mult;
      if ((v & 0x20) === 0) return result;
      mult *= 32;
    }
  };
  const signed = () => {
    const u = unsigned();
    return u % 2 ? -(u + 1) / 2 : u / 2;
  };
  if (unsigned() !== 1) throw new Error("unknown polyline version");
  const header = unsigned();
  const factor = 10 ** (header & 15);
  const third = (header >> 4) & 7;
  const out: [number, number][] = [];
  let lat = 0, lng = 0;
  while (i < s.length) {
    lat += signed();
    lng += signed();
    if (third) signed();
    out.push([lat / factor, lng / factor]);
  }
  return out;
}

// ---- Cache -------------------------------------------------------------------------------------

/**
 * Google's terms allow no caching of its place content, nor do AWS's of
 * Amazon Location's (GrabMaps can't mark an answer for storage): those
 * answers are never kept.
 */
export function cacheSeconds(provider: string, kind: Kind): number {
  if (provider === "google" || provider === "amazon") return 0;
  return { search: 86400, reverse: 30 * 86400, routing: 3600, distance: 3600 }[kind];
}

/** The cache key: same provider, kind and (rounded) question. */
export function cacheKey(provider: string, kind: Kind, parts: (string | number | undefined)[]): string {
  const norm = parts.map((p) => (typeof p === "number" ? p.toFixed(5) : String(p ?? "").trim().toLowerCase()));
  return `${kind}:${provider}:${norm.join("|")}`;
}
