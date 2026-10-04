import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/meter_logic.dart';
import 'package:get_ride/src/core/meter_trip.dart';
import 'package:get_ride/src/core/taxi_meter.dart';

/// ~11.1 m per 0.0001° of latitude.
MeterPoint _at(double northM, {double? accuracy}) => MeterPoint(3.0 + northM / 111195, 101.0, accuracyM: accuracy);

/// Drives the meter north at [kmh] for [seconds], one GPS fix a second.
MeterState _drive(MeterState s, {required int fromMs, required double fromM, required double kmh, required int seconds}) {
  var state = s;
  for (var i = 1; i <= seconds; i++) {
    state = applyMeterSample(state, MeterSample(at: fromMs + i * 1000, gpsPoint: _at(fromM + kmh / 3.6 * i)));
  }
  return state;
}

void main() {
  group('accrual', () {
    test('a stopped meter accrues nothing', () {
      const s = MeterState();
      final after = applyMeterSample(s, MeterSample(at: 1000, gpsPoint: _at(0), gpsSpeedKmh: 50));
      expect(after.distanceM, 0);
      expect(after.elapsedMs, 0);
    });

    test('GPS displacement accrues distance and time', () {
      var s = startMeter(const MeterState(), 0);
      s = applyMeterSample(s, MeterSample(at: 0, gpsPoint: _at(0)));
      s = _drive(s, fromMs: 0, fromM: 0, kmh: 36, seconds: 10); // 10 m/s
      expect(s.distanceM, closeTo(100, 1));
      expect(s.elapsedMs, 10000);
      expect(s.source, MeterSource.gps);
      expect(s.gpsSamples, 10);
      expect(s.waitingMs, 0);
    });

    test('jitter under 3 m is standing still, and counts as waiting', () {
      var s = startMeter(const MeterState(), 0);
      s = applyMeterSample(s, MeterSample(at: 0, gpsPoint: _at(0)));
      s = applyMeterSample(s, MeterSample(at: 1000, gpsPoint: _at(1.5)));
      expect(s.distanceM, 0);
      expect(s.waitingMs, 1000);
    });

    test('an implausible jump is ignored; ground speed fills in', () {
      var s = startMeter(const MeterState(), 0);
      s = applyMeterSample(s, MeterSample(at: 0, gpsPoint: _at(0)));
      s = applyMeterSample(s, MeterSample(at: 1000, gpsPoint: _at(500), gpsSpeedKmh: 36));
      expect(s.distanceM, closeTo(10, 0.01));
    });

    test('inaccurate fixes are not used for displacement', () {
      var s = startMeter(const MeterState(), 0);
      s = applyMeterSample(s, MeterSample(at: 0, gpsPoint: _at(0)));
      s = applyMeterSample(s, MeterSample(at: 1000, gpsPoint: _at(20, accuracy: 80)));
      expect(s.distanceM, 0);
      expect(s.source, MeterSource.none);
    });

    test('a long gap is clamped so a pause is never billed as motion', () {
      var s = startMeter(const MeterState(), 0);
      s = applyMeterSample(s, const MeterSample(at: 0, gpsSpeedKmh: 36));
      s = applyMeterSample(s, const MeterSample(at: 60000, gpsSpeedKmh: 36));
      expect(s.elapsedMs, maxSampleGapMs);
      expect(s.distanceM, closeTo(50, 0.01));
    });

    test('fresh OBD speed wins over GPS; stale OBD does not', () {
      var s = startMeter(const MeterState(), 0);
      s = applyMeterSample(s, const MeterSample(at: 0));
      s = applyMeterSample(s, const MeterSample(at: 1000, obdSpeedKmh: 72, obdUpdatedAt: 900, gpsSpeedKmh: 10));
      expect(s.source, MeterSource.obd);
      expect(s.distanceM, closeTo(20, 0.01));
      s = applyMeterSample(s, const MeterSample(at: 2000, obdSpeedKmh: 72, obdUpdatedAt: -5000, gpsSpeedKmh: 36));
      expect(s.source, MeterSource.gps);
    });

    test('pausing drops the baseline so movement while paused is free', () {
      var s = startMeter(const MeterState(), 0);
      s = applyMeterSample(s, MeterSample(at: 0, gpsPoint: _at(0)));
      s = _drive(s, fromMs: 0, fromM: 0, kmh: 36, seconds: 5);
      s = pauseMeter(s);
      s = applyMeterSample(s, MeterSample(at: 10000, gpsPoint: _at(400)));
      expect(s.distanceM, closeTo(50, 1));
      s = startMeter(s, 20000);
      s = applyMeterSample(s, MeterSample(at: 20000, gpsPoint: _at(400)));
      s = applyMeterSample(s, MeterSample(at: 21000, gpsPoint: _at(410)));
      expect(s.distanceM, closeTo(60, 1));
      expect(s.startedAt, 0);
    });

    test('only time past the flag distance is chargeable', () {
      var s = startMeter(const MeterState(), 0);
      s = applyMeterSample(s, const MeterSample(at: 0, gpsSpeedKmh: 36));
      // 10 m/s: 1000 m is reached at 100 s.
      for (var i = 1; i <= 120; i++) {
        s = applyMeterSample(s, MeterSample(at: i * 1000, gpsSpeedKmh: 36));
      }
      expect(s.distanceM, closeTo(1200, 0.1));
      expect(s.chargeableMs, closeTo(20000, 5));

      var t = startMeter(const MeterState(), 0);
      t = applyMeterSample(t, const MeterSample(at: 0, gpsSpeedKmh: 36));
      for (var i = 1; i <= 120; i++) {
        t = applyMeterSample(t, MeterSample(at: i * 1000, gpsSpeedKmh: 36), flagDistanceM: 500);
      }
      expect(t.chargeableMs, closeTo(70000, 5));
    });
  });

  group('fare', () {
    test('the old TEKSI tariff: flag fall covers the first km, then 35 sen per 200 m', () {
      const s = MeterState(distanceM: 1000, elapsedMs: 60000);
      expect(meterFare(s, tariffRates['old']!), 4.0);
      const s2 = MeterState(distanceM: 1401, elapsedMs: 60000, chargeableMs: 10000);
      expect(meterFare(s2, tariffRates['old']!), 4.0 + 3 * 0.35);
    });

    test('the night key multiplies the whole fare', () {
      const s = MeterState(distanceM: 1000);
      expect(meterFare(s, tariffRates['old']!, multiplier: periodMultiplier(MeterPeriod.night)), 6.0);
      expect(periodMultiplier(MeterPeriod.day), 1);
      expect(periodMultiplier(MeterPeriod.night, -1), nightMultiplierDefault);
    });

    test('the night window, including one that wraps midnight', () {
      expect(isNightPeriod(DateTime(2026, 1, 1, 0, 30)), isTrue);
      expect(isNightPeriod(DateTime(2026, 1, 1, 6, 0)), isFalse);
      expect(isNightPeriod(DateTime(2026, 1, 1, 23), startHour: 22, endHour: 6), isTrue);
      expect(isNightPeriod(DateTime(2026, 1, 1, 12), startHour: 22, endHour: 6), isFalse);
    });

    test('extras step in sen and stay within bounds', () {
      expect(adjustExtra(0, 3), 1.5);
      expect(adjustExtra(1, -5), 0);
      expect(adjustExtra(99, 5), maxExtraDefault);
      expect(adjustExtra(0, 2, step: 1.0, max: 1.5), 1.5);
    });

    test('the grand total adds each charge without letting one pull it down', () {
      expect(meterGrandTotal(10, [2.5, 3, -4]), 15.5);
      expect(meterGrandTotal(double.nan, [1]), 1);
    });
  });

  test('display formats', () {
    expect(formatMeterClock(3723000), '01:02:03');
    expect(formatMeterDistance(740.4), '740 m');
    expect(formatMeterDistance(3421), '3.42 km');
    expect(formatMeterKm(1234), '1.23');
    expect(describeMeterSource(MeterSource.none), 'No signal');
  });

  group('end-of-hire declaration', () {
    test('nothing is preselected and every answer is needed', () {
      const d = MeterTripDetailsDraft();
      expect(resolveTripDetails(d), isNull);
      expect(describeMissingTripDetails(d), 'Still to declare: passengers · luggage · airport');
      final done = d.copyWith(pax: 2, luggage: 0, airport: MeterAirport.none);
      expect(resolveTripDetails(done)!.airportSurcharge, 0);
      expect(describeMissingTripDetails(done), isNull);
    });

    test('an airport at either end carries the surcharge', () {
      final d = const MeterTripDetailsDraft(pax: 1, luggage: 2, airport: MeterAirport.dropoff, charges: 12.345);
      final r = resolveTripDetails(d)!;
      expect(r.airportSurcharge, airportSurcharge);
      expect(r.charges, 12.35);
    });

    test('counts and charges are clamped', () {
      expect(clampPax(20), maxPax);
      expect(clampPax(0), minPax);
      expect(clampLuggage(-1), 0);
      expect(clampPax(null), isNull);
      expect(sanitizeCharges(500), maxCharges);
      expect(sanitizeChargesText('12,3456abc'), '12.34');
      expect(sanitizeChargesText('123456'), '1234');
      expect(chargesFromText('7.5'), 7.5);
      expect(chargesToText(0), '');
    });
  });

  group('trip record and receipt', () {
    MeterTrip trip({MeterPeriod period = MeterPeriod.day}) => buildMeterTrip(
          const MeterState(startedAt: 1000, distanceM: 3420, elapsedMs: 600000, waitingMs: 60000, gpsSamples: 600),
          id: 't1',
          endedAt: 601000,
          fare: 12.4,
          details: resolveTripDetails(
              const MeterTripDetailsDraft(pax: 2, luggage: 1, charges: 3, airport: MeterAirport.pickup))!,
          rateLabel: 'Global rate card',
          period: period,
          flagFare: 4,
          nightMultiplier: 1.5,
          currency: 'RM',
          cardSurcharge: 1,
          pickup: const MeterWaypoint(at: 1000, latitude: 3.1, longitude: 101.6, place: 'KLCC'),
          dropoff: const MeterWaypoint(at: 601000, latitude: 3.2, longitude: 101.7),
        );

    test('the total is the fare plus every declared charge', () {
      final t = trip();
      expect(t.total, 12.4 + 3 + airportSurcharge + 1);
      expect(t.nightMultiplier, 1, reason: 'a day hire records no night multiplier');
    });

    test('the record survives a round trip through storage', () {
      final t = trip(period: MeterPeriod.night);
      final back = MeterTrip.fromJson(t.toJson())!;
      expect(back.toJson(), t.toJson());
      expect(MeterTrip.fromJson({'id': 'x'}), isNull);
      final old = MeterTrip.fromJson({'id': 'x', 'endedAt': 5})!;
      expect(old.pax, isNull);
      expect(old.startedAt, 5);
    });

    test('the receipt prints each charge on its own line', () {
      final lines = {for (final l in meterReceiptLines(trip(period: MeterPeriod.night))) l.label: l.value};
      expect(lines['Pickup'], 'KLCC');
      expect(lines['Drop-off'], '3.20000, 101.70000');
      expect(lines['Tariff'], 'Global rate card · Night');
      expect(lines['Night surcharge'], '+50%');
      expect(lines['Flag fall'], 'RM 6.00');
      expect(lines['Tolls & charges'], 'RM 3.00');
      expect(lines['Bags & passengers'], 'RM 1.00');
      expect(lines['Airport surcharge'], 'RM 3.00');
      expect(lines['Total'], 'RM 19.40');
      expect(meterReceiptText(trip()), contains('Fare metered on GPS · 0 OBD / 600 GPS samples'));
    });

    test('a record without a declaration prints no lines for it', () {
      final lines = meterReceiptLines(MeterTrip.fromJson({'id': 'x', 'endedAt': 5, 'total': 4})!).map((l) => l.label);
      expect(lines, isNot(contains('Passengers')));
      expect(lines, isNot(contains('Pickup')));
      expect(lines, isNot(contains('Airport surcharge')));
    });

    test('the log summary adds up distance and takings', () {
      final s = summarizeMeterTrips([trip(), trip()]);
      expect(s.count, 2);
      expect(s.distanceM, 6840);
      expect(s.total, 38.8);
    });
  });
}
