import 'dart:convert';

import 'package:flutter/painting.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/fuel_range.dart';
import 'package:get_ride/src/core/obd_pid_catalog.dart';
import 'package:get_ride/src/core/vehicle_scan.dart';
import 'package:get_ride/src/data/vehicle_fuel_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

VehicleReading reading(String pid, String label, String value, [double? numeric]) =>
    VehicleReading(pid: pid, label: label, value: value, group: PidGroup.vehicle, known: true, numeric: numeric);

const emptySnapshot = FuelSnapshot.empty;

/// A scripted `send`: each call takes the next answer (a String, or an
/// Exception to throw); the last one repeats.
({SendCommand send, List<String> sent}) scripted(List<Object> answers) {
  final sent = <String>[];
  Future<String> send(String command) async {
    sent.add(command);
    final answer = answers[sent.length - 1 < answers.length ? sent.length - 1 : answers.length - 1];
    if (answer is Exception) throw answer;
    return answer as String;
  }

  return (send: send, sent: sent);
}

void main() {
  group('readFuelSnapshot', () {
    test('picks the odometer, level and rate parameters out of a scan', () {
      final snapshot = readFuelSnapshot([
        reading('A6', 'Odometer', '128456.7 km', 128456.7),
        reading('2F', 'Fuel tank level', '62.0 %', 62),
        reading('5E', 'Engine fuel rate', '6.40 L/h', 6.4),
        reading('10', 'Mass air flow rate', '12.50 g/s', 12.5),
        reading('0D', 'Vehicle speed', '80 km/h', 80),
        reading('31', 'Distance since codes cleared', '412 km', 412),
        reading('51', 'Fuel type', 'Diesel'),
      ]);
      expect(
        snapshot,
        const FuelSnapshot(
          odometerKm: 128456.7,
          distanceSinceClearedKm: 412,
          fuelLevelPercent: 62,
          fuelRateLph: 6.4,
          mafGramsPerSec: 12.5,
          speedKmh: 80,
          fuelType: 'Diesel',
        ),
      );
    });

    test('reads real decoded frames end to end', () {
      // 01A6 -> 0.1 km/bit; 012F -> 100/255 %.
      final odometer = decodeReading('A6', '41A600139B4A\r>');
      final level = decodeReading('2F', '412F80\r>');
      final snapshot = readFuelSnapshot([odometer!, level!]);
      expect(snapshot.odometerKm, closeTo(128493.8, 0.05));
      expect(snapshot.fuelLevelPercent, closeTo(50.2, 0.05));
    });

    test('ignores raw fallbacks — an undecoded frame is not a number', () {
      final snapshot = readFuelSnapshot([
        const VehicleReading(pid: 'A6', label: 'Odometer', value: '00 13', group: PidGroup.vehicle, known: false),
      ]);
      expect(snapshot.odometerKm, isNull);
    });

    test('returns all-null for a vehicle that answered none of them', () {
      expect(readFuelSnapshot([]), emptySnapshot);
    });
  });

  group('estimateConsumption', () {
    final profile = defaultFuelProfile();

    test('falls back to the entered average with nothing live', () {
      expect(
        estimateConsumption(emptySnapshot, profile),
        const ConsumptionEstimate(l100: defaultConsumptionLPer100Km, source: ConsumptionSource.configured),
      );
    });

    test('uses the live fuel rate at road speed', () {
      final result = estimateConsumption(emptySnapshot.copyWith(fuelRateLph: 6, speedKmh: 80), profile);
      expect(result.source, ConsumptionSource.fuelRate);
      expect(result.l100, closeTo(7.5, 0.0005));
    });

    test('ignores the live rate at a standstill — burning fuel, going nowhere', () {
      expect(
        estimateConsumption(emptySnapshot.copyWith(fuelRateLph: 1.2, speedKmh: 0), profile).source,
        ConsumptionSource.configured,
      );
    });

    test('falls back to air flow when the vehicle has no fuel-rate PID', () {
      final result = estimateConsumption(emptySnapshot.copyWith(mafGramsPerSec: 12, speedKmh: 90), profile);
      expect(result.source, ConsumptionSource.maf);
      expect(result.l100, closeTo((fuelRateFromMaf(12, null) / 90) * 100, 5e-7));
    });

    test('rejects a live figure outside the plausible band', () {
      // 0.1 L/h at 100 km/h would be 0.1 L/100 km — a decode artefact, not a car.
      expect(
        estimateConsumption(emptySnapshot.copyWith(fuelRateLph: 0.1, speedKmh: 100), profile).source,
        ConsumptionSource.configured,
      );
    });

    test('prefers a measured figure over any live reading', () {
      final measured = profile.copyWith(measuredL100: 9.4);
      expect(
        estimateConsumption(emptySnapshot.copyWith(fuelRateLph: 6, speedKmh: 80), measured),
        const ConsumptionEstimate(l100: 9.4, source: ConsumptionSource.measured),
      );
    });

    test('treats diesel as denser and leaner than petrol', () {
      expect(fuelRateFromMaf(12, 'Diesel'), lessThan(fuelRateFromMaf(12, 'Petrol')));
    });

    test('labels every source as the TS CONSUMPTION_SOURCE_LABEL does', () {
      expect(ConsumptionSource.measured.label, "measured from this vehicle's own fuel use");
      expect(ConsumptionSource.fuelRate.label, "from the engine's live fuel rate");
      expect(ConsumptionSource.maf.label, 'estimated from live air flow');
      expect(ConsumptionSource.configured.label, 'your entered average — no live measurement yet');
      expect(ConsumptionSource.fuelRate.key, 'fuel-rate');
    });
  });

  group('computeFuelRange', () {
    test('converts the level into litres and kilometres', () {
      final result = computeFuelRange(
        emptySnapshot.copyWith(odometerKm: 90000, fuelLevelPercent: 50),
        defaultFuelProfile().copyWith(tankCapacityL: 50, consumptionL100: 10),
      );
      expect(result.litresRemaining, closeTo(25, 5e-7));
      expect(result.rangeKm, closeTo(250, 5e-7));
      expect(result.odometerKm, 90000);
      expect(result.estimated, isTrue);
    });

    test('is not an estimate once the consumption has been measured', () {
      final result = computeFuelRange(
        emptySnapshot.copyWith(fuelLevelPercent: 100),
        defaultFuelProfile().copyWith(tankCapacityL: 40, measuredL100: 8),
      );
      expect(result.consumption.source, ConsumptionSource.measured);
      expect(result.estimated, isFalse);
      expect(result.rangeKm, closeTo(500, 5e-7));
    });

    test('has no range to report when the vehicle hides its fuel gauge', () {
      final result = computeFuelRange(emptySnapshot.copyWith(odometerKm: 1000), defaultFuelProfile());
      expect(result.litresRemaining, isNull);
      expect(result.rangeKm, isNull);
    });

    test('clamps a nonsense level rather than inventing fuel', () {
      final result = computeFuelRange(
        emptySnapshot.copyWith(fuelLevelPercent: 140),
        defaultFuelProfile().copyWith(tankCapacityL: 50),
      );
      expect(result.litresRemaining, closeTo(50, 5e-7));
    });
  });

  group('learnConsumption', () {
    final base = defaultFuelProfile().copyWith(tankCapacityL: 50);

    test('takes the first sample as a baseline and measures nothing', () {
      final result = learnConsumption(const FuelSample(odometerKm: 1000, fuelLevelPercent: 90, at: 1), base);
      expect(result.learned, isFalse);
      expect(result.profile.baseline, const FuelSample(odometerKm: 1000, fuelLevelPercent: 90, at: 1));
      expect(result.profile.measuredL100, isNull);
    });

    test('measures the burn across a long enough stretch', () {
      final profile = base.copyWith(baseline: const FuelSample(odometerKm: 1000, fuelLevelPercent: 90, at: 1));
      // 200 km on 20 % of a 50 L tank = 10 L = 5.0 L/100 km.
      final result = learnConsumption(const FuelSample(odometerKm: 1200, fuelLevelPercent: 70, at: 2), profile);
      expect(result.learned, isTrue);
      expect(result.sampleL100, closeTo(5, 5e-7));
      expect(result.profile.measuredL100, closeTo(5, 5e-7));
      expect(result.profile.baseline?.odometerKm, 1200);
    });

    test('smooths a new measurement into the running one', () {
      final profile = base.copyWith(
        measuredL100: 10.0,
        baseline: const FuelSample(odometerKm: 1000, fuelLevelPercent: 90, at: 1),
      );
      final result = learnConsumption(const FuelSample(odometerKm: 1200, fuelLevelPercent: 70, at: 2), profile);
      // 0.6 * 10 + 0.4 * 5
      expect(result.profile.measuredL100, closeTo(8, 5e-7));
    });

    test('keeps the baseline until enough distance has been covered', () {
      const baseline = FuelSample(odometerKm: 1000, fuelLevelPercent: 90, at: 1);
      final profile = base.copyWith(baseline: baseline);
      final result = learnConsumption(
        const FuelSample(odometerKm: 1000 + minLearnDistanceKm - 1, fuelLevelPercent: 88, at: 2),
        profile,
      );
      expect(result.learned, isFalse);
      expect(result.profile.baseline, baseline);
    });

    test('re-baselines after a refuel instead of measuring a negative burn', () {
      final profile = base.copyWith(baseline: const FuelSample(odometerKm: 1000, fuelLevelPercent: 30, at: 1));
      final result = learnConsumption(const FuelSample(odometerKm: 1200, fuelLevelPercent: 95, at: 2), profile);
      expect(result.learned, isFalse);
      expect(result.profile.measuredL100, isNull);
      expect(result.profile.baseline?.fuelLevelPercent, 95);
    });

    test('re-baselines when the odometer goes backwards', () {
      final profile = base.copyWith(baseline: const FuelSample(odometerKm: 90000, fuelLevelPercent: 80, at: 1));
      final result = learnConsumption(const FuelSample(odometerKm: 120, fuelLevelPercent: 60, at: 2), profile);
      expect(result.learned, isFalse);
      expect(result.profile.baseline?.odometerKm, 120);
    });

    test('discards an implausible result rather than poisoning the average', () {
      final profile = base.copyWith(baseline: const FuelSample(odometerKm: 1000, fuelLevelPercent: 90, at: 1));
      // 25 km on 45 % of a 50 L tank would be 90 L/100 km.
      final result = learnConsumption(const FuelSample(odometerKm: 1025, fuelLevelPercent: 45, at: 2), profile);
      expect(result.learned, isFalse);
      expect(result.profile.measuredL100, isNull);
    });
  });

  group('profileForVin', () {
    test('adopts the VIN the first time one is seen', () {
      final stored = defaultFuelProfile().copyWith(tankCapacityL: 60);
      expect(profileForVin(stored, 'WVWZZZ1JZ3W386752'), stored.copyWith(vin: 'WVWZZZ1JZ3W386752'));
    });

    test('keeps the profile for the same vehicle', () {
      final stored = defaultFuelProfile('VIN1').copyWith(measuredL100: 7.0);
      expect(profileForVin(stored, 'VIN1'), same(stored));
    });

    test('starts fresh for a different vehicle', () {
      final stored = defaultFuelProfile('VIN1').copyWith(tankCapacityL: 80, measuredL100: 7.0);
      expect(profileForVin(stored, 'VIN2'), defaultFuelProfile('VIN2'));
    });

    test('keeps the stored profile when the vehicle reports no VIN', () {
      final stored = defaultFuelProfile('VIN1');
      expect(profileForVin(stored, null), same(stored));
    });
  });

  group('normalizeFuelProfile', () {
    test('returns the defaults for nothing stored', () {
      expect(normalizeFuelProfile(null), defaultFuelProfile());
    });

    test('clamps values an older build may have written', () {
      final profile = normalizeFuelProfile({'tankCapacityL': 9999, 'consumptionL100': 0});
      expect(profile.tankCapacityL, maxTankCapacityL);
      expect(profile.consumptionL100, 2);
    });

    test('drops a measured figure outside the plausible band', () {
      expect(normalizeFuelProfile({'measuredL100': 900}).measuredL100, isNull);
    });

    test('drops a malformed baseline', () {
      expect(
        normalizeFuelProfile({
          'baseline': {'odometerKm': double.nan, 'fuelLevelPercent': 5, 'at': 1},
        }).baseline,
        isNull,
      );
    });
  });

  group('validateFuelProfileInput', () {
    test('accepts a typed pair', () {
      expect(
        validateFuelProfileInput(' 48 ', '7.6'),
        const ProfileEditResult(ok: true, value: FuelProfileInput(tankCapacityL: 48, consumptionL100: 7.6)),
      );
    });

    test('rejects an impossible tank', () {
      expect(validateFuelProfileInput('0', '8').ok, isFalse);
      expect(validateFuelProfileInput('abc', '8').ok, isFalse);
    });

    test('rejects an impossible consumption', () {
      expect(validateFuelProfileInput('45', '99').ok, isFalse);
    });
  });

  group('display helpers', () {
    test('renders whole, separated kilometres', () {
      expect(formatKm(128456.7), '128,457');
      expect(formatKm(null), '—');
    });

    test('renders litres, percent and consumption to one place', () {
      expect(formatLitres(27.94), '27.9');
      expect(formatPercent(61.6), '62');
      expect(formatConsumption(8), '8.0');
      expect(formatLitres(null), '—');
    });

    test('maps the gauge onto a bar and a colour', () {
      expect(fuelBarFraction(50), closeTo(0.5, 5e-7));
      expect(fuelBarFraction(140), 1);
      expect(fuelBarFraction(null), 0);
      expect(fuelLevelColor(60), const Color(0xFF22C55E));
      expect(fuelLevelColor(20), const Color(0xFFF59E0B));
      expect(fuelLevelColor(5), const Color(0xFFEF4444));
    });

    test('defaults a fresh profile to a plausible car', () {
      expect(defaultFuelProfile().tankCapacityL, defaultTankCapacityL);
      expect(defaultFuelProfile().consumptionL100, defaultConsumptionLPer100Km);
    });
  });

  group('readOdometerKm', () {
    const frame = '41 A6 00 01 E2 40'; // 123456 → 12345.6 km

    test('decodes the odometer off the first good answer', () async {
      final s = scripted([frame]);
      expect(await readOdometerKm(s.send, delayMs: 0), closeTo(12345.6, 0.0005));
      expect(s.sent, ['01A6']);
    });

    test('retries an adapter that was busy rather than calling the reading absent', () async {
      // One unanswered command is not proof that a car has no odometer: the
      // adapter serves the 1 Hz sweep at the same time and clones answer BUSY.
      final s = scripted(['BUSY', Exception('timed out'), frame]);
      expect(await readOdometerKm(s.send, delayMs: 0), closeTo(12345.6, 0.0005));
      expect(s.sent, hasLength(3));
    });

    test('gives up honestly on a car that does not publish PID A6', () async {
      final s = scripted(['NO DATA']);
      expect(await readOdometerKm(s.send, delayMs: 0), isNull);
      expect(s.sent, hasLength(odometerReadAttempts));
    });

    test('never reports a reading from a link that only ever threw', () async {
      final s = scripted([Exception('no session')]);
      expect(await readOdometerKm(s.send, attempts: 2, delayMs: 0), isNull);
      expect(s.sent, hasLength(2));
    });

    test('waits the retry delay between attempts through the injected clock', () async {
      final waits = <Duration>[];
      final s = scripted(['NO DATA']);
      expect(await readOdometerKm(s.send, delay: (d) async => waits.add(d)), isNull);
      expect(waits, List.filled(odometerReadAttempts - 1, const Duration(milliseconds: odometerRetryDelayMs)));
    });
  });

  group('shouldReadOdometer', () {
    const base = OdometerPollInput(
      linked: true,
      simulated: false,
      status: OdometerStatus.unknown,
      reading: false,
      lastAttemptAt: null,
      now: 1000000,
    );

    test('reads as soon as a real link is up', () {
      expect(shouldReadOdometer(base), isTrue);
    });

    test('never asks without a session', () {
      expect(shouldReadOdometer(base.copyWith(linked: false)), isFalse);
    });

    test('never asks the simulator — a fake odometer is not a reading', () {
      expect(shouldReadOdometer(base.copyWith(simulated: true)), isFalse);
    });

    test('does not queue a second command behind one in flight', () {
      expect(shouldReadOdometer(base.copyWith(reading: true)), isFalse);
    });

    test('holds the reading until the refresh is due, then asks again', () {
      final lastAttemptAt = base.now - odometerRefreshMs + 1;
      expect(shouldReadOdometer(base.copyWith(status: OdometerStatus.ready, lastAttemptAt: lastAttemptAt)), isFalse);
      expect(shouldReadOdometer(base.copyWith(status: OdometerStatus.ready, lastAttemptAt: lastAttemptAt - 1)), isTrue);
    });

    test("honours a caller's own cadence", () {
      expect(
        shouldReadOdometer(
          base.copyWith(status: OdometerStatus.ready, lastAttemptAt: base.now - 5000, refreshMs: 1000),
        ),
        isTrue,
      );
    });

    test('stops asking a car that has already refused the parameter', () {
      expect(
        shouldReadOdometer(
          base.copyWith(status: OdometerStatus.unsupported, lastAttemptAt: base.now - odometerRefreshMs * 10),
        ),
        isFalse,
      );
    });

    test('is not parked by a clock that jumped backwards', () {
      expect(shouldReadOdometer(base.copyWith(status: OdometerStatus.ready, lastAttemptAt: base.now + 60000)), isTrue);
    });
  });

  // No vehicleFuelStore tests exist in the Expo app; these cover the port.
  group('VehicleFuelStore', () {
    final store = VehicleFuelStore();

    test('loads the defaults when nothing is stored or the JSON is corrupt', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await store.load(), defaultFuelProfile());
      SharedPreferences.setMockInitialValues({VehicleFuelStore.profileKey: '{not json'});
      expect(await store.load(), defaultFuelProfile());
    });

    test('saves normalised JSON under the Expo key without the @', () async {
      SharedPreferences.setMockInitialValues({});
      expect(VehicleFuelStore.profileKey, 'vehicle_fuel_profile_v1');
      final saved = await store.save(defaultFuelProfile('VIN1').copyWith(tankCapacityL: 9999));
      expect(saved.tankCapacityL, maxTankCapacityL);
      final raw = (await SharedPreferences.getInstance()).getString(VehicleFuelStore.profileKey)!;
      expect(jsonDecode(raw), {
        'tankCapacityL': 500.0,
        'consumptionL100': 8.0,
        'measuredL100': null,
        'baseline': null,
        'vin': 'VIN1',
      });
      expect(await store.load(), saved);
    });

    test('records a sample as a baseline, then learns across a stretch', () async {
      SharedPreferences.setMockInitialValues({});
      await store.save(defaultFuelProfile().copyWith(tankCapacityL: 50));
      final first = await store.recordFuelSample(
        'VIN1',
        const FuelSample(odometerKm: 1000, fuelLevelPercent: 90, at: 1),
      );
      expect(first.learned, isFalse);
      expect(first.profile.vin, 'VIN1');
      final second = await store.recordFuelSample(
        'VIN1',
        const FuelSample(odometerKm: 1200, fuelLevelPercent: 70, at: 2),
      );
      expect(second.learned, isTrue);
      expect((await store.load()).measuredL100, closeTo(5, 5e-7));
    });

    test('a VIN switch without a sample still persists the fresh profile', () async {
      SharedPreferences.setMockInitialValues({});
      await store.save(defaultFuelProfile('VIN1').copyWith(tankCapacityL: 80));
      final result = await store.recordFuelSample('VIN2', null);
      expect(result.learned, isFalse);
      expect(result.profile, defaultFuelProfile('VIN2'));
      expect(await store.load(), defaultFuelProfile('VIN2'));
    });

    test('reset drops the measurement and baseline, keeping what was typed', () async {
      SharedPreferences.setMockInitialValues({});
      await store.save(
        defaultFuelProfile().copyWith(
          tankCapacityL: 60,
          consumptionL100: 9,
          measuredL100: 7.0,
          baseline: const FuelSample(odometerKm: 1, fuelLevelPercent: 2, at: 3),
        ),
      );
      final reset = await store.resetMeasuredConsumption();
      expect(reset, defaultFuelProfile().copyWith(tankCapacityL: 60, consumptionL100: 9));
    });
  });
}
