/**
 * Admin → Settings → Maps (migration 0200), the pure half of the `geo`
 * function: which tiles, place search, reverse geocoding and routing a
 * rider or partner gets on each kind of device, the provider's key for each,
 * and how each provider is asked and answered.
 *
 *   tiles     osm · google · mapbox · here · tomtom · maptiler (light, dark,
 *             satellite; esri for satellite), tomtom · here (traffic)
 *   search    nominatim · google · mapbox · here · tomtom · locationiq · maptiler
 *   reverse   the same
 *   routing   osrm · google · mapbox · here · tomtom · locationiq
 *
 * 'app' (tiles) keeps what the app was built with. nominatim and osrm are
 * called by the device itself (spread over every device's own address, as
 * OpenStreetMap's usage policy needs); the rest go through `geo`, which
 * holds the keys. Fetching is in geo/index.ts.
 */

export const ROLES = ["rider", "partner"] as const;
export const DEVICES = ["android", "ios", "web", "desktop"] as const;
export type Role = (typeof ROLES)[number];
export type Device = (typeof DEVICES)[number];
export type Kind = "search" | "reverse" | "routing";
export type TileSlot = "light" | "dark" | "satellite" | "traffic";

export interface Profile {
  tiles: Record<TileSlot, string>;
  search: string[];
  reverse: string[];
  routing: string[];
}

export interface MapConfig {
  profiles: Record<string, Profile>;
  keys: Record<string, string>;
}

/** Providers the device calls itself (no key, OpenStreetMap's servers or the admin's own). */
export const DIRECT = new Set(["nominatim", "osrm"]);

const DEFAULT_PROFILE: Profile = {
  tiles: { light: "app", dark: "app", satellite: "app", traffic: "app" },
  search: ["nominatim"],
  reverse: ["nominatim"],
  routing: ["osrm"],
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
  if (provider !== "google") return provider;
  return { tiles: "google_tiles", search: "google_places", reverse: "google_geocoding", routing: "google_routes" }[use];
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
  google_tiles: ["GOOGLE_MAP_API_KEY"],
  google_places: ["GOOGLE_PLACES_API_KEY"],
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

// ---- Tiles -----------------------------------------------------------------------------------

export interface TileSource {
  url: string;
  /** Darken on the device (OSM's tiles have no dark style). */
  darken: boolean;
  attribution: string;
}

const ATTRIBUTION: Record<string, string> = {
  osm: "© OpenStreetMap contributors",
  esri: "Imagery © Esri",
  google: "Map data © Google",
  mapbox: "© Mapbox © OpenStreetMap",
  here: "© HERE",
  tomtom: "© TomTom",
  maptiler: "© MapTiler © OpenStreetMap contributors",
};

const enc = encodeURIComponent;

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
): TileSource | null {
  const a = ATTRIBUTION[provider] ?? "";
  const k = key ? enc(key) : "";
  switch (provider) {
    case "osm":
      if (slot === "satellite") return null;
      return { url: "https://tile.openstreetmap.org/{z}/{x}/{y}.png", darken: slot === "dark", attribution: a };
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

/** The body to create a Google Map Tiles session for [slot]. */
export function googleSessionBody(slot: "light" | "dark" | "satellite", region: string, language = "en-US") {
  return {
    mapType: slot === "satellite" ? "satellite" : "roadmap",
    language,
    region: region.toUpperCase(),
    ...(slot === "dark" ? { styles: GOOGLE_NIGHT_STYLES } : {}),
  };
}

// ---- Place search and reverse geocoding -----------------------------------------------------

export interface Place {
  name: string;
  address: string;
  lat: number;
  lng: number;
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
          "X-Goog-FieldMask": "places.displayName,places.formattedAddress,places.location",
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
  }
  return null;
}

function place(name: string, address: string, lat: unknown, lng: unknown): Place | null {
  const la = num(lat), ln = num(lng);
  if (la == null || ln == null) return null;
  const addr = address || name;
  const n = name || addr.split(",")[0]?.trim() || "";
  if (!n) return null;
  return { name: n, address: addr, lat: la, lng: ln };
}

// deno-lint-ignore no-explicit-any
type J = any;

export function parseSearch(provider: string, body: J): Place[] {
  const out: (Place | null)[] = [];
  switch (provider) {
    case "google":
      for (const p of body?.places ?? []) {
        out.push(place(str(p?.displayName?.text), str(p?.formattedAddress), p?.location?.latitude, p?.location?.longitude));
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
  }
  return out.filter((p): p is Place => p != null).slice(0, 8);
}

export function reverseRequest(provider: string, lat: number, lng: number, lang: string, key: string): HttpRequest | null {
  const k = enc(key);
  switch (provider) {
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

// ---- Routing -----------------------------------------------------------------------------------

export interface Route {
  distanceKm: number;
  durationMin: number;
  /** [lat, lng] pairs. */
  points: [number, number][];
}

export function routeRequest(provider: string, points: [number, number][], key: string): HttpRequest | null {
  if (points.length < 2) return null;
  const k = enc(key);
  const lngLat = points.map(([la, ln]) => `${ln},${la}`).join(";");
  const [from, to] = [points[0], points[points.length - 1]];
  const via = points.slice(1, -1);
  switch (provider) {
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
    case "google": {
      const r = body?.routes?.[0];
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

/** Google's terms allow no caching of its place content: those answers are never kept. */
export function cacheSeconds(provider: string, kind: Kind): number {
  if (provider === "google") return 0;
  return { search: 86400, reverse: 30 * 86400, routing: 3600 }[kind];
}

/** The cache key: same provider, kind and (rounded) question. */
export function cacheKey(provider: string, kind: Kind, parts: (string | number | undefined)[]): string {
  const norm = parts.map((p) => (typeof p === "number" ? p.toFixed(5) : String(p ?? "").trim().toLowerCase()));
  return `${kind}:${provider}:${norm.join("|")}`;
}
