/**
 * The trip card, built on the server (migration 0274, trip-card-push): the
 * same card lib/src/core/trip_card.dart builds on the phone, for a phone
 * whose app is closed. The app starts the card; while it is closed, a data
 * push carries this card's keys and TripCardPushReceiver.kt moves the
 * card on with them (or ends it).
 *
 * Kept in step with the Dart builder by one set of cases both test suites
 * read (trip_card_cases.json, here and in test/trip_card_cases_test.dart):
 * change the wording in one, and the other's test fails until it matches.
 *
 * What the server has that the phone's builder would also use: the ride
 * row (only the columns trip_card_push_snapshot hands over, never the trip
 * code or a courier's delivery code), the driver's live position on it,
 * and the amount due (ride_amount_due, the same sum as RideRequest.totalDue).
 * What it has not: the trip map's road route, so minutes and kilometres are
 * the phone's straight-line fallback (tripEta without a route).
 *
 *     deno test supabase/functions/_shared/trip_card_test.ts
 */

export type TripCardStage = "finding" | "toPickup" | "arrived" | "onTrip" | "done";
export type TripCardService = "ride" | "courier" | "freight";
export type TripCardAction = "call" | "chat" | "share" | "sos" | "cancel" | "rate";

export const ACTION_LABELS: Record<TripCardAction, string> = {
  call: "Call",
  chat: "Chat",
  share: "Share trip",
  sos: "SOS",
  cancel: "Cancel",
  rate: "Rate",
};

/** Android shows at most three buttons on a notification. */
export const TRIP_CARD_MAX_ACTIONS = 3;

/** The ride row's columns the card reads (trip_card_push_snapshot). */
export interface TripRide {
  id: string;
  status?: string | null;
  service?: string | null;
  rider_id?: string | null;
  rider_name?: string | null;
  booked_for_name?: string | null;
  partner_id?: string | null;
  partner_name?: string | null;
  partner_vehicle?: string | null;
  partner_plate?: string | null;
  pickup_name?: string | null;
  pickup_address?: string | null;
  pickup_lat?: number | null;
  pickup_lng?: number | null;
  drop_name?: string | null;
  drop_address?: string | null;
  drop_lat?: number | null;
  drop_lng?: number | null;
  distance_km?: number | null;
  duration_min?: number | null;
  fare?: number | null;
  ride_fare?: number | null;
  /** ride_amount_due: fare, surcharges, taxes, tolls, other charges, fees carried over. */
  total_due?: number | null;
  currency?: string | null;
  payment_mode?: string | null;
  partner_accept_lat?: number | null;
  partner_accept_lng?: number | null;
  partner_live_lat?: number | null;
  partner_live_lng?: number | null;
  pickup_door_name?: string | null;
  parcel_size?: string | null;
  cargo_description?: string | null;
  recipient_name?: string | null;
  started_at?: string | null;
  completed_at?: string | null;
  /** The pickup region's time zone (0124): the card's clock times. */
  timezone?: string | null;
}

/** The card's keys, as TripCard.toPlatform names them (without the colours). */
export interface TripCardKeys {
  rideId: string;
  role: "rider" | "driver";
  service: TripCardService;
  stage: TripCardStage;
  brand: string;
  chip: string;
  compact: string;
  headline: string;
  emphasis: string | null;
  subline: string;
  driverName: string | null;
  car: string | null;
  plate: string | null;
  footTitle: string | null;
  footText: string | null;
  progress: number;
  etaMs: number | null;
  minutesLeft: number | null;
  openUri: string;
  actions: { id: TripCardAction; label: string; uri: string }[];
  ongoing: boolean;
}

// ---- Reading the row --------------------------------------------------------

const num = (v: unknown): number | null => {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && v.trim() !== "") {
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  }
  return null;
};

const text = (v: unknown): string | null => (typeof v === "string" && v.trim() !== "" ? v.trim() : null);

const time = (v: unknown): Date | null => {
  if (typeof v !== "string" || v.trim() === "") return null;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? null : d;
};

/** RideStatus.parse: anything unknown reads as open. */
export function rideStatus(s: unknown): "open" | "accepted" | "arrived" | "on_trip" | "completed" | "cancelled" | "expired" {
  switch (s) {
    case "accepted":
    case "arrived":
    case "on_trip":
    case "completed":
    case "cancelled":
    case "expired":
      return s;
    default:
      return "open";
  }
}

/** The stage a ride is at; null once there is nothing to show. */
export function stageOf(status: unknown): TripCardStage | null {
  switch (rideStatus(status)) {
    case "open":
      return "finding";
    case "accepted":
      return "toPickup";
    case "arrived":
      return "arrived";
    case "on_trip":
      return "onTrip";
    case "completed":
      return "done";
    default:
      return null;
  }
}

/** Courier is built on Freight's parts, so it is asked first. */
export function serviceOf(r: TripRide): TripCardService {
  if (text(r.parcel_size) !== null) return "courier";
  if (text(r.cargo_description) !== null) return "freight";
  return "ride";
}

// ---- Distances (latlong2's Distance(): Vincenty, rounded to the metre) -----

type LL = { lat: number; lng: number };

const ll = (lat: unknown, lng: unknown): LL | null => {
  const a = num(lat), b = num(lng);
  return a === null || b === null ? null : { lat: a, lng: b };
};

const rad = (d: number) => d * (Math.PI / 180);

/** Metres between two points on the WGS-84 ellipsoid, as latlong2 counts them. */
export function vincentyMetres(p1: LL, p2: LL): number {
  const a = 6378137.0, b = 6356752.314245, f = 1 / 298.257223563;
  const l = rad(p2.lng) - rad(p1.lng);
  const u1 = Math.atan((1 - f) * Math.tan(rad(p1.lat)));
  const u2 = Math.atan((1 - f) * Math.tan(rad(p2.lat)));
  const sinU1 = Math.sin(u1), cosU1 = Math.cos(u1);
  const sinU2 = Math.sin(u2), cosU2 = Math.cos(u2);
  let lambda = l, lambdaP: number;
  let sinSigma: number, cosSigma: number, sigma: number, cosSqAlpha: number, cos2SigmaM: number;
  let iterations = 200;
  do {
    const sinLambda = Math.sin(lambda), cosLambda = Math.cos(lambda);
    sinSigma = Math.sqrt(
      (cosU2 * sinLambda) * (cosU2 * sinLambda) +
        (cosU1 * sinU2 - sinU1 * cosU2 * cosLambda) * (cosU1 * sinU2 - sinU1 * cosU2 * cosLambda),
    );
    if (sinSigma === 0) return 0;
    cosSigma = sinU1 * sinU2 + cosU1 * cosU2 * cosLambda;
    sigma = Math.atan2(sinSigma, cosSigma);
    const sinAlpha = cosU1 * cosU2 * sinLambda / sinSigma;
    cosSqAlpha = 1 - sinAlpha * sinAlpha;
    cos2SigmaM = cosSigma - 2 * sinU1 * sinU2 / cosSqAlpha;
    if (Number.isNaN(cos2SigmaM)) cos2SigmaM = 0;
    const c = f / 16 * cosSqAlpha * (4 + f * (4 - 3 * cosSqAlpha));
    lambdaP = lambda;
    lambda = l + (1 - c) * f * sinAlpha *
        (sigma + c * sinSigma * (cos2SigmaM + c * cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)));
  } while (Math.abs(lambda - lambdaP) > 1e-12 && --iterations > 0);
  if (iterations === 0) return 0;
  const uSq = cosSqAlpha * (a * a - b * b) / (b * b);
  const A = 1 + uSq / 16384 * (4096 + uSq * (-768 + uSq * (320 - 175 * uSq)));
  const B = uSq / 1024 * (256 + uSq * (-128 + uSq * (74 - 47 * uSq)));
  const deltaSigma = B * sinSigma *
    (cos2SigmaM + B / 4 * (cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM) -
      B / 6 * cos2SigmaM * (-3 + 4 * sinSigma * sinSigma) * (-3 + 4 * cos2SigmaM * cos2SigmaM)));
  return b * A * (sigma - deltaSigma);
}

/** Kilometres as the phone's `_km` counts them (whole metres). */
export function km(a: LL, b: LL): number {
  return Math.round(vincentyMetres(a, b)) / 1000;
}

/** driver_eta.dart: the speed a driver comes to the pickup at, in town. */
export const DRIVER_APPROACH_KMH = 24.0;

/** driver_eta.dart approachMinutes: haversine at the approach speed, never under one. */
export function approachMinutes(from: LL, to: LL): number {
  const r = 6371.0;
  const dLat = rad(to.lat - from.lat), dLng = rad(to.lng - from.lng);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(from.lat)) * Math.cos(rad(to.lat)) * Math.sin(dLng / 2) ** 2;
  const d = 2 * r * Math.asin(Math.sqrt(h));
  return Math.max(1, Math.ceil(d / DRIVER_APPROACH_KMH * 60));
}

/** The average speed assumed on the trip when the ride has no time and distance. */
export const TRIP_FALLBACK_KMH = 30.0;

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

/** Where the driver is: their live position, else (on the way) where they accepted. */
export function driverAt(r: TripRide): LL | null {
  return ll(r.partner_live_lat, r.partner_live_lng) ??
    (rideStatus(r.status) === "accepted" ? ll(r.partner_accept_lat, r.partner_accept_lng) : null);
}

/** tripEta without a road route: minutes and kilometres to the next point. */
export function tripEta(r: TripRide): { minutes: number; km: number } | null {
  const status = rideStatus(r.status);
  const pickup = ll(r.pickup_lat, r.pickup_lng), drop = ll(r.drop_lat, r.drop_lng);
  const target = status === "accepted" ? pickup : status === "on_trip" ? drop : null;
  const at = driverAt(r);
  if (target === null || at === null) return null;
  const straight = km(at, target);
  if (status === "accepted") {
    return { minutes: approachMinutes(at, target), km: straight };
  }
  const whole = pickup === null ? null : km(pickup, target);
  const booked = num(r.distance_km);
  const factor = booked !== null && whole !== null && whole > 0.05 ? clamp(booked / whole, 1.0, 2.0) : 1.3;
  const k = straight * factor;
  const mins = num(r.duration_min);
  const kmh = booked !== null && mins !== null && booked > 0 && mins > 0 ? booked / mins * 60 : TRIP_FALLBACK_KMH;
  return { minutes: k / kmh * 60, km: k };
}

/** tripStageFraction: how much of the current stage is done, 0 to 1. */
export function tripStageFraction(r: TripRide, kmLeft: number | null): number {
  switch (rideStatus(r.status)) {
    case "accepted": {
      const pickup = ll(r.pickup_lat, r.pickup_lng);
      const from = ll(r.partner_accept_lat, r.partner_accept_lng);
      const at = driverAt(r);
      if (pickup === null || from === null || at === null) return 0;
      const start = km(from, pickup);
      if (start <= 0.02) return 1;
      return clamp(1 - km(at, pickup) / start, 0, 1);
    }
    case "on_trip": {
      const pickup = ll(r.pickup_lat, r.pickup_lng), drop = ll(r.drop_lat, r.drop_lng);
      const total = num(r.distance_km) ?? (pickup === null || drop === null ? null : km(pickup, drop));
      if (total === null || total <= 0 || kmLeft === null) return 0;
      return clamp(1 - kmLeft / total, 0, 1);
    }
    case "completed":
      return 1;
    default:
      return 0;
  }
}

/** tripCardProgress: where each stage sits on the one bar. */
export function tripCardProgress(stage: TripCardStage, fraction: number): number {
  const f = clamp(fraction, 0, 1);
  switch (stage) {
    case "finding":
      return 0.04;
    case "toPickup":
      return 0.05 + 0.40 * f;
    case "arrived":
      return 0.45;
    case "onTrip":
      return 0.5 + 0.5 * f;
    case "done":
      return 1.0;
  }
}

// ---- Words and numbers as the phone writes them (core/format.dart) ---------

/** Expo's currency symbols (format.dart currencyStyles). */
export const CURRENCY_STYLES: Record<string, { symbol: string; after: boolean; decimals: number }> = {
  MYR: { symbol: "RM", after: false, decimals: 2 },
  SGD: { symbol: "S$", after: false, decimals: 2 },
  IDR: { symbol: "Rp", after: false, decimals: 2 },
  THB: { symbol: "฿", after: false, decimals: 2 },
  PHP: { symbol: "₱", after: false, decimals: 2 },
  VND: { symbol: "₫", after: true, decimals: 0 },
  INR: { symbol: "₹", after: false, decimals: 2 },
  USD: { symbol: "$", after: false, decimals: 2 },
  GBP: { symbol: "£", after: false, decimals: 2 },
  EUR: { symbol: "€", after: false, decimals: 2 },
  JPY: { symbol: "¥", after: false, decimals: 0 },
  KRW: { symbol: "₩", after: false, decimals: 0 },
  AUD: { symbol: "A$", after: false, decimals: 2 },
  AED: { symbol: "AED ", after: false, decimals: 2 },
  SAR: { symbol: "SAR ", after: false, decimals: 2 },
  PKR: { symbol: "Rs", after: false, decimals: 2 },
  BDT: { symbol: "৳", after: false, decimals: 2 },
  LKR: { symbol: "Rs", after: false, decimals: 2 },
  MMK: { symbol: "K", after: true, decimals: 2 },
  KHR: { symbol: "៛", after: true, decimals: 2 },
  LAK: { symbol: "₭", after: false, decimals: 2 },
  BND: { symbol: "B$", after: false, decimals: 2 },
  CNY: { symbol: "¥", after: false, decimals: 2 },
  TWD: { symbol: "NT$", after: false, decimals: 2 },
  HKD: { symbol: "HK$", after: false, decimals: 2 },
};

function grouped(amount: number, decimals: number): string {
  const neg = amount < 0;
  const [whole, frac] = Math.abs(amount).toFixed(decimals).split(".");
  const withCommas = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return `${neg ? "-" : ""}${withCommas}${frac ? `.${frac}` : ""}`;
}

/** formatMoney(amount, currency): the currency's own symbol and decimals. */
export function formatMoney(amount: number, currency: string): string {
  const code = currency.trim().toUpperCase();
  const style = CURRENCY_STYLES[code];
  if (!style) return `${code} ${grouped(amount, 2)}`;
  return style.after ? `${grouped(amount, style.decimals)}${style.symbol}` : `${style.symbol}${grouped(amount, style.decimals)}`;
}

/** formatDistance: metres under a kilometre, else one decimal. */
export function formatDistance(k: number): string {
  return k < 1 ? `${Math.round(k * 1000)} m` : `${k.toFixed(1)} km`;
}

/** The fallback clock when a ride has no time zone of its own. */
export const DEFAULT_TIME_ZONE = "Asia/Kuala_Lumpur";

function clockParts(t: Date, timeZone: string): { h: string; m: string; ampm: string } {
  let parts: Intl.DateTimeFormatPart[];
  try {
    parts = new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit", hour12: true, timeZone })
      .formatToParts(t);
  } catch {
    parts = new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit", hour12: true, timeZone: DEFAULT_TIME_ZONE })
      .formatToParts(t);
  }
  const get = (type: string) => parts.find((p) => p.type === type)?.value ?? "";
  return { h: get("hour"), m: get("minute"), ampm: get("dayPeriod").toUpperCase() };
}

/** formatTime: "4:05 PM". */
export function formatTime(t: Date, timeZone: string): string {
  const p = clockParts(t, timeZone);
  return `${p.h}:${p.m} ${p.ampm}`;
}

/** The status bar chip's clock: "4:05". */
export function formatClock(t: Date, timeZone: string): string {
  const p = clockParts(t, timeZone);
  return `${p.h}:${p.m}`;
}

function first(name: string | null | undefined): string {
  return (name ?? "").trim().split(/\s+/)[0] ?? "";
}

function parcel(size: string | null | undefined): string {
  switch ((size ?? "").toUpperCase()) {
    case "S":
      return "Small parcel";
    case "M":
      return "Medium parcel";
    case "L":
      return "Large parcel";
    default:
      return "Parcel";
  }
}

function join(parts: (string | null | undefined)[]): string {
  return parts.filter((p): p is string => p != null && p.trim() !== "").map((p) => p.trim()).join(" · ");
}

function left(mins: number | null, k: number | null): string {
  return join([mins !== null ? `${mins} min` : null, k !== null ? `${formatDistance(k)} left` : null]);
}

function paid(r: TripRide): string {
  const fare = num(r.ride_fare) ?? num(r.fare);
  const amount = fare === null ? null : (num(r.total_due) ?? fare);
  return join([amount === null ? null : formatMoney(amount, r.currency ?? "MYR"), r.payment_mode ?? "Cash"]);
}

/** tripCardLink: `getride://trip/<ride>`, with the button and `as=driver`. */
export function tripCardLink(rideId: string, driver: boolean, action?: TripCardAction): string {
  const q: string[] = [];
  if (action) q.push(`do=${action}`);
  if (driver) q.push("as=driver");
  return `getride://trip/${encodeURIComponent(rideId)}${q.length ? `?${q.join("&")}` : ""}`;
}

// ---- The card ---------------------------------------------------------------

/**
 * buildTripCard for [r] at [now], for its rider or, with [asDriver], its
 * driver. Null when the ride has nothing to show (cancelled, expired, or a
 * driver's card before they took it). The trip code and a courier's
 * delivery code are never read here: anyone holding the phone can read a
 * lock screen.
 */
export function buildTripCard(
  r: TripRide,
  opts: { asDriver: boolean; now: Date; eta?: { minutes: number; km: number } | null; fraction?: number },
): TripCardKeys | null {
  const stage = stageOf(r.status);
  if (stage === null) return null;
  const asDriver = opts.asDriver;
  if (asDriver && stage === "finding") return null;
  const service = serviceOf(r);
  const eta = opts.eta ?? null;
  const mins = eta === null ? null : clamp(Math.ceil(eta.minutes), 1, 24 * 60);
  const at = mins === null ? null : new Date(opts.now.getTime() + mins * 60000);
  const k = eta === null ? null : eta.km;
  const tz = text(r.timezone) ?? DEFAULT_TIME_ZONE;
  const driverName = first(r.partner_name) === "" ? "Your driver" : first(r.partner_name);
  const passenger = text(r.booked_for_name) ?? r.rider_name ?? "Passenger";
  const rider = first(passenger) === "" ? "Passenger" : first(passenger);
  const progress = tripCardProgress(stage, opts.fraction ?? 0);
  const pickupLabel = r.pickup_name ?? r.pickup_address ?? "Pickup";
  const dropLabel = r.drop_name ?? r.drop_address ?? "Drop-off";
  const route = `${pickupLabel} to ${dropLabel}`;
  const minChip = mins === null ? null : `${mins} min`;
  const clock = at === null ? null : formatTime(at, tz);
  const shortClock = at === null ? null : formatClock(at, tz);

  const card = (c: {
    chip: string;
    compact?: string;
    headline: string;
    emphasis?: string | null;
    subline?: string;
    withDriver?: boolean;
    footTitle?: string;
    footText?: string;
    actions?: TripCardAction[];
  }): TripCardKeys => ({
    rideId: r.id,
    role: asDriver ? "driver" : "rider",
    service,
    stage,
    brand: "GET.ride",
    chip: c.chip,
    compact: c.compact ?? c.chip,
    headline: c.headline,
    emphasis: c.emphasis ?? null,
    subline: c.subline ?? "",
    driverName: c.withDriver ? driverName : null,
    car: c.withDriver ? (r.partner_vehicle ?? null) : null,
    plate: c.withDriver ? (r.partner_plate ?? null) : null,
    footTitle: c.footTitle ?? null,
    footText: c.footText ?? null,
    progress,
    etaMs: at === null ? null : at.getTime(),
    minutesLeft: mins,
    openUri: tripCardLink(r.id, asDriver),
    actions: (c.actions ?? []).slice(0, TRIP_CARD_MAX_ACTIONS).map((a) => ({
      id: a,
      label: ACTION_LABELS[a],
      uri: tripCardLink(r.id, asDriver, a),
    })),
    ongoing: stage !== "done",
  });

  if (asDriver) {
    const talk: TripCardAction[] = ["call", "chat", "sos"];
    switch (stage) {
      case "toPickup":
        return card({
          chip: minChip ?? "On the way",
          headline: service === "ride"
            ? (mins === null ? `Pick up ${rider}` : `Pick up ${rider} in ${mins} min`)
            : service === "courier"
            ? (mins === null ? "Collect the parcel" : `Collect the parcel in ${mins} min`)
            : (mins === null ? "Go to the loading point" : `Loading point in ${mins} min`),
          emphasis: minChip,
          subline: join([pickupLabel, k !== null ? formatDistance(k) : null]),
          actions: talk,
        });
      case "arrived":
        return card({
          chip: "Waiting",
          headline: service === "ride"
            ? `Waiting for ${rider}`
            : service === "courier"
            ? `Collect the parcel from ${rider}`
            : "Loading the cargo",
          emphasis: service === "freight" ? null : rider,
          subline: `At ${text(r.pickup_door_name) ?? pickupLabel}`,
          actions: talk,
        });
      case "onTrip":
        return card({
          chip: clock ?? "On trip",
          compact: shortClock ?? "On trip",
          headline: clock === null
            ? (service === "ride" ? "On the way to the drop-off" : "On the way to deliver")
            : service === "courier"
            ? `Delivery at ${clock}`
            : `Drop-off at ${clock}`,
          emphasis: clock,
          subline: join([left(mins, k), dropLabel]),
          actions: talk,
        });
      case "done":
        return card({
          chip: "Done",
          headline: service === "ride" ? "Trip complete" : service === "courier" ? "Parcel delivered" : "Cargo delivered",
          subline: paid(r),
        });
      default:
        return null;
    }
  }

  const coming: TripCardAction[] = ["call", "chat", "share"];
  switch (stage) {
    case "finding":
      return card({
        chip: "Finding",
        headline: service === "ride"
          ? "Looking for a driver"
          : service === "courier"
          ? "Looking for a courier"
          : "Looking for a van or lorry",
        subline: service === "courier"
          ? join([parcel(r.parcel_size), r.service])
          : (r.service ?? (service === "freight" ? "Freight" : "Ride")),
        footTitle: route,
        footText: "Offers will show here",
        actions: ["cancel"],
      });
    case "toPickup":
      return card({
        chip: minChip ?? "On the way",
        headline: service === "ride"
          ? (mins === null ? `${driverName} is on the way` : `${driverName} is ${mins} min away`)
          : service === "courier"
          ? (mins === null ? `${driverName} is coming for the parcel` : `${driverName} picks up in ${mins} min`)
          : (mins === null ? `${driverName} is coming to load` : `${driverName} loads in ${mins} min`),
        emphasis: minChip,
        subline: r.partner_vehicle ?? "",
        withDriver: true,
        actions: coming,
      });
    case "arrived":
      if (service === "ride") {
        return card({
          chip: "Arrived",
          compact: "Here",
          headline: `${driverName} has arrived`,
          emphasis: "arrived",
          subline: `Meet at ${text(r.pickup_door_name) ?? pickupLabel}`,
          withDriver: true,
          actions: coming,
        });
      }
      if (service === "courier") {
        return card({
          chip: "Arrived",
          compact: "Here",
          headline: `${driverName} is at the pickup`,
          emphasis: "at the pickup",
          subline: "Hand over the parcel",
          withDriver: true,
          actions: coming,
        });
      }
      return card({
        chip: "Loading",
        compact: "Load",
        headline: "Loading your cargo",
        subline: `${driverName} is at the loading point`,
        withDriver: true,
        actions: coming,
      });
    case "onTrip": {
      const started = time(r.started_at);
      if (service === "ride") {
        return card({
          chip: "On trip",
          compact: shortClock ?? "On trip",
          headline: clock === null ? "You are on your way" : `You will arrive at ${clock}`,
          emphasis: clock,
          subline: left(mins, k),
          footTitle: "Share your trip",
          footText: "Family can follow you live",
          actions: ["share", "sos", "chat"],
        });
      }
      if (service === "courier") {
        return card({
          chip: "On the way",
          compact: shortClock ?? "On way",
          headline: clock === null ? "Parcel on the way" : `Delivers at ${clock}`,
          emphasis: clock,
          subline: started === null ? "Parcel picked up" : `Parcel picked up at ${formatTime(started, tz)}`,
          actions: coming,
        });
      }
      return card({
        chip: "On the way",
        compact: shortClock ?? "On way",
        headline: clock === null ? "Cargo on the way" : `Arrives at ${clock}`,
        emphasis: clock,
        subline: left(null, k),
        actions: coming,
      });
    }
    case "done": {
      const ended = time(r.completed_at);
      if (service === "ride") {
        return card({
          chip: "Done",
          headline: "You have arrived",
          subline: paid(r),
          footTitle: "How was your ride?",
          footText: `Tap to rate ${driverName}`,
          actions: ["rate"],
        });
      }
      if (service === "courier") {
        const recipient = text(r.recipient_name);
        return card({
          chip: "Done",
          headline: "Parcel delivered",
          subline: join([
            recipient === null ? "Delivered" : `Received by ${recipient}`,
            ended === null ? null : formatTime(ended, tz),
          ]),
          footTitle: "How was the delivery?",
          footText: `Tap to rate ${driverName}`,
          actions: ["rate"],
        });
      }
      return card({
        chip: "Done",
        headline: "Cargo delivered",
        subline: paid(r),
        footTitle: "How was the move?",
        footText: `Tap to rate ${driverName}`,
        actions: ["rate"],
      });
    }
  }
}

/** The card for [r] now, with its minutes and progress worked out here. */
export function tripCardFor(r: TripRide, asDriver: boolean, now: Date): TripCardKeys | null {
  const eta = tripEta(r);
  return buildTripCard(r, { asDriver, now, eta, fraction: tripStageFraction(r, eta?.km ?? null) });
}

// ---- Admin -> Display Settings -> Trip card ----------------------------------

export interface TripCardSettings {
  ride: boolean;
  courier: boolean;
  freight: boolean;
  driver: boolean;
  doneMinutes: number;
}

export const DEFAULT_DONE_MINUTES = 5;
export const MAX_DONE_MINUTES = 60;

/** TripCardSettings.fromDisplay on the blob's `tripCard`: missing means on, 5 minutes. */
export function tripCardSettings(raw: unknown): TripCardSettings {
  const m = raw !== null && typeof raw === "object" && !Array.isArray(raw) ? raw as Record<string, unknown> : {};
  const on = (k: string) => (typeof m[k] === "boolean" ? m[k] as boolean : true);
  const done = m.doneMinutes;
  return {
    ride: on("ride"),
    courier: on("courier"),
    freight: on("freight"),
    driver: on("driver"),
    doneMinutes: typeof done === "number" && Number.isFinite(done)
      ? clamp(Math.round(done), 0, MAX_DONE_MINUTES)
      : DEFAULT_DONE_MINUTES,
  };
}

/** TripCardSettings.allows. */
export function allows(s: TripCardSettings, service: TripCardService, asDriver: boolean): boolean {
  if (asDriver && !s.driver) return false;
  return s[service];
}
