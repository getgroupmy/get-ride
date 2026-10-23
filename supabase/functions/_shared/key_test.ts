/**
 * Admin → API Keys → a key → Test: one small, real request with that key to
 * the API picked from a list, and what came back in plain words. The pure
 * half of the `key-test` function; fetching is in key-test/index.ts.
 *
 *   GET  → { tests: [{ id, provider, label, about, services, as, browser? }] }
 *   POST { provider, service, key, test, as?, cert? }
 *        → { result: "ok" | "warn" | "fail", title, detail, http, ms }
 *
 * The key is read here from Admin → API Keys by its id; the app never sends
 * it. "as" sends the request the way the key's application restriction
 * expects: "server" (none), "web" (getride.my as the referrer), "android"
 * (this app's package and, when given, the signing key's SHA-1) or "ios"
 * (this app's bundle ID). Tests marked browser run in the admin page itself
 * (Google's JavaScript map) and are never asked of the function.
 */

import { parseAwsKey, signedJsonPost } from "./aws_sigv4.ts";

export const APP_ID = "com.taxxee.teksi";
export const SITE = "https://getride.my/";

export type SendAs = "server" | "web" | "android" | "ios";
export const SEND_AS: SendAs[] = ["server", "web", "android", "ios"];

export interface HttpRequest {
  url: string;
  method?: "GET" | "POST";
  headers?: Record<string, string>;
  body?: string;
}

export interface KeyTest {
  id: string;
  /** Admin → API Keys provider id. */
  provider: string;
  label: string;
  about: string;
  /** Services this test is offered first for ("*" = all of the provider's). */
  services: string[];
  /** How it is sent unless the admin picks otherwise. */
  as?: SendAs;
  /** Runs in the admin's browser, not the function. */
  browser?: boolean;
  /** Free test from Google's own key check: the key exists, whatever the API restriction says. */
  keyCheck?: boolean;
  /** The request, given the key and map_config's Amazon region (a signed
   * one, AWS's, is made asynchronously). */
  request?(key: string, region: string): HttpRequest | Promise<HttpRequest>;
  /** An image is the answer (status alone says). */
  image?: boolean;
}

const enc = encodeURIComponent;
const KL = { lat: 3.139, lng: 101.6869 };
const KLCC = { lat: 3.1579, lng: 101.7123 };
const json = (url: string, body: unknown, headers: Record<string, string> = {}): HttpRequest => ({
  url,
  method: "POST",
  headers: { "Content-Type": "application/json", ...headers },
  body: JSON.stringify(body),
});
const latLng = (p: { lat: number; lng: number }) => ({ latLng: { latitude: p.lat, longitude: p.lng } });

export const TESTS: KeyTest[] = [
  // ---- Google ------------------------------------------------------------------------------
  {
    id: "google_key",
    provider: "google",
    label: "Key check (any Google key)",
    about: "Whether Google knows the key and lets this app or site use it, whichever APIs it is kept to.",
    services: ["maps_android", "maps_ios"],
    keyCheck: true,
    request: (k) => ({ url: `https://maps.googleapis.com/maps/api/geocode/json?latlng=${KL.lat},${KL.lng}&key=${enc(k)}` }),
  },
  {
    id: "google_maps_js",
    provider: "google",
    label: "Maps JavaScript (in this browser)",
    about: "Loads Google's JavaScript map with the key here, as the website and desktop app do.",
    services: ["maps_js"],
    as: "web",
    browser: true,
  },
  {
    id: "google_tiles",
    provider: "google",
    label: "Map Tiles API",
    about: "Starts a Map Tiles session, as the app's Google map does.",
    services: ["maps"],
    request: (k) => json(`https://tile.googleapis.com/v1/createSession?key=${enc(k)}`, {
      mapType: "roadmap",
      language: "en-US",
      region: "MY",
    }),
  },
  {
    id: "google_static",
    provider: "google",
    label: "Maps Static API",
    about: "A small map image.",
    services: ["maps"],
    image: true,
    request: (k) => ({
      url: `https://maps.googleapis.com/maps/api/staticmap?center=${KL.lat},${KL.lng}&zoom=13&size=64x64&key=${enc(k)}`,
    }),
  },
  {
    id: "google_places_text",
    provider: "google",
    label: "Places API (New) · Text Search",
    about: "Place search for “KLCC”.",
    services: ["places"],
    request: (k) => json("https://places.googleapis.com/v1/places:searchText", { textQuery: "KLCC", maxResultCount: 1 }, {
      "X-Goog-Api-Key": k,
      "X-Goog-FieldMask": "places.displayName",
    }),
  },
  {
    id: "google_places_autocomplete",
    provider: "google",
    label: "Places API (New) · Autocomplete",
    about: "Suggestions for “KLCC”.",
    services: ["places"],
    request: (k) => json("https://places.googleapis.com/v1/places:autocomplete", { input: "KLCC" }, { "X-Goog-Api-Key": k }),
  },
  {
    id: "google_places_legacy",
    provider: "google",
    label: "Places API (older) · Text Search",
    about: "Place search for “KLCC” with the older API.",
    services: ["places"],
    request: (k) => ({ url: `https://maps.googleapis.com/maps/api/place/textsearch/json?query=KLCC&key=${enc(k)}` }),
  },
  {
    id: "google_geocoding",
    provider: "google",
    label: "Geocoding API",
    about: "The address at a point in Kuala Lumpur.",
    services: ["geocoding"],
    request: (k) => ({ url: `https://maps.googleapis.com/maps/api/geocode/json?latlng=${KL.lat},${KL.lng}&key=${enc(k)}` }),
  },
  {
    id: "google_routes",
    provider: "google",
    label: "Routes API · route",
    about: "A drive across Kuala Lumpur.",
    services: ["directions"],
    request: (k) => json("https://routes.googleapis.com/directions/v2:computeRoutes", {
      origin: { location: latLng(KL) },
      destination: { location: latLng(KLCC) },
      travelMode: "DRIVE",
    }, { "X-Goog-Api-Key": k, "X-Goog-FieldMask": "routes.distanceMeters" }),
  },
  {
    id: "google_route_matrix",
    provider: "google",
    label: "Routes API · route matrix",
    about: "Road distance between two points.",
    services: ["distance_matrix", "directions"],
    request: (k) => json("https://routes.googleapis.com/distanceMatrix/v2:computeRouteMatrix", {
      origins: [{ waypoint: { location: latLng(KL) } }],
      destinations: [{ waypoint: { location: latLng(KLCC) } }],
      travelMode: "DRIVE",
    }, { "X-Goog-Api-Key": k, "X-Goog-FieldMask": "distanceMeters,condition" }),
  },
  {
    id: "google_directions",
    provider: "google",
    label: "Directions API (older)",
    about: "A drive across Kuala Lumpur with the older API.",
    services: ["directions"],
    request: (k) => ({
      url: `https://maps.googleapis.com/maps/api/directions/json?origin=${KL.lat},${KL.lng}` +
        `&destination=${KLCC.lat},${KLCC.lng}&key=${enc(k)}`,
    }),
  },
  {
    id: "google_distance_matrix",
    provider: "google",
    label: "Distance Matrix API (older)",
    about: "Road distance between two points with the older API.",
    services: ["distance_matrix"],
    request: (k) => ({
      url: `https://maps.googleapis.com/maps/api/distancematrix/json?origins=${KL.lat},${KL.lng}` +
        `&destinations=${KLCC.lat},${KLCC.lng}&key=${enc(k)}`,
    }),
  },
  {
    id: "google_address_validation",
    provider: "google",
    label: "Address Validation API",
    about: "Checks a Kuala Lumpur address.",
    services: ["address_validation"],
    request: (k) => json(`https://addressvalidation.googleapis.com/v1:validateAddress?key=${enc(k)}`, {
      address: { regionCode: "MY", addressLines: ["Jalan Ampang, 50450 Kuala Lumpur"] },
    }),
  },
  {
    id: "google_roads",
    provider: "google",
    label: "Roads API",
    about: "The nearest road to a point.",
    services: ["roads"],
    request: (k) => ({ url: `https://roads.googleapis.com/v1/nearestRoads?points=${KL.lat},${KL.lng}&key=${enc(k)}` }),
  },
  // ---- Google Gemini -------------------------------------------------------------------------
  {
    id: "gemini_models",
    provider: "google_gemini",
    label: "Gemini API · list models",
    about: "Lists the models the key may use (nothing is generated).",
    services: ["*"],
    request: (k) => ({ url: `https://generativelanguage.googleapis.com/v1beta/models?pageSize=1&key=${enc(k)}` }),
  },
  // ---- Others --------------------------------------------------------------------------------
  {
    id: "amazon_places",
    provider: "amazon",
    label: "Amazon Location · place search",
    about: "Place search for “KLCC” in the region set in Admin → Maps.",
    services: ["location"],
    request: (k, r) => json(`https://places.geo.${r}.amazonaws.com/v2/search-text?key=${enc(k)}`, {
      QueryText: "KLCC",
      MaxResults: 1,
      BiasPosition: [KL.lng, KL.lat],
    }),
  },
  {
    id: "amazon_routes",
    provider: "amazon",
    label: "Amazon Location · route",
    about: "A drive across Kuala Lumpur.",
    services: ["location"],
    request: (k, r) => json(`https://routes.geo.${r}.amazonaws.com/v2/routes?key=${enc(k)}`, {
      Origin: [KL.lng, KL.lat],
      Destination: [KLCC.lng, KLCC.lat],
      TravelMode: "Car",
    }),
  },
  {
    id: "amazon_map",
    provider: "amazon",
    label: "Amazon Location · map style",
    about: "The map's style, as the browser loads it.",
    services: ["maps"],
    request: (k, r) => ({ url: `https://maps.geo.${r}.amazonaws.com/v2/styles/Standard/descriptor?key=${enc(k)}` }),
  },
  {
    id: "mapbox_search",
    provider: "mapbox",
    label: "Mapbox · geocoding",
    about: "Place search for “Kuala Lumpur”.",
    services: ["*"],
    request: (k) => ({ url: `https://api.mapbox.com/search/geocode/v6/forward?q=Kuala%20Lumpur&limit=1&access_token=${enc(k)}` }),
  },
  {
    id: "mapbox_style",
    provider: "mapbox",
    label: "Mapbox · map style",
    about: "The streets map style.",
    services: ["tiles"],
    request: (k) => ({ url: `https://api.mapbox.com/styles/v1/mapbox/streets-v12?access_token=${enc(k)}` }),
  },
  {
    id: "here_search",
    provider: "here",
    label: "HERE · geocoding",
    about: "Place search for “Kuala Lumpur”.",
    services: ["*"],
    request: (k) => ({ url: `https://geocode.search.hereapi.com/v1/geocode?q=Kuala%20Lumpur&limit=1&apiKey=${enc(k)}` }),
  },
  {
    id: "here_route",
    provider: "here",
    label: "HERE · route",
    about: "A drive across Kuala Lumpur.",
    services: ["api"],
    request: (k) => ({
      url: `https://router.hereapi.com/v8/routes?transportMode=car&origin=${KL.lat},${KL.lng}` +
        `&destination=${KLCC.lat},${KLCC.lng}&return=summary&apiKey=${enc(k)}`,
    }),
  },
  {
    id: "tomtom_search",
    provider: "tomtom",
    label: "TomTom · search",
    about: "Place search for “Kuala Lumpur”.",
    services: ["*"],
    request: (k) => ({ url: `https://api.tomtom.com/search/2/search/Kuala%20Lumpur.json?limit=1&key=${enc(k)}` }),
  },
  {
    id: "tomtom_route",
    provider: "tomtom",
    label: "TomTom · route",
    about: "A drive across Kuala Lumpur.",
    services: ["api"],
    request: (k) => ({
      url: `https://api.tomtom.com/routing/1/calculateRoute/${KL.lat},${KL.lng}:${KLCC.lat},${KLCC.lng}/json?key=${enc(k)}`,
    }),
  },
  {
    id: "azure_search",
    provider: "microsoft",
    label: "Azure Maps · search",
    about: "Place search for “Kuala Lumpur”.",
    services: ["azure_maps"],
    request: (k) => ({
      url: `https://atlas.microsoft.com/search/address/json?api-version=1.0&query=Kuala%20Lumpur&limit=1&subscription-key=${enc(k)}`,
    }),
  },
  {
    id: "arcgis_geocode",
    provider: "esri",
    label: "ArcGIS · geocoding",
    about: "Place search for “Kuala Lumpur”.",
    services: ["*"],
    request: (k) => ({
      url: "https://geocode-api.arcgis.com/arcgis/rest/services/World/GeocodeServer/findAddressCandidates" +
        `?SingleLine=Kuala%20Lumpur&maxLocations=1&f=json&token=${enc(k)}`,
    }),
  },
  {
    id: "maptiler_search",
    provider: "tiles",
    label: "MapTiler · geocoding",
    about: "Place search for “Kuala Lumpur”.",
    services: ["maptiler"],
    request: (k) => ({ url: `https://api.maptiler.com/geocoding/Kuala%20Lumpur.json?limit=1&key=${enc(k)}` }),
  },
  {
    id: "stadia_search",
    provider: "tiles",
    label: "Stadia Maps · geocoding",
    about: "Place search for “Kuala Lumpur”.",
    services: ["stadia_maps"],
    request: (k) => ({ url: `https://api.stadiamaps.com/geocoding/v1/search?text=Kuala%20Lumpur&size=1&api_key=${enc(k)}` }),
  },
  {
    id: "thunderforest_tile",
    provider: "tiles",
    label: "Thunderforest · map tile",
    about: "One map tile.",
    services: ["thunderforest"],
    image: true,
    request: (k) => ({ url: `https://tile.thunderforest.com/cycle/1/1/1.png?apikey=${enc(k)}` }),
  },
  {
    id: "graphhopper_route",
    provider: "routing",
    label: "GraphHopper · route",
    about: "A drive across Kuala Lumpur.",
    services: ["graphhopper"],
    request: (k) => ({
      url: `https://graphhopper.com/api/1/route?point=${KL.lat},${KL.lng}&point=${KLCC.lat},${KLCC.lng}` +
        `&profile=car&calc_points=false&key=${enc(k)}`,
    }),
  },
  {
    id: "locationiq_search",
    provider: "geocoding",
    label: "LocationIQ · search",
    about: "Place search for “Kuala Lumpur”.",
    services: ["locationiq"],
    request: (k) => ({ url: `https://us1.locationiq.com/v1/search?q=Kuala%20Lumpur&format=json&limit=1&key=${enc(k)}` }),
  },
  {
    id: "opencage_search",
    provider: "geocoding",
    label: "OpenCage · geocoding",
    about: "Place search for “Kuala Lumpur”.",
    services: ["opencage"],
    request: (k) => ({ url: `https://api.opencagedata.com/geocode/v1/json?q=Kuala%20Lumpur&limit=1&key=${enc(k)}` }),
  },
  {
    id: "geoapify_search",
    provider: "geocoding",
    label: "Geoapify · geocoding",
    about: "Place search for “Kuala Lumpur”.",
    services: ["geoapify"],
    request: (k) => ({ url: `https://api.geoapify.com/v1/geocode/search?text=Kuala%20Lumpur&limit=1&apiKey=${enc(k)}` }),
  },
  {
    id: "positionstack_search",
    provider: "geocoding",
    label: "Positionstack · geocoding",
    about: "Place search for “Kuala Lumpur”.",
    services: ["positionstack"],
    request: (k) => ({ url: `https://api.positionstack.com/v1/forward?query=Kuala%20Lumpur&limit=1&access_key=${enc(k)}` }),
  },
  {
    id: "what3words_convert",
    provider: "geocoding",
    label: "what3words · convert",
    about: "The three words for a point in Kuala Lumpur.",
    services: ["what3words"],
    request: (k) => ({ url: `https://api.what3words.com/v3/convert-to-3wa?coordinates=${KL.lat},${KL.lng}&key=${enc(k)}` }),
  },
  {
    id: "radar_geocode",
    provider: "geofencing",
    label: "Radar · geocoding",
    about: "Place search for “Kuala Lumpur”.",
    services: ["*"],
    request: (k) => ({ url: "https://api.radar.io/v1/geocode/forward?query=Kuala%20Lumpur", headers: { Authorization: k } }),
  },
  {
    id: "foursquare_search",
    provider: "places",
    label: "Foursquare · place search",
    about: "Places near Kuala Lumpur.",
    services: ["*"],
    request: (k) => ({
      url: `https://places-api.foursquare.com/places/search?ll=${KL.lat},${KL.lng}&limit=1`,
      headers: { Authorization: `Bearer ${k}`, "X-Places-Api-Version": "2025-06-17" },
    }),
  },
  {
    id: "ipinfo_lookup",
    provider: "ip_geolocation",
    label: "IPinfo · lookup",
    about: "Where 8.8.8.8 is.",
    services: ["ipinfo"],
    request: (k) => ({ url: `https://ipinfo.io/8.8.8.8?token=${enc(k)}` }),
  },
  {
    id: "ipgeolocation_lookup",
    provider: "ip_geolocation",
    label: "ipgeolocation.io · lookup",
    about: "Where 8.8.8.8 is.",
    services: ["ipgeolocation"],
    request: (k) => ({ url: `https://api.ipgeolocation.io/ipgeo?ip=8.8.8.8&apiKey=${enc(k)}` }),
  },
  {
    id: "nominatim_search",
    provider: "openstreetmap",
    label: "Nominatim server · search",
    about: "Place search on the server address saved as this key.",
    services: ["nominatim"],
    request: (k) => ({ url: `${base(k)}/search?q=Kuala%20Lumpur&format=json&limit=1` }),
  },
  {
    id: "osrm_route",
    provider: "openstreetmap",
    label: "OSRM server · route",
    about: "A drive across Kuala Lumpur on the server address saved as this key.",
    services: ["osrm"],
    request: (k) => ({
      url: `${base(k)}/route/v1/driving/${KL.lng},${KL.lat};${KLCC.lng},${KLCC.lat}?overview=false`,
    }),
  },
  {
    id: "overpass_status",
    provider: "openstreetmap",
    label: "Overpass server · query",
    about: "A tiny query on the server address saved as this key.",
    services: ["overpass"],
    request: (k) => ({ url: `${base(k)}?data=${enc("[out:json];node(1);out;")}` }),
  },
  // ---- Email (the Reports schedules, migration 0280) --------------------------------------
  {
    id: "resend_key",
    provider: "email",
    label: "Resend · key check",
    about: "Asks Resend for the key's sending domains. No email is sent.",
    services: ["resend"],
    request: (k) => ({ url: "https://api.resend.com/domains", headers: { Authorization: `Bearer ${k}` } }),
  },
  // ---- AWS (face compare, 0281) ---------------------------------------------------------------
  {
    id: "aws_rekognition",
    provider: "aws",
    label: "Rekognition · list collections",
    about: "A free signed call with the key: AWS knows it and lets it use Rekognition in its region.",
    services: ["rekognition"],
    request: async (k) => {
      const key = parseAwsKey(k);
      if (!key) throw new Error("not an AWS key");
      const body = JSON.stringify({ MaxResults: 1 });
      const signed = await signedJsonPost(key, "rekognition", "RekognitionService.ListCollections", body);
      return { url: signed.url, method: "POST", headers: signed.headers, body };
    },
  },
];

/** A self-hosted server's address saved as a key: https only, no trailing slash. */
function base(v: string): string {
  const s = v.trim().replace(/\/+$/, "");
  if (!/^https:\/\/[^\s]+$/.test(s)) throw new Error("not_a_url");
  return s;
}

/** The tests a key of [provider]'s [service] may run: the ones meant for it first. */
export function testsFor(provider: string, service: string): KeyTest[] {
  const mine = TESTS.filter((t) => t.provider === provider);
  const meant = (t: KeyTest) => t.services.includes(service) || t.services.includes("*");
  return [...mine.filter(meant), ...mine.filter((t) => !meant(t))];
}

/** How a key of [service] is sent by default: as the app or site it is restricted to. */
export function defaultAs(service: string, test?: KeyTest): SendAs {
  if (service === "maps_android") return "android";
  if (service === "maps_ios") return "ios";
  if (service === "maps_js") return "web";
  return test?.as ?? "server";
}

/** A SHA-1 as Google wants it in X-Android-Cert: 40 hex digits, no colons. */
export function certOf(v: unknown): string | null {
  const s = typeof v === "string" ? v.replace(/[\s:]/g, "").toUpperCase() : "";
  return /^[0-9A-F]{40}$/.test(s) ? s : null;
}

/** The headers that make the request look like it came from our app or site. */
export function restrictionHeaders(as: SendAs, cert: string | null): Record<string, string> {
  switch (as) {
    case "web":
      return { Referer: SITE, Origin: SITE.replace(/\/$/, "") };
    case "android":
      return { "X-Android-Package": APP_ID, ...(cert ? { "X-Android-Cert": cert } : {}) };
    case "ios":
      return { "X-Ios-Bundle-Identifier": APP_ID };
  }
  return {};
}

export interface Verdict {
  result: "ok" | "warn" | "fail";
  title: string;
  detail: string;
}

/** Google's reason codes (newer APIs) in plain words. */
const GOOGLE_REASONS: Record<string, Verdict> = {
  API_KEY_INVALID: { result: "fail", title: "Google doesn't know this key", detail: "Check it was copied whole, and that it wasn't deleted in Google Cloud." },
  API_KEY_SERVICE_BLOCKED: { result: "fail", title: "This API isn't allowed for the key", detail: "In Google Cloud → Credentials → this key → API restrictions, tick this API." },
  SERVICE_DISABLED: { result: "fail", title: "This API is turned off in the key's project", detail: "Enable it in Google Cloud → APIs & Services → Library, in the project the key belongs to." },
  API_KEY_HTTP_REFERRER_BLOCKED: { result: "fail", title: "The key's website list doesn't allow getride.my", detail: "Add getride.my/* (and the admin's address) under Website restrictions, or test it sent as another kind." },
  API_KEY_ANDROID_APP_BLOCKED: { result: "fail", title: "The key's Android app list doesn't match", detail: `It must list ${APP_ID} with the SHA-1 of the Play signing key (Play Console → App integrity) and the upload key. Give that SHA-1 here to test it.` },
  API_KEY_IOS_APP_BLOCKED: { result: "fail", title: "The key's iOS app list doesn't match", detail: `It must list the bundle ID ${APP_ID}.` },
  API_KEY_IP_ADDRESS_BLOCKED: { result: "fail", title: "The key only allows certain IP addresses", detail: "Server calls come from Supabase, whose addresses change: use no IP restriction for server keys." },
  BILLING_DISABLED: { result: "fail", title: "Billing is off for the key's project", detail: "Turn on billing in Google Cloud for the project the key belongs to." },
  RATE_LIMIT_EXCEEDED: { result: "warn", title: "Over the quota", detail: "The key works, but its quota is used up for now." },
  RESOURCE_EXHAUSTED: { result: "warn", title: "Over the quota", detail: "The key works, but its quota is used up for now." },
};

/** Google's older APIs' error_message in plain words. */
function googleMessage(message: string, keyCheck: boolean): Verdict {
  const m = message.toLowerCase();
  if (m.includes("api key is invalid") || m.includes("api key not valid")) return GOOGLE_REASONS.API_KEY_INVALID;
  // App and site restrictions first: their message also says "not authorized to use this API key".
  if (m.includes("referer") || m.includes("referrer")) return GOOGLE_REASONS.API_KEY_HTTP_REFERRER_BLOCKED;
  if (m.includes("android")) return GOOGLE_REASONS.API_KEY_ANDROID_APP_BLOCKED;
  if (/\bios\b/.test(m)) return GOOGLE_REASONS.API_KEY_IOS_APP_BLOCKED;
  if (m.includes("ip, site or mobile application") || m.includes("ip address")) {
    return { result: "fail", title: "The key is kept to certain apps or sites", detail: "Pick how to send it (website, Android or iOS) to test it as the app or site it is meant for." };
  }
  if (/not authorized to use this (service or )?api\b(?! key)/.test(m)) {
    return keyCheck
      ? { result: "ok", title: "Google knows this key, and it is kept to other APIs", detail: "Good for a key kept to one API (Maps SDK for Android or iOS). The map itself can only show on a phone." }
      : GOOGLE_REASONS.API_KEY_SERVICE_BLOCKED;
  }
  if (m.includes("not activated") || m.includes("has not been used") || m.includes("is disabled")) return GOOGLE_REASONS.SERVICE_DISABLED;
  if (m.includes("billing")) return GOOGLE_REASONS.BILLING_DISABLED;
  if (m.includes("quota") || m.includes("limit")) return GOOGLE_REASONS.RATE_LIMIT_EXCEEDED;
  return { result: "fail", title: "Google refused", detail: message };
}

/** Takes [key] out of anything shown. */
export function scrub(text: string, key: string): string {
  const k = key.trim();
  return k.length >= 6 ? text.split(k).join("••••").split(encodeURIComponent(k)).join("••••") : text;
}

// deno-lint-ignore no-explicit-any
type J = any;

/** What an answer means. [body] is the parsed JSON (null when it wasn't), [text] the raw start. */
export function verdictOf(test: KeyTest, status: number, body: J, text: string): Verdict {
  const okStatus = status >= 200 && status < 300;
  const google = test.provider === "google" || test.provider === "google_gemini";
  if (google) {
    // The newer APIs: { error: { status, message, details: [{ reason }] } }.
    const err = body?.error;
    if (err && typeof err === "object") {
      const reasons: string[] = [err.status, ...(Array.isArray(err.details) ? err.details.map((d: J) => d?.reason) : [])]
        .filter((r): r is string => typeof r === "string");
      for (const r of reasons) if (GOOGLE_REASONS[r]) return GOOGLE_REASONS[r];
      return { result: "fail", title: "Google refused", detail: String(err.message ?? reasons.join(", ") ?? status) };
    }
    // The older APIs answer 200 with a status.
    const s = typeof body?.status === "string" ? body.status : null;
    if (s && s !== "OK" && s !== "ZERO_RESULTS") {
      return googleMessage(String(body?.error_message ?? s), !!test.keyCheck);
    }
    // The Static API answers its errors as text.
    if (!okStatus) return googleMessage(text || `HTTP ${status}`, !!test.keyCheck);
    return test.keyCheck
      ? { result: "ok", title: "Google knows this key, and Geocoding works with it", detail: "The key isn't kept to one API. For a phone key, keep it to Maps SDK for Android or iOS." }
      : { result: "ok", title: "Works", detail: "Google answered." };
  }
  // A Resend key kept to sending can't list the domains: it still sends.
  if (test.provider === "email" && status === 401 && body?.name === "restricted_api_key") {
    return { result: "ok", title: "Works (a sending-only key)", detail: "Resend accepts the key for sending email." };
  }
  if (test.provider === "email" && okStatus) {
    const domains = Array.isArray(body?.data) ? body.data as { name?: string; status?: string }[] : [];
    const verified = domains.filter((d) => d?.status === "verified").map((d) => d.name).filter(Boolean);
    return verified.length
      ? { result: "ok", title: "Works", detail: `Resend accepts the key. Verified to send from: ${verified.join(", ")}.` }
      : { result: "warn", title: "The key works, but no domain is verified", detail: "Verify the sender's domain (e.g. getride.my) in Resend, or the emails will be refused." };
  }
  if (!okStatus) {
    if (status === 401 || status === 403) {
      return { result: "fail", title: "The key was refused", detail: shortError(body, text) || `HTTP ${status}` };
    }
    if (status === 429) return { result: "warn", title: "Over the quota", detail: "The key works, but its quota is used up for now." };
    if (status === 404 && test.provider === "openstreetmap") {
      return { result: "fail", title: "Not found on that server", detail: "Check the address saved as this key." };
    }
    return { result: "fail", title: `HTTP ${status}`, detail: shortError(body, text) };
  }
  // Some answer 200 with an error in the body.
  const inBody = body && typeof body === "object" && !Array.isArray(body) ? body.error ?? body.errors : null;
  if (inBody) return { result: "fail", title: "The provider refused", detail: shortError(body, text) };
  return { result: "ok", title: "Works", detail: "The provider answered." };
}

function shortError(body: J, text: string): string {
  const e = body?.error ?? body?.errors ?? body?.message ?? body?.Message ?? body?.detail;
  const s = typeof e === "string"
    ? e
    : typeof e?.message === "string"
    ? e.message
    : typeof e?.details === "string"
    ? e.details
    : Array.isArray(e) && typeof e[0]?.message === "string"
    ? e[0].message
    : text;
  return String(s ?? "").replace(/\s+/g, " ").trim().slice(0, 300);
}

/** The list the admin picks from (no requests in it). */
export function testList() {
  return TESTS.map(({ id, provider, label, about, services, as, browser }) => ({
    id,
    provider,
    label,
    about,
    services,
    as: as ?? "server",
    browser: browser === true,
  }));
}

interface KeyEntry {
  id?: string;
  value?: string;
}

/** The key's value in Admin → API Keys, by provider, service and key id; null when none. */
export function keyValue(apiProviders: unknown, provider: string, service: string, keyId: string): string | null {
  const list = Array.isArray(apiProviders) ? apiProviders : (apiProviders as { providers?: unknown })?.providers;
  if (!Array.isArray(list)) return null;
  const p = list.find((x) => x?.id === provider);
  const s = (p?.services ?? []).find((x: { id?: string }) => x?.id === service);
  const k = (Array.isArray(s?.keys) ? s.keys as KeyEntry[] : []).find((x) => x?.id === keyId);
  const v = typeof k?.value === "string" ? k.value.trim() : "";
  return v || null;
}

export interface KeyTestDeps {
  /** api_providers and map_config. */
  settings(): Promise<{ apiProviders: unknown; config: unknown }>;
  /** One request: status, the start of the body as text. */
  fetch(req: HttpRequest): Promise<{ status: number; text: string }>;
  now(): number;
}

export interface TestAnswer {
  status: number;
  body: unknown;
}

/** POST body → the test's answer. The caller is already known to be an admin. */
export async function runKeyTest(input: unknown, deps: KeyTestDeps): Promise<TestAnswer> {
  const b = (input ?? {}) as Record<string, unknown>;
  const str = (v: unknown) => (typeof v === "string" ? v : "");
  const test = TESTS.find((t) => t.id === str(b.test));
  if (!test || !test.request) return { status: 400, body: { error: "Unknown test." } };
  if (test.provider !== str(b.provider)) return { status: 400, body: { error: "That test is for another provider." } };
  const as = (SEND_AS as string[]).includes(str(b.as)) ? str(b.as) as SendAs : defaultAs(str(b.service), test);
  const { apiProviders, config } = await deps.settings();
  const key = keyValue(apiProviders, test.provider, str(b.service), str(b.key));
  if (!key) return { status: 404, body: { error: "That key has no value." } };
  const regionRaw = (config as { amazonRegion?: unknown } | null)?.amazonRegion;
  const region = regionRaw === "ap-southeast-1" ? "ap-southeast-1" : "ap-southeast-5";
  let req: HttpRequest;
  try {
    req = await test.request(key, region);
  } catch {
    return {
      status: 200,
      body: test.provider === "aws"
        ? { result: "fail", title: "Not an AWS key", detail: "Save it as ACCESS_KEY_ID:SECRET_ACCESS_KEY, or add :region.", http: 0, ms: 0 }
        : { result: "fail", title: "Not a server address", detail: "Save the server's https:// address as this key.", http: 0, ms: 0 },
    };
  }
  req = { ...req, headers: { ...(req.headers ?? {}), ...restrictionHeaders(as, certOf(b.cert)) } };
  const started = deps.now();
  let status = 0, text = "";
  try {
    ({ status, text } = await deps.fetch(req));
  } catch (e) {
    const timeout = e instanceof Error && (e.name === "TimeoutError" || /timed? ?out/i.test(e.message));
    return {
      status: 200,
      body: {
        result: "fail",
        title: timeout ? "No answer within 10 s" : "Couldn't reach the provider",
        detail: scrub(e instanceof Error ? e.message : "", key).slice(0, 200),
        http: 0,
        ms: deps.now() - started,
      },
    };
  }
  let body: J = null;
  if (!test.image || status >= 300) {
    try {
      body = JSON.parse(text);
    } catch {
      body = null;
    }
  }
  const v = verdictOf(test, status, body, text.slice(0, 400));
  return {
    status: 200,
    body: {
      result: v.result,
      title: v.title,
      detail: scrub(v.detail, key),
      http: status,
      ms: deps.now() - started,
      as,
    },
  };
}
