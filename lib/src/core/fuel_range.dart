// Odometer, fuel level and distance-to-empty, ported from the Expo app's
// `utils/canbus/fuelRange.ts`.
//
// Two of the three numbers the driver actually wants come straight off the
// bus: the odometer (mode 01 PID A6) and the fuel tank level (PID 2F). The
// third (how far the remaining fuel will go) is *not* an OBD-II parameter.
// Generic OBD-II exposes no tank capacity and no distance-to-empty, so this
// module reconstructs it from what the reader can see:
//
//     litres remaining = tank capacity × fuel level %
//     range            = litres remaining ÷ consumption
//
// Tank capacity has to come from the driver. Consumption is resolved in
// priority order (measured > live fuel rate > live MAF > configured average)
// and every result says which source it used, so the screen never presents an
// assumption as a measurement.
//
// Everything here is pure arithmetic; see test/fuel_range_test.dart.
import 'dart:developer' as developer;
import 'dart:math' as math;

// Colour only (dart:ui via painting): no widget imports.
import 'package:flutter/painting.dart' show Color;

import 'vehicle_scan.dart';

/* ------------------------------------------------------------------ *
 * PIDs this module reads
 * ------------------------------------------------------------------ */

const pidOdometer = 'A6';
const pidFuelLevel = '2F';
const pidFuelRate = '5E';
const pidMaf = '10';
const pidSpeed = '0D';
const pidFuelType = '51';

/// Fallback distance counter: not an odometer, but the only one many cars have.
const pidDistanceSinceCleared = '31';

/* ------------------------------------------------------------------ *
 * Profile: the part of the maths that cannot come off the bus
 * ------------------------------------------------------------------ */

/// Tank size assumed until the driver enters the real one (a typical sedan).
const double defaultTankCapacityL = 45;

/// Consumption assumed until something better is known, in L/100 km.
const double defaultConsumptionLPer100Km = 8;

const double minTankCapacityL = 5;
const double maxTankCapacityL = 500;

/// Sanity band for any consumption figure, measured or entered.
const double minConsumptionLPer100Km = 2;
const double maxConsumptionLPer100Km = 40;

/// Below this the fuel burn is too small for the level gauge to resolve.
const double minLearnDistanceKm = 20;

/// A drop larger than this between two scans is a gauge glitch, not a burn.
const double maxLearnLevelDrop = 60;

/// Weight given to a fresh measurement when folding it into the running one.
const double learnSmoothing = 0.4;

/// Live consumption is meaningless below this speed (idling burns fuel, goes nowhere).
const double minLiveConsumptionSpeedKmh = 10;

/// Sentinel for `copyWith` parameters that may be explicitly set to null.
const Object _unset = Object();

/// One (odometer, fuel level) pair, kept so the next scan can measure the burn.
class FuelSample {
  const FuelSample({required this.odometerKm, required this.fuelLevelPercent, required this.at});

  final double odometerKm;
  final double fuelLevelPercent;

  /// Epoch ms.
  final int at;

  Map<String, Object?> toJson() => {'odometerKm': odometerKm, 'fuelLevelPercent': fuelLevelPercent, 'at': at};

  @override
  bool operator ==(Object other) =>
      other is FuelSample &&
      other.odometerKm == odometerKm &&
      other.fuelLevelPercent == fuelLevelPercent &&
      other.at == at;

  @override
  int get hashCode => Object.hash(odometerKm, fuelLevelPercent, at);

  @override
  String toString() => 'FuelSample(odometerKm: $odometerKm, fuelLevelPercent: $fuelLevelPercent, at: $at)';
}

/// Everything about this vehicle's fuel that the bus cannot tell us.
class FuelProfile {
  const FuelProfile({
    required this.tankCapacityL,
    required this.consumptionL100,
    this.measuredL100,
    this.baseline,
    this.vin,
  });

  /// Usable tank size in litres.
  final double tankCapacityL;

  /// The driver's own average, in L/100 km: used when nothing better exists.
  final double consumptionL100;

  /// Consumption actually measured from this car's fuel burn, if enough has been driven.
  final double? measuredL100;

  /// The reading the next measurement is taken against.
  final FuelSample? baseline;

  /// Which vehicle this profile describes, when the VIN is known.
  final String? vin;

  /// The TS object spread. Nullable fields accept an explicit `null`.
  FuelProfile copyWith({
    double? tankCapacityL,
    double? consumptionL100,
    Object? measuredL100 = _unset,
    Object? baseline = _unset,
    Object? vin = _unset,
  }) => FuelProfile(
    tankCapacityL: tankCapacityL ?? this.tankCapacityL,
    consumptionL100: consumptionL100 ?? this.consumptionL100,
    measuredL100: identical(measuredL100, _unset) ? this.measuredL100 : (measuredL100 as num?)?.toDouble(),
    baseline: identical(baseline, _unset) ? this.baseline : baseline as FuelSample?,
    vin: identical(vin, _unset) ? this.vin : vin as String?,
  );

  /// Same shape (and key names) as the Expo app's stored JSON.
  Map<String, Object?> toJson() => {
    'tankCapacityL': tankCapacityL,
    'consumptionL100': consumptionL100,
    'measuredL100': measuredL100,
    'baseline': baseline?.toJson(),
    'vin': vin,
  };

  @override
  bool operator ==(Object other) =>
      other is FuelProfile &&
      other.tankCapacityL == tankCapacityL &&
      other.consumptionL100 == consumptionL100 &&
      other.measuredL100 == measuredL100 &&
      other.baseline == baseline &&
      other.vin == vin;

  @override
  int get hashCode => Object.hash(tankCapacityL, consumptionL100, measuredL100, baseline, vin);

  @override
  String toString() =>
      'FuelProfile(tankCapacityL: $tankCapacityL, consumptionL100: $consumptionL100, '
      'measuredL100: $measuredL100, baseline: $baseline, vin: $vin)';
}

FuelProfile defaultFuelProfile([String? vin]) => FuelProfile(
  tankCapacityL: defaultTankCapacityL,
  consumptionL100: defaultConsumptionLPer100Km,
  measuredL100: null,
  baseline: null,
  vin: vin,
);

double _clamp(double value, double min, double max) => math.min(max, math.max(min, value));

/// JavaScript `Number(x)` for the values stored JSON can hold: a missing key
/// (undefined) is NaN, but `null`, `false` and a blank string are 0.
double _jsNumber(Object? value, {bool present = true}) {
  if (!present) return double.nan;
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  if (value is bool) return value ? 1 : 0;
  if (value is String) {
    final s = value.trim();
    if (s.isEmpty) return 0;
    final lower = s.toLowerCase();
    for (final (prefix, radix) in const [('0x', 16), ('0o', 8), ('0b', 2)]) {
      if (lower.startsWith(prefix)) {
        final parsed = int.tryParse(s.substring(2), radix: radix);
        return parsed == null || s.substring(2).startsWith(RegExp(r'[+-]')) ? double.nan : parsed.toDouble();
      }
    }
    if (s == 'Infinity' || s == '+Infinity') return double.infinity;
    if (s == '-Infinity') return double.negativeInfinity;
    // JS accepts neither "NaN" spelt differently nor Dart-only forms.
    if (!RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$').hasMatch(s)) return double.nan;
    return double.parse(s);
  }
  if (value is List) {
    if (value.isEmpty) return 0;
    if (value.length == 1) return _jsNumber(value.first is List ? value.first : value.first?.toString() ?? '');
    return double.nan;
  }
  return double.nan;
}

/// JS truthiness for the guard on a stored baseline.
bool _truthy(Object? value) {
  if (value == null || value == false) return false;
  if (value is num) return value != 0 && !value.isNaN;
  if (value is String) return value.isNotEmpty;
  return true;
}

/// Coerce a stored/parsed profile into a usable one, replacing anything absent
/// or out of range with the default. Storage is device-local JSON that older
/// builds may have written, so nothing here may be trusted blindly.
///
/// Accepts the decoded JSON map (the TS `Partial<FuelProfile>`) or a
/// [FuelProfile].
FuelProfile normalizeFuelProfile(Object? input) {
  final base = defaultFuelProfile();
  if (input is FuelProfile) input = input.toJson();
  if (!_truthy(input)) return base;
  if (input is! Map) return base;
  double field(Map m, String key) => _jsNumber(m[key], present: m.containsKey(key));

  final capacity = field(input, 'tankCapacityL');
  final consumption = field(input, 'consumptionL100');
  final measured = field(input, 'measuredL100');
  final rawBaseline = input['baseline'];
  FuelSample? baseline;
  if (_truthy(rawBaseline)) {
    final b = rawBaseline is Map ? rawBaseline : const <String, Object?>{};
    final odometer = field(b, 'odometerKm');
    final level = field(b, 'fuelLevelPercent');
    if (odometer.isFinite && level.isFinite) {
      final at = field(b, 'at');
      baseline = FuelSample(
        odometerKm: odometer,
        fuelLevelPercent: level,
        // `Number(at) || 0`: NaN and 0 both become 0.
        at: at.isNaN || at == 0 ? 0 : (at.isFinite ? at.toInt() : 0),
      );
    }
  }
  final vin = input['vin'];
  return FuelProfile(
    tankCapacityL: capacity.isFinite ? _clamp(capacity, minTankCapacityL, maxTankCapacityL) : base.tankCapacityL,
    consumptionL100: consumption.isFinite
        ? _clamp(consumption, minConsumptionLPer100Km, maxConsumptionLPer100Km)
        : base.consumptionL100,
    measuredL100: measured.isFinite && measured >= minConsumptionLPer100Km && measured <= maxConsumptionLPer100Km
        ? measured
        : null,
    baseline: baseline,
    vin: vin is String && vin.isNotEmpty ? vin : null,
  );
}

/// The profile to use for the vehicle now on the other end of the reader.
///
/// A different VIN is a different car, so the profile starts fresh rather than
/// computing range for one car from another car's numbers. A vehicle that does
/// not report a VIN cannot be told apart, so the stored profile stands.
/// Returns [stored] itself (identical) wherever the TS returns it unchanged.
FuelProfile profileForVin(FuelProfile stored, String? vin) {
  if (vin == null || vin.isEmpty) return stored;
  if (stored.vin == null || stored.vin!.isEmpty) return stored.copyWith(vin: vin);
  if (stored.vin == vin) return stored;
  return defaultFuelProfile(vin);
}

/// The two numbers a valid edit yields.
class FuelProfileInput {
  const FuelProfileInput({required this.tankCapacityL, required this.consumptionL100});
  final double tankCapacityL;
  final double consumptionL100;

  @override
  bool operator ==(Object other) =>
      other is FuelProfileInput && other.tankCapacityL == tankCapacityL && other.consumptionL100 == consumptionL100;

  @override
  int get hashCode => Object.hash(tankCapacityL, consumptionL100);

  @override
  String toString() => 'FuelProfileInput(tankCapacityL: $tankCapacityL, consumptionL100: $consumptionL100)';
}

class ProfileEditResult {
  const ProfileEditResult({required this.ok, this.error, this.value});
  final bool ok;
  final String? error;
  final FuelProfileInput? value;

  @override
  bool operator ==(Object other) =>
      other is ProfileEditResult && other.ok == ok && other.error == error && other.value == value;

  @override
  int get hashCode => Object.hash(ok, error, value);

  @override
  String toString() => 'ProfileEditResult(ok: $ok, error: $error, value: $value)';
}

/// JS template-literal rendering of a whole-number double ("5", not "5.0").
String _jsNum(double v) => v == v.truncateToDouble() && v.isFinite ? v.toInt().toString() : v.toString();

/// Validate the two numbers the driver can type on the fuel settings popup.
/// Each argument is a `String` or a `num` (TS `string | number`).
ProfileEditResult validateFuelProfileInput(Object tankCapacity, Object consumption) {
  final capacity = tankCapacity is num ? tankCapacity.toDouble() : _jsNumber(tankCapacity.toString().trim());
  if (!capacity.isFinite || capacity < minTankCapacityL || capacity > maxTankCapacityL) {
    return ProfileEditResult(
      ok: false,
      error: 'Tank capacity must be between ${_jsNum(minTankCapacityL)} and ${_jsNum(maxTankCapacityL)} litres.',
    );
  }
  final l100 = consumption is num ? consumption.toDouble() : _jsNumber(consumption.toString().trim());
  if (!l100.isFinite || l100 < minConsumptionLPer100Km || l100 > maxConsumptionLPer100Km) {
    return ProfileEditResult(
      ok: false,
      error:
          'Average consumption must be between ${_jsNum(minConsumptionLPer100Km)} and '
          '${_jsNum(maxConsumptionLPer100Km)} L/100 km.',
    );
  }
  return ProfileEditResult(
    ok: true,
    value: FuelProfileInput(tankCapacityL: capacity, consumptionL100: l100),
  );
}

/* ------------------------------------------------------------------ *
 * Snapshot: what this scan saw
 * ------------------------------------------------------------------ */

class FuelSnapshot {
  const FuelSnapshot({
    this.odometerKm,
    this.distanceSinceClearedKm,
    this.fuelLevelPercent,
    this.fuelRateLph,
    this.mafGramsPerSec,
    this.speedKmh,
    this.fuelType,
  });

  /// Total distance the vehicle has covered, km (PID A6).
  final double? odometerKm;

  /// Distance since the codes were last cleared, km (PID 31): not an odometer.
  final double? distanceSinceClearedKm;
  final double? fuelLevelPercent;

  /// Instantaneous burn in L/h (PID 5E).
  final double? fuelRateLph;

  /// Mass air flow in g/s (PID 10), the fallback way to a burn rate.
  final double? mafGramsPerSec;
  final double? speedKmh;

  /// Decoded fuel type text (PID 51), e.g. "Diesel".
  final String? fuelType;

  static const empty = FuelSnapshot();

  FuelSnapshot copyWith({
    Object? odometerKm = _unset,
    Object? distanceSinceClearedKm = _unset,
    Object? fuelLevelPercent = _unset,
    Object? fuelRateLph = _unset,
    Object? mafGramsPerSec = _unset,
    Object? speedKmh = _unset,
    Object? fuelType = _unset,
  }) {
    double? d(Object? v, double? old) => identical(v, _unset) ? old : (v as num?)?.toDouble();
    return FuelSnapshot(
      odometerKm: d(odometerKm, this.odometerKm),
      distanceSinceClearedKm: d(distanceSinceClearedKm, this.distanceSinceClearedKm),
      fuelLevelPercent: d(fuelLevelPercent, this.fuelLevelPercent),
      fuelRateLph: d(fuelRateLph, this.fuelRateLph),
      mafGramsPerSec: d(mafGramsPerSec, this.mafGramsPerSec),
      speedKmh: d(speedKmh, this.speedKmh),
      fuelType: identical(fuelType, _unset) ? this.fuelType : fuelType as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FuelSnapshot &&
      other.odometerKm == odometerKm &&
      other.distanceSinceClearedKm == distanceSinceClearedKm &&
      other.fuelLevelPercent == fuelLevelPercent &&
      other.fuelRateLph == fuelRateLph &&
      other.mafGramsPerSec == mafGramsPerSec &&
      other.speedKmh == speedKmh &&
      other.fuelType == fuelType;

  @override
  int get hashCode => Object.hash(
    odometerKm,
    distanceSinceClearedKm,
    fuelLevelPercent,
    fuelRateLph,
    mafGramsPerSec,
    speedKmh,
    fuelType,
  );

  @override
  String toString() =>
      'FuelSnapshot(odometerKm: $odometerKm, distanceSinceClearedKm: $distanceSinceClearedKm, '
      'fuelLevelPercent: $fuelLevelPercent, fuelRateLph: $fuelRateLph, mafGramsPerSec: $mafGramsPerSec, '
      'speedKmh: $speedKmh, fuelType: $fuelType)';
}

double? _numericReading(Map<String, VehicleReading> byPid, String pid) {
  final value = byPid[pid]?.numeric;
  return value != null && value.isFinite ? value : null;
}

/// Pull everything the range maths needs out of a completed scan. Raw
/// fallbacks (`known == false`) are ignored; the last reading for a PID wins.
FuelSnapshot readFuelSnapshot(List<VehicleReading> readings) {
  final byPid = <String, VehicleReading>{};
  for (final reading in readings) {
    if (reading.known) byPid[reading.pid.toUpperCase()] = reading;
  }
  return FuelSnapshot(
    odometerKm: _numericReading(byPid, pidOdometer),
    distanceSinceClearedKm: _numericReading(byPid, pidDistanceSinceCleared),
    fuelLevelPercent: _numericReading(byPid, pidFuelLevel),
    fuelRateLph: _numericReading(byPid, pidFuelRate),
    mafGramsPerSec: _numericReading(byPid, pidMaf),
    speedKmh: _numericReading(byPid, pidSpeed),
    fuelType: byPid[pidFuelType]?.value,
  );
}

/* ------------------------------------------------------------------ *
 * Reading the odometer off a live adapter
 * ------------------------------------------------------------------ */

/// How many times PID A6 is asked before the reading is called absent.
///
/// One unanswered command is not proof that a car has no odometer: the adapter
/// serves one command at a time beside the 1 Hz sweep, and ELM327 clones
/// answer `BUSY`, `STOPPED` or a truncated frame often enough that a single
/// ask is a coin toss.
const odometerReadAttempts = 3;

/// Pause between attempts, long enough for the adapter to finish its answer.
const odometerRetryDelayMs = 250;

/// How the retry pause is waited out; injectable so tests never sleep.
typedef DelayFn = Future<void> Function(Duration duration);

Future<void> _wait(Duration duration) => Future<void>.delayed(duration);

/// Ask a live reader for the odometer the cluster is showing (mode 01 PID A6).
///
/// Returns the reading in km, or null once every attempt has come back empty,
/// which on a car that does not implement A6 is the honest answer. PID 31 is
/// *not* a substitute: any scan-tool clear resets it.
///
/// A thrown command (timeout, dropped link) counts as one failed attempt
/// rather than aborting the read. [delay] defaults to a real timer.
Future<double?> readOdometerKm(SendCommand send, {int? attempts, int? delayMs, DelayFn? delay}) async {
  final tries = math.max(1, attempts ?? odometerReadAttempts);
  final pauseMs = math.max(0, delayMs ?? odometerRetryDelayMs);
  final sleep = delay ?? _wait;
  for (var attempt = 0; attempt < tries; attempt += 1) {
    if (attempt > 0 && pauseMs > 0) await sleep(Duration(milliseconds: pauseMs));
    try {
      final raw = await send('01$pidOdometer');
      final numeric = decodeReading(pidOdometer, raw)?.numeric;
      if (numeric != null && numeric.isFinite && numeric >= 0) return numeric;
    } catch (e) {
      developer.log('odometer read failed', name: 'fuelRange', error: e);
    }
  }
  return null;
}

/// How long a reading stands before a linked reader is asked again, in ms.
///
/// The odometer is deliberately not in the 1 Hz sweep: every PID added there
/// slows every other reading. At 110 km/h a car covers 0.9 km in 30 s, so a
/// screen that wants it live reads it on this slower cadence instead.
const odometerRefreshMs = 30000;

/// How many *whole* empty reads stand behind telling a driver their car has no
/// odometer: worth a second round on the refresh cadence before saying
/// something about the vehicle that is not true.
const odometerAbsentReads = 2;

/// What a reader has managed to tell us about this vehicle's odometer.
enum OdometerStatus { unknown, ready, unsupported }

class OdometerPollInput {
  const OdometerPollInput({
    required this.linked,
    required this.simulated,
    required this.status,
    required this.reading,
    required this.lastAttemptAt,
    required this.now,
    this.refreshMs,
  });

  /// A real session is open. Demo Mode is not one: see [simulated].
  final bool linked;
  final bool simulated;
  final OdometerStatus status;

  /// A read is already in flight.
  final bool reading;

  /// When the last read was *started* (epoch ms), or null if none has been.
  final int? lastAttemptAt;
  final int now;

  /// Defaults to [odometerRefreshMs].
  final int? refreshMs;

  OdometerPollInput copyWith({
    bool? linked,
    bool? simulated,
    OdometerStatus? status,
    bool? reading,
    Object? lastAttemptAt = _unset,
    int? now,
    Object? refreshMs = _unset,
  }) => OdometerPollInput(
    linked: linked ?? this.linked,
    simulated: simulated ?? this.simulated,
    status: status ?? this.status,
    reading: reading ?? this.reading,
    lastAttemptAt: identical(lastAttemptAt, _unset) ? this.lastAttemptAt : lastAttemptAt as int?,
    now: now ?? this.now,
    refreshMs: identical(refreshMs, _unset) ? this.refreshMs : refreshMs as int?,
  );
}

/// Decide whether to ask the reader for the odometer right now. The caller
/// owns the timer and the command; this owns the rules.
bool shouldReadOdometer(OdometerPollInput input) {
  // No session at all, or a simulator that would answer with a number the
  // vehicle never reported.
  if (!input.linked || input.simulated) return false;
  // The adapter serves one command at a time.
  if (input.reading) return false;
  // `readOdometerKm` already retried: this car does not implement A6.
  if (input.status == OdometerStatus.unsupported) return false;
  final lastAttemptAt = input.lastAttemptAt;
  if (lastAttemptAt == null) return true;
  final refreshMs = math.max(0, input.refreshMs ?? odometerRefreshMs);
  // A clock that jumped backwards would otherwise park the reading.
  if (input.now < lastAttemptAt) return true;
  return input.now - lastAttemptAt >= refreshMs;
}

/* ------------------------------------------------------------------ *
 * Consumption
 * ------------------------------------------------------------------ */

enum ConsumptionSource {
  measured('measured', "measured from this vehicle's own fuel use"),
  fuelRate('fuel-rate', "from the engine's live fuel rate"),
  maf('maf', 'estimated from live air flow'),
  configured('configured', 'your entered average — no live measurement yet');

  const ConsumptionSource(this.key, this.label);

  /// The TS string literal, e.g. "fuel-rate".
  final String key;

  /// `CONSUMPTION_SOURCE_LABEL[source]`.
  final String label;
}

class ConsumptionEstimate {
  const ConsumptionEstimate({required this.l100, required this.source});

  /// Litres per 100 km.
  final double l100;
  final ConsumptionSource source;

  @override
  bool operator ==(Object other) => other is ConsumptionEstimate && other.l100 == l100 && other.source == source;

  @override
  int get hashCode => Object.hash(l100, source);

  @override
  String toString() => 'ConsumptionEstimate(l100: $l100, source: ${source.key})';
}

/// Litres per hour derived from mass air flow: air mass over the
/// stoichiometric ratio, over the fuel's density. Diesel runs leaner and is
/// denser than petrol; anything else uses the petrol figures.
double fuelRateFromMaf(double mafGramsPerSec, String? fuelType) {
  final diesel = (fuelType ?? '').toLowerCase().contains('diesel');
  final airFuelRatio = diesel ? 14.5 : 14.7;
  final densityGramsPerL = diesel ? 832 : 745;
  return (mafGramsPerSec * 3600) / (airFuelRatio * densityGramsPerL);
}

bool _inBand(double l100) => l100.isFinite && l100 >= minConsumptionLPer100Km && l100 <= maxConsumptionLPer100Km;

/// Resolve the consumption to divide the remaining fuel by: measured, then a
/// live rate taken at road speed (fuel rate, then MAF), then the entered
/// average. Live rates are only used while the vehicle is actually moving.
ConsumptionEstimate estimateConsumption(FuelSnapshot snapshot, FuelProfile profile) {
  final measured = profile.measuredL100;
  if (measured != null && _inBand(measured)) {
    return ConsumptionEstimate(l100: measured, source: ConsumptionSource.measured);
  }
  final speed = snapshot.speedKmh;
  if (speed != null && speed >= minLiveConsumptionSpeedKmh) {
    final rate = snapshot.fuelRateLph;
    if (rate != null && rate > 0) {
      final l100 = (rate / speed) * 100;
      if (_inBand(l100)) return ConsumptionEstimate(l100: l100, source: ConsumptionSource.fuelRate);
    }
    final maf = snapshot.mafGramsPerSec;
    if (maf != null && maf > 0) {
      final l100 = (fuelRateFromMaf(maf, snapshot.fuelType) / speed) * 100;
      if (_inBand(l100)) return ConsumptionEstimate(l100: l100, source: ConsumptionSource.maf);
    }
  }
  return ConsumptionEstimate(l100: profile.consumptionL100, source: ConsumptionSource.configured);
}

/* ------------------------------------------------------------------ *
 * Learning the real consumption
 * ------------------------------------------------------------------ */

class LearnResult {
  const LearnResult({required this.profile, required this.learned, this.sampleL100});
  final FuelProfile profile;

  /// True when this sample produced a new measurement.
  final bool learned;

  /// The consumption this sample alone implied, before smoothing.
  final double? sampleL100;
}

/// Fold a fresh (odometer, level) reading into the profile.
///
/// Only a plausible burn is used: the odometer must have gone forward far
/// enough for the gauge to move, and the level must have gone *down* by a
/// believable amount. A refuel, an odometer going backwards or an implausible
/// result re-baselines instead of poisoning the average; too short a stretch
/// keeps the old baseline (returning [profile] itself).
LearnResult learnConsumption(FuelSample current, FuelProfile profile) {
  final rebaselined = profile.copyWith(baseline: current);
  final previous = profile.baseline;
  if (previous == null) return LearnResult(profile: rebaselined, learned: false);

  final distanceKm = current.odometerKm - previous.odometerKm;
  if (distanceKm < 0) return LearnResult(profile: rebaselined, learned: false);
  if (distanceKm < minLearnDistanceKm) return LearnResult(profile: profile, learned: false);

  final levelDrop = previous.fuelLevelPercent - current.fuelLevelPercent;
  if (levelDrop <= 0 || levelDrop > maxLearnLevelDrop) {
    return LearnResult(profile: rebaselined, learned: false);
  }

  final litresUsed = (profile.tankCapacityL * levelDrop) / 100;
  final sampleL100 = (litresUsed / distanceKm) * 100;
  if (!_inBand(sampleL100)) return LearnResult(profile: rebaselined, learned: false);

  final prior = profile.measuredL100;
  final measuredL100 = prior == null ? sampleL100 : prior * (1 - learnSmoothing) + sampleL100 * learnSmoothing;

  return LearnResult(
    profile: rebaselined.copyWith(measuredL100: measuredL100),
    learned: true,
    sampleL100: sampleL100,
  );
}

/* ------------------------------------------------------------------ *
 * The answer
 * ------------------------------------------------------------------ */

class FuelRangeResult {
  const FuelRangeResult({
    required this.odometerKm,
    required this.distanceSinceClearedKm,
    required this.fuelLevelPercent,
    required this.litresRemaining,
    required this.rangeKm,
    required this.consumption,
    required this.estimated,
  });

  final double? odometerKm;

  /// Only meaningful when the vehicle does not report a real odometer.
  final double? distanceSinceClearedKm;
  final double? fuelLevelPercent;
  final double? litresRemaining;

  /// Distance the remaining fuel is expected to cover, km.
  final double? rangeKm;
  final ConsumptionEstimate consumption;

  /// True when the numbers rest on an entered figure rather than a measured one.
  final bool estimated;
}

FuelRangeResult computeFuelRange(FuelSnapshot snapshot, FuelProfile profile) {
  final consumption = estimateConsumption(snapshot, profile);
  final level = snapshot.fuelLevelPercent;
  final litresRemaining = level == null ? null : (profile.tankCapacityL * _clamp(level, 0, 100)) / 100;
  final rangeKm = litresRemaining == null || consumption.l100 <= 0 ? null : (litresRemaining / consumption.l100) * 100;
  return FuelRangeResult(
    odometerKm: snapshot.odometerKm,
    distanceSinceClearedKm: snapshot.distanceSinceClearedKm,
    fuelLevelPercent: level,
    litresRemaining: litresRemaining,
    rangeKm: rangeKm,
    consumption: consumption,
    estimated: consumption.source != ConsumptionSource.measured,
  );
}

/* ------------------------------------------------------------------ *
 * Display
 * ------------------------------------------------------------------ */

const _dash = '—';

/// Thousands-separated whole kilometres, e.g. 128456.7 → "128,457".
/// Rounds like JS `Math.round` (halves toward +∞), and keeps its "-0".
String formatKm(double? km) {
  if (km == null || !km.isFinite) return _dash;
  final rounded = (km + 0.5).floorToDouble();
  final negative = rounded < 0 || (rounded == 0 && km < 0);
  final digits = rounded.abs().toStringAsFixed(0);
  final grouped = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) grouped.write(',');
    grouped.write(digits[i]);
  }
  return '${negative ? '-' : ''}$grouped';
}

String formatLitres(double? litres) => litres == null || !litres.isFinite ? _dash : litres.toStringAsFixed(1);

String formatPercent(double? percent) => percent == null || !percent.isFinite ? _dash : percent.toStringAsFixed(0);

String formatConsumption(double? l100) => l100 == null || !l100.isFinite ? _dash : l100.toStringAsFixed(1);

/// How full the tank is, 0…1, for the level bar.
double fuelBarFraction(double? percent) {
  if (percent == null || !percent.isFinite) return 0;
  return _clamp(percent, 0, 100) / 100;
}

/// Grey: no reading (TS "#6B7280").
const fuelLevelUnknownColor = Color(0xFF6B7280);

/// Red: at or below the 10 % reserve (TS "#EF4444").
const fuelLevelReserveColor = Color(0xFFEF4444);

/// Amber: at or below a quarter (TS "#F59E0B").
const fuelLevelLowColor = Color(0xFFF59E0B);

/// Green: above a quarter (TS "#22C55E").
const fuelLevelOkColor = Color(0xFF22C55E);

/// Green above a quarter, amber down to the reserve, red below it.
Color fuelLevelColor(double? percent) {
  if (percent == null || !percent.isFinite) return fuelLevelUnknownColor;
  if (percent <= 10) return fuelLevelReserveColor;
  if (percent <= 25) return fuelLevelLowColor;
  return fuelLevelOkColor;
}
