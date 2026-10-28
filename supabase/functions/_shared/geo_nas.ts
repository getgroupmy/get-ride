/**
 * The office NAS as a `geo` provider (migration 0319): "Office NAS
 * (OpenStreetMap)", id "nas". deploy/nas-maps runs OSRM (routes, ETAs,
 * distances), Photon (place search, address lookup) and Protomaps vector
 * tiles on the NAS, reached through its Cloudflare Tunnel:
 *
 *   mapsUrl   (e.g. https://maps.getride.my)   routes and search; every request carries
 *             the secret header X-Nas-Maps-Key, which only this function holds
 *   tilesUrl  (e.g. https://tiles.getride.my)  the map: public, cached by Cloudflare;
 *             /styles/light.json and /styles/dark.json for MapLibre (the web)
 *
 * nas_maps_link(lat, lng) says where it is, whether it checked in within 3
 * minutes, which parts are on at that point (the admin's Default and region
 * rules, and whether that service said it was well), and how long to wait
 * for it (timeoutMs, 1.5 s by default) before the app asks the next provider.
 *
 * A profile that names "nas" only gets it while it is on: [withNas] takes
 * it out of the lists (and the map back to the app's own) otherwise, so the
 * app doesn't even ask an office NAS that is off. Pure: see geo_nas_test.ts.
 */
import type { HttpRequest, Kind, Place, Area, Profile, Route, TileSource } from "./geo.ts";

export const NAS = "nas";

/** The header the NAS's gateway checks. */
export const NAS_HEADER = "X-Nas-Maps-Key";

export const NAS_ATTRIBUTION = "© OpenStreetMap contributors, Protomaps";

export interface NasLink {
  url: string;
  tilesUrl: string | null;
  secret: string;
  online: boolean;
  routes: boolean;
  search: boolean;
  tiles: boolean;
  timeoutMs: number;
}

const https = (v: unknown): string | null =>
  typeof v === "string" && /^https:\/\/[A-Za-z0-9.-]+(:\d{1,5})?$/.test(v) ? v : null;

/** nas_maps_link's answer, or null when there is no NAS to ask. */
export function parseNasLink(v: unknown): NasLink | null {
  const o = v as Record<string, unknown> | null;
  if (!o || typeof o !== "object") return null;
  const url = https(o.url);
  const secret = typeof o.secret === "string" && o.secret.length >= 32 ? o.secret : null;
  if (!url || !secret) return null;
  const t = Number(o.timeoutMs);
  return {
    url,
    tilesUrl: https(o.tilesUrl),
    secret,
    online: o.online === true,
    routes: o.online === true && o.routes === true,
    search: o.online === true && o.search === true,
    tiles: o.online === true && o.tiles === true && !!https(o.tilesUrl),
    timeoutMs: Number.isFinite(t) ? Math.max(300, Math.min(5000, Math.round(t))) : 1500,
  };
}

/** Which of the admin's switches a kind of call goes by. */
export function nasPart(kind: Kind): "routes" | "search" {
  return kind === "routing" || kind === "distance" ? "routes" : "search";
}

/** Whether [p] names the NAS anywhere (only then is nas_maps_link asked). */
export function profileUsesNas(p: Profile): boolean {
  return [p.search, p.reverse, p.routing, p.distance, p.locate].some((l) => l.includes(NAS)) ||
    p.tiles.light === NAS || p.tiles.dark === NAS;
}

/**
 * [p] as the app should have it now: "nas" left in a list only while that
 * part is on (the default rule, as the profile has no point), the NAS map
 * only while the tiles are; a list left empty gets the free default back.
 */
export function withNas(p: Profile, link: NasLink | null): Profile {
  const routes = !!link?.routes, search = !!link?.search, tiles = !!link?.tiles;
  const keep = (list: string[], on: boolean, d: string) => {
    const out = on ? list : list.filter((x) => x !== NAS);
    return out.length ? out : [d];
  };
  const tile = (v: string) => (v === NAS && !tiles ? "app" : v);
  return {
    tiles: { ...p.tiles, light: tile(p.tiles.light), dark: tile(p.tiles.dark) },
    search: keep(p.search, search, "nominatim"),
    reverse: keep(p.reverse, search, "nominatim"),
    locate: keep(p.locate, search, "nominatim"),
    routing: keep(p.routing, routes, "osrm"),
    distance: keep(p.distance, routes, "osrm"),
  };
}

/**
 * The NAS's map for [slot]: a MapLibre style (vector tiles, drawn by the
 * browser), with no key, as the tiles are public. No imagery.
 */
export function nasTileSource(slot: "light" | "dark" | "satellite", link: NasLink | null): TileSource | null {
  if (slot === "satellite" || !link?.tiles || !link.tilesUrl) return null;
  return {
    url: "",
    darken: false,
    attribution: NAS_ATTRIBUTION,
    engine: "maplibre",
    key: "",
    keyless: true,
    style: `${link.tilesUrl}/styles/${slot}.json`,
  };
}

const lngLat = (points: [number, number][]) => points.map(([la, ln]) => `${ln.toFixed(6)},${la.toFixed(6)}`).join(";");

function ask(link: NasLink, path: string): HttpRequest {
  return { url: `${link.url}${path}`, headers: { [NAS_HEADER]: link.secret }, timeoutMs: link.timeoutMs };
}

/** OSRM's route, with every stop. */
export function nasRouteRequest(link: NasLink, points: [number, number][]): HttpRequest {
  return ask(link, `/route/v1/driving/${lngLat(points)}?overview=full&geometries=geojson`);
}

/** OSRM's table: the road distance from the first point to each other one. */
export function nasDistanceRequest(link: NasLink, from: [number, number], to: [number, number][]): HttpRequest {
  return ask(link, `/table/v1/driving/${lngLat([from, ...to])}?sources=0&annotations=distance`);
}

const enc = encodeURIComponent;

/** Photon's search, near the user when known. */
export function nasSearchRequest(link: NasLink, q: string, lang: string, lat?: number, lng?: number): HttpRequest {
  const near = lat != null && lng != null ? `&lat=${lat.toFixed(5)}&lon=${lng.toFixed(5)}` : "";
  return ask(link, `/api?q=${enc(q)}&limit=8&lang=${enc(photonLang(lang))}${near}`);
}

/** Photon's reverse lookup: what is at the point. */
export function nasReverseRequest(link: NasLink, lat: number, lng: number, lang: string): HttpRequest {
  return ask(link, `/reverse?lat=${lat.toFixed(6)}&lon=${lng.toFixed(6)}&limit=1&lang=${enc(photonLang(lang))}`);
}

/** Photon answers in "default" (local names), en, de, fr or it; our imports add ms and zh. */
function photonLang(lang: string): string {
  const l = lang.slice(0, 2).toLowerCase();
  return ["en", "ms", "zh"].includes(l) ? l : "en";
}

// deno-lint-ignore no-explicit-any
type J = any;

const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
const s = (v: unknown): string => (typeof v === "string" ? v.trim() : "");

export function parseNasRoute(body: J): Route | null {
  const r = body?.code === "Ok" ? body?.routes?.[0] : null;
  const m = num(r?.distance), sec = num(r?.duration);
  if (m == null || sec == null) return null;
  const points: [number, number][] = [];
  for (const c of r?.geometry?.coordinates ?? []) {
    if (Array.isArray(c) && num(c[0]) != null && num(c[1]) != null) points.push([c[1], c[0]]);
  }
  return { distanceKm: m / 1000, durationMin: sec / 60, points };
}

/** Each place's road distance in km (null where OSRM found no road). */
export function parseNasDistances(body: J, count: number): (number | null)[] | null {
  const row = body?.code === "Ok" ? body?.distances?.[0] : null;
  if (!Array.isArray(row) || row.length !== count + 1) return null;
  // The first column is the user's own spot.
  return row.slice(1).map((m: unknown) => (num(m) == null ? null : (m as number) / 1000));
}

/** One line of a Photon feature's address, without repeats. */
function photonAddress(p: J, name: string): string {
  const street = [s(p.housenumber), s(p.street)].filter(Boolean).join(" ");
  const parts = [name, street, s(p.district) || s(p.locality), s(p.city), [s(p.postcode), s(p.state)].filter(Boolean).join(" "),
    s(p.country)];
  const seen = new Set<string>();
  return parts.filter((x) => {
    const k = x.toLowerCase();
    if (!x || seen.has(k)) return false;
    seen.add(k);
    return true;
  }).join(", ");
}

function photonName(p: J): string {
  return s(p?.name) || [s(p?.housenumber), s(p?.street)].filter(Boolean).join(" ") || s(p?.city);
}

export function parseNasSearch(body: J): Place[] {
  const out: Place[] = [];
  for (const f of body?.features ?? []) {
    const [lng, lat] = f?.geometry?.coordinates ?? [];
    const p = f?.properties ?? {};
    const name = photonName(p);
    if (num(lat) == null || num(lng) == null || !name) continue;
    out.push({ name, address: photonAddress(p, name), lat, lng });
  }
  return out;
}

/** What is at [lat], [lng] (the point asked about, as other providers answer). */
export function parseNasReverse(body: J, lat: number, lng: number): Area | null {
  const p = body?.features?.[0]?.properties;
  if (!p) return null;
  const name = photonName(p);
  const address = photonAddress(p, name);
  if (!address) return null;
  return {
    name: name || address.split(",")[0].trim(),
    address,
    lat,
    lng,
    country: s(p.country) || null,
    state: s(p.state) || null,
    city: s(p.city) || s(p.county) || null,
    suburb: s(p.district) || s(p.locality) || null,
  };
}

/** Whether [e] is the NAS taking longer than its timeout. */
export function isTimeout(e: unknown): boolean {
  const m = e instanceof Error ? `${e.name} ${e.message}` : String(e ?? "");
  return /timed? ?out|TimeoutError|aborted/i.test(m);
}
