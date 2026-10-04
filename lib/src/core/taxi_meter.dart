// The taxi meter's accrual, ported from the Expo app's `utils/taxiMeter.ts`.
//
// The meter runs off a 1 Hz sample loop. Each sample carries what the sensors
// know: the vehicle's OBD-II speed (when a reader is linked, a later slice of
// this port) and the GPS fix. OBD speed wins while it is fresh; otherwise
// distance comes from the displacement between trustworthy fixes, or from the
// GPS ground speed when the fixes are not trustworthy.
//
// Everything here is pure (no timers, no sensors) so it can be tested sample by
// sample. The fare itself comes from a rate card: `computeMeterFareTotal` and
// `MeterRates` live with the rate-card editor in the admin panel
// (meter_logic.dart) so the editor's preview and the meter bill identically.
import 'dart:math' as math;

import '../admin/screens/meterapp/meter_logic.dart';

/// How old an OBD speed reading may be before the meter falls back to GPS.
const obdStaleMs = 4000;

/// Longest gap between samples that still counts as continuous driving. A
/// longer one (app backgrounded, screen slept) is clamped so a pause can
/// never be billed as motion.
const maxSampleGapMs = 5000;

/// At or below this speed the vehicle counts as waiting.
const waitingSpeedKmh = 5.0;

/// GPS fixes worse than this (metres) are not trusted for displacement.
const gpsMaxAccuracyM = 50.0;

/// Displacement below this (metres) is jitter: the vehicle is standing still.
const gpsMinMoveM = 3.0;

/// Displacement implying more than this (km/h) is a GPS jump, not travel.
const gpsMaxPlausibleKmh = 220.0;

enum MeterSource { obd, gps, none }

enum MeterPeriod { day, night }

class MeterPoint {
  const MeterPoint(this.latitude, this.longitude, {this.accuracyM});
  final double latitude;
  final double longitude;
  final double? accuracyM;
}

/// One tick of sensor input. Every field is optional: sources come and go.
class MeterSample {
  const MeterSample({required this.at, this.obdSpeedKmh, this.obdUpdatedAt, this.gpsSpeedKmh, this.gpsPoint});
  final int at;
  final double? obdSpeedKmh;
  final int? obdUpdatedAt;
  final double? gpsSpeedKmh;
  final MeterPoint? gpsPoint;
}

class MeterState {
  const MeterState({
    this.running = false,
    this.startedAt,
    this.distanceM = 0,
    this.elapsedMs = 0,
    this.chargeableMs = 0,
    this.waitingMs = 0,
    this.speedKmh = 0,
    this.source = MeterSource.none,
    this.obdSamples = 0,
    this.gpsSamples = 0,
    this.lastAt,
    this.lastPoint,
  });

  final bool running;
  final int? startedAt;
  final double distanceM;
  final int elapsedMs;

  /// Running time accrued past the flag-fare distance: what a `flag` card
  /// bills its time on.
  final int chargeableMs;
  final int waitingMs;
  final double speedKmh;
  final MeterSource source;
  final int obdSamples;
  final int gpsSamples;
  final int? lastAt;
  final MeterPoint? lastPoint;

  /// Whether a hire is open (running or paused), as opposed to a fresh meter.
  bool get hasHire => startedAt != null;

  MeterState copyWith({
    bool? running,
    int? startedAt,
    double? distanceM,
    int? elapsedMs,
    int? chargeableMs,
    int? waitingMs,
    double? speedKmh,
    MeterSource? source,
    int? obdSamples,
    int? gpsSamples,
    int? Function()? lastAt,
    MeterPoint? Function()? lastPoint,
  }) =>
      MeterState(
        running: running ?? this.running,
        startedAt: startedAt ?? this.startedAt,
        distanceM: distanceM ?? this.distanceM,
        elapsedMs: elapsedMs ?? this.elapsedMs,
        chargeableMs: chargeableMs ?? this.chargeableMs,
        waitingMs: waitingMs ?? this.waitingMs,
        speedKmh: speedKmh ?? this.speedKmh,
        source: source ?? this.source,
        obdSamples: obdSamples ?? this.obdSamples,
        gpsSamples: gpsSamples ?? this.gpsSamples,
        lastAt: lastAt == null ? this.lastAt : lastAt(),
        lastPoint: lastPoint == null ? this.lastPoint : lastPoint(),
      );
}

/// Start or resume accrual at [at]. However long the meter sat paused is
/// never billed, and the GPS baseline is dropped because the car may have
/// moved meanwhile.
MeterState startMeter(MeterState s, int at) =>
    s.copyWith(running: true, startedAt: s.startedAt ?? at, lastAt: () => at, lastPoint: () => null);

/// Pause accrual, keeping the totals.
MeterState pauseMeter(MeterState s) =>
    s.copyWith(running: false, speedKmh: 0, lastAt: () => null, lastPoint: () => null);

/// Great-circle distance between two fixes, in metres.
double haversineMeters(MeterPoint a, MeterPoint b) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(b.latitude - a.latitude);
  final dLon = rad(b.longitude - a.longitude);
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(a.latitude)) * math.cos(rad(b.latitude)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(h)));
}

bool _usableFix(MeterPoint? p) {
  if (p == null || !p.latitude.isFinite || !p.longitude.isFinite) return false;
  final acc = p.accuracyM;
  return acc == null || !acc.isFinite || acc <= gpsMaxAccuracyM;
}

/// The OBD speed is present and recent enough to bill on.
bool isObdFresh(MeterSample s) {
  final speed = s.obdSpeedKmh, at = s.obdUpdatedAt;
  if (speed == null || !speed.isFinite || speed < 0 || at == null) return false;
  final age = s.at - at;
  return age >= 0 && age <= obdStaleMs;
}

/// Folds one sample into the meter. A stopped meter ignores samples, so it can
/// never accrue distance, time or fare.
///
/// [flagDistanceM] is the card's flag-fare distance: time past it is the
/// [MeterState.chargeableMs] a `flag` card bills. (The Expo meter always uses
/// 1 km here, whatever the card says.)
MeterState applyMeterSample(MeterState s, MeterSample sample, {int flagDistanceM = flagFallDistanceM}) {
  if (!s.running) return s;
  final fix = _usableFix(sample.gpsPoint) ? sample.gpsPoint : null;
  if (s.lastAt == null) return s.copyWith(lastAt: () => sample.at, lastPoint: () => fix);

  final dt = math.min(math.max(0, sample.at - s.lastAt!), maxSampleGapMs);
  var source = MeterSource.none;
  var speedKmh = 0.0;
  var deltaM = 0.0;

  if (isObdFresh(sample)) {
    source = MeterSource.obd;
    speedKmh = sample.obdSpeedKmh!;
    deltaM = speedKmh / 3.6 * dt / 1000;
  } else {
    final gpsSpeed = sample.gpsSpeedKmh;
    final validSpeed = gpsSpeed != null && gpsSpeed.isFinite && gpsSpeed >= 0 ? gpsSpeed : null;
    double? displacement;
    if (fix != null && s.lastPoint != null && dt > 0) {
      final moved = haversineMeters(s.lastPoint!, fix);
      final impliedKmh = moved / (dt / 1000) * 3.6;
      if (moved >= gpsMinMoveM && impliedKmh <= gpsMaxPlausibleKmh) {
        displacement = moved;
      } else if (moved < gpsMinMoveM) {
        // Below the jitter floor the car is standing still: a real zero.
        displacement = 0;
      }
    }
    if (displacement != null) {
      source = MeterSource.gps;
      deltaM = displacement;
      speedKmh = validSpeed ?? (dt > 0 ? displacement / (dt / 1000) * 3.6 : 0);
    } else if (validSpeed != null) {
      source = MeterSource.gps;
      speedKmh = validSpeed;
      deltaM = validSpeed / 3.6 * dt / 1000;
    }
  }

  final distanceM = s.distanceM + deltaM;
  // When a sample straddles the flag distance, only the part after it counts.
  var chargeableMs = s.chargeableMs;
  if (distanceM > flagDistanceM) {
    final share = s.distanceM >= flagDistanceM || deltaM <= 0 ? 1.0 : (distanceM - flagDistanceM) / deltaM;
    chargeableMs += (dt * share.clamp(0.0, 1.0)).round();
  }

  return s.copyWith(
    distanceM: distanceM,
    elapsedMs: s.elapsedMs + dt,
    chargeableMs: chargeableMs,
    waitingMs: s.waitingMs + (speedKmh <= waitingSpeedKmh ? dt : 0),
    speedKmh: speedKmh,
    source: source,
    obdSamples: s.obdSamples + (source == MeterSource.obd ? 1 : 0),
    gpsSamples: s.gpsSamples + (source == MeterSource.gps ? 1 : 0),
    lastAt: () => sample.at,
    lastPoint: () => fix ?? s.lastPoint,
  );
}

// ---- Shift, extras and totals ------------------------------------------------

/// Whether [at] falls on the night shift (local time). A window that wraps
/// past midnight (22 → 6) is handled.
bool isNightPeriod(DateTime at, {int startHour = nightStartHour, int endHour = nightEndHour}) {
  final h = at.hour;
  return startHour <= endHour ? h >= startHour && h < endHour : h >= startHour || h < endHour;
}

/// The multiplier the DAY / NIGHT key selects.
double periodMultiplier(MeterPeriod period, [double nightMultiplier = nightMultiplierDefault]) {
  if (period != MeterPeriod.night) return 1;
  return nightMultiplier.isFinite && nightMultiplier > 0 ? nightMultiplier : nightMultiplierDefault;
}

double _round2(double n) => (n * 100).round() / 100;

/// The metered fare for the meter's totals, on [rates].
double meterFare(MeterState s, MeterRates rates, {double multiplier = 1}) => computeMeterFareTotal(
      rates,
      distanceM: s.distanceM,
      elapsedMs: s.elapsedMs,
      chargeableMs: s.chargeableMs,
      multiplier: multiplier,
    );

/// The EXTRA − / + keys: clamped to [0, max] and rounded to sen.
double adjustExtra(double current, int steps, {double step = extraStepDefault, double max = maxExtraDefault}) {
  final st = step.isFinite && step > 0 ? step : extraStepDefault;
  final mx = max.isFinite && max > 0 ? max : maxExtraDefault;
  final base = current.isFinite ? current : 0.0;
  return _round2((base + steps * st).clamp(0.0, mx));
}

/// What the passenger pays: the fare plus every declared addition, each
/// clamped on its own so no bad value can pull the total below the fare.
double meterGrandTotal(double fare, List<double> extras) {
  final f = fare.isFinite ? math.max(0.0, fare) : 0.0;
  final added = extras.fold(0.0, (sum, v) => sum + (v.isFinite ? math.max(0.0, v) : 0.0));
  return _round2(f + added);
}

// ---- Display -------------------------------------------------------------------

String _pad(int n) => n.toString().padLeft(2, '0');

/// Always "HH:MM:SS": the fixed-width form the display needs.
String formatMeterClock(int ms) {
  final total = math.max(0, ms ~/ 1000);
  return '${_pad(total ~/ 3600)}:${_pad(total % 3600 ~/ 60)}:${_pad(total % 60)}';
}

/// "740 m" below a kilometre, else "3.42 km".
String formatMeterDistance(double meters) {
  final m = math.max(0.0, meters);
  return m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(2)} km';
}

/// Kilometres to two decimals, for the readout (the unit is its own label).
String formatMeterKm(double meters) => (math.max(0.0, meters) / 1000).toStringAsFixed(2);

String describeMeterSource(MeterSource s) => switch (s) {
      MeterSource.obd => 'OBD-II',
      MeterSource.gps => 'GPS',
      MeterSource.none => 'No signal',
    };

// ---- Who gets a meter, and on what -----------------------------------------------

/// Partners with the TEKSI partner type drive the meter (Expo
/// `hasTeksiPartnerType`).
bool hasTeksiPartnerType(Object? types) => types is List && types.any((t) => '${t ?? ''}'.trim().toLowerCase() == 'teksi');

/// Why this build cannot open a hire on [card], or null when it can. This
/// slice of the port meters on GPS only, so a card that takes GPS away (an
/// OBD-only card) cannot be billed here: it must never quietly bill on GPS.
String? meterGpsBlock(MeterProfile card) => allowedMeterSources(card.sourceMode).gps
    ? null
    : "This rate card bills on the vehicle's OBD-II reader only, and the reader is not supported in this version "
        'of the app yet. Ask an administrator to allow GPS on the card, or use the meter in the previous app.';
