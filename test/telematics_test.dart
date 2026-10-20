// Telematics (migration 0255): the periods and their buckets, the trip
// types' names, the numbers' formats, the CSV, the GPS distance filter, the
// driver app's tracker (online km and a trip's checkpoints), and the
// driver's and the admin's pages in light and dark.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show moduleAccessProvider;
import 'package:get_ride/src/admin/screens/telematics_screen.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/telematics.dart';
import 'package:get_ride/src/data/dispatch_repository.dart' show DispatchRoles;
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/telematics_repository.dart';
import 'package:get_ride/src/data/telematics_tracker.dart';
import 'package:get_ride/src/core/dispatch.dart' show DispatchGroup, DispatchStand, GroupKind, StandPerms;
import 'package:get_ride/src/features/dispatch/dispatch_screen.dart' show dispatchTabsFor;
import 'package:get_ride/src/features/dispatch/telematics_tab.dart' show telematicsScopesFor;
import 'package:get_ride/src/features/partner/earnings_screen.dart' show CsvShareOutcome, earningsCsvSharerProvider;
import 'package:get_ride/src/features/partner/telematics_screen.dart';
import 'package:get_ride/src/providers.dart';

// 20 Oct 2026, 14:30 in Malaysia (a Tuesday).
final _now = DateTime.utc(2026, 10, 20, 6, 30);

TelematicsFix _fix(double lat, double lng, int sec, {double? acc = 8}) =>
    (lat: lat, lng: lng, accuracy: acc, at: DateTime.utc(2026, 10, 20, 6).add(Duration(seconds: sec)));

/// 0.001° of latitude is ~111 m.
const _step = 0.001;

void main() {
  group('periods', () {
    test('today by the hour, from Malaysia\'s midnight', () {
      final r = telematicsRange(TelematicsPeriod.today, _now);
      expect(r.from, DateTime.utc(2026, 10, 19, 16));
      expect(r.to, DateTime.utc(2026, 10, 20, 16));
      expect(r.bucket, TelematicsBucket.hour);
      expect(r.days, 1);
    });

    test('this week from Monday and this month from the 1st, by the day', () {
      final w = telematicsRange(TelematicsPeriod.week, _now);
      expect(w.first, DateTime.utc(2026, 10, 19));
      expect(w.days, 2);
      expect(w.bucket, TelematicsBucket.day);
      final m = telematicsRange(TelematicsPeriod.month, _now);
      expect(m.from, DateTime.utc(2026, 9, 30, 16));
      expect(m.days, 20);
    });

    test('a custom range: either order, at most a year, bucketed by its length', () {
      final r = telematicsRange(TelematicsPeriod.custom, _now, first: DateTime(2026, 10, 10), last: DateTime(2026, 10, 1));
      expect(r.first, DateTime.utc(2026, 10, 1));
      expect(r.last, DateTime.utc(2026, 10, 10));
      expect(r.days, 10);
      expect(r.bucket, TelematicsBucket.day);
      final long = telematicsRange(TelematicsPeriod.custom, _now, first: DateTime(2020, 1, 1), last: DateTime(2026, 10, 20));
      expect(long.days, telematicsMaxDays);
      expect(long.last, DateTime.utc(2026, 10, 20));
      expect(long.bucket, TelematicsBucket.month);
      expect(telematicsRange(TelematicsPeriod.custom, _now, first: DateTime(2026, 10, 5), last: DateTime(2026, 10, 5)).bucket,
          TelematicsBucket.hour);
    });

    test('bucket maths', () {
      expect(telematicsBucketFor(1), TelematicsBucket.hour);
      expect(telematicsBucketFor(2), TelematicsBucket.day);
      expect(telematicsBucketFor(62), TelematicsBucket.day);
      expect(telematicsBucketFor(63), TelematicsBucket.week);
      expect(telematicsBucketFor(190), TelematicsBucket.week);
      expect(telematicsBucketFor(191), TelematicsBucket.month);
      final mon = DateTime.utc(2026, 10, 19, 14);
      expect(telematicsBucketLabel(mon, TelematicsBucket.hour, days: 1), '14');
      expect(telematicsBucketLabel(mon, TelematicsBucket.day, days: 7), 'Mon');
      expect(telematicsBucketLabel(mon, TelematicsBucket.day, days: 20), '19');
      expect(telematicsBucketLabel(mon, TelematicsBucket.week, days: 90), '19 Oct');
      expect(telematicsBucketLabel(mon, TelematicsBucket.month, days: 300), 'Oct');
      expect(telematicsBucketTitle(mon, TelematicsBucket.hour), '14:00');
      expect(telematicsBucketTitle(mon, TelematicsBucket.day), 'Mon 19 Oct');
      expect(telematicsBucketTitle(mon, TelematicsBucket.week), 'Week of 19 Oct');
      expect(telematicsBucketTitle(mon, TelematicsBucket.month), 'Oct 2026');
      expect(telematicsLabelledBars(7, 10), [0, 1, 2, 3, 4, 5, 6]);
      expect(telematicsLabelledBars(24, 8), [0, 3, 6, 9, 12, 15, 18, 21]);
      expect(telematicsLabelledBars(0, 8), isEmpty);
    });
  });

  group('trip types and numbers', () {
    test('each kind in words', () {
      expect(tripKindLabel('service:Comfort'), 'Comfort');
      expect(tripKindLabel('service:6-seater'), '6-seater');
      expect(tripKindLabel('service:'), 'Ride');
      expect(tripKindLabel('meter'), 'Taxi (meter)');
      expect(tripKindLabel('stand'), 'Stand order');
      expect(tripKindLabel('airport'), 'Airport queue');
      expect(tripKindLabel('scheduled'), 'Scheduled');
      expect(tripKindLabel('call_centre'), 'Call centre');
      expect(tripKindLabel('my_ride'), 'My Ride / GET.now');
    });

    test('km, the difference and "not recorded"', () {
      expect(formatTelematicsKm(1234.56), '1,234.6');
      expect(formatTelematicsKm(0), '0.0');
      expect(formatTelematicsKm(1234567.0), '1,234,567.0');
      expect(formatTelematicsKm(null), '—');
      expect(kmDiffPercent(10, 11), closeTo(10, 1e-9));
      expect(kmDiffPercent(null, 11), isNull);
      expect(kmDiffPercent(0, 11), isNull);
      expect(formatKmDiff(3.24), '+3.2%');
      expect(formatKmDiff(-1.0), '-1.0%');
      expect(formatKmDiff(null), '—');
    });

    test('the summary, its trip share and paired differences', () {
      final s = TelematicsSummary.fromJson({
        'mode': 'self',
        'online_recorded': true,
        'online_km': 50,
        'trips': 3,
        'km': {
          'est_pickup': 4, 'est_trip': 20, 'act_pickup': 2.5, 'act_trip': 22,
          'pickup_pairs': 1, 'trip_pairs': 2, 'est_pickup_paired': 2, 'act_pickup_paired': 2.5,
          'est_trip_paired': 20, 'act_trip_paired': 22, 'with_actual': 2, 'obd': 1,
        },
        'buckets': [
          {'start': '2026-10-19T00:00', 'trips': 2, 'pickup_km': 3, 'trip_km': 15, 'other_km': 10, 'online_km': 28},
          {'start': '2026-10-20T00:00', 'trips': 1, 'pickup_km': 1.5, 'trip_km': 8, 'other_km': 12.5, 'online_km': 22},
        ],
        'types': [{'kind': 'service:Ride', 'trips': 2}, {'kind': 'meter', 'trips': 1}],
      });
      expect(s.buckets.first.start, DateTime.utc(2026, 10, 19));
      expect(s.buckets.first.total, 28);
      expect(s.tripKm, 27.5);
      expect(s.tripShare, closeTo(0.55, 1e-9));
      expect(s.km.pickupDiff, 25);
      expect(s.km.tripDiff, 10);
      expect(s.km.totalDiff, closeTo((24.5 - 22) / 22 * 100, 1e-9));
      expect(s.km.estTotal, 24);
      expect(s.types.map((t) => t.label), ['Ride', 'Taxi (meter)']);
      expect(const TelematicsSummary().tripShare, isNull, reason: 'no online km recorded');
      expect(const TelematicsKm().actTotal, isNull);
    });

    test('the period list as CSV', () {
      final rows = [
        TelematicsListRow.fromJson({
          'driver_id': 'd1', 'driver_name': 'Ahmad, bin Ali', 'driver_code': 'D-1042', 'vehicle_id': 'v1',
          'plate': 'WXY 1234', 'vehicle': 'Perodua Bezza', 'online_km': 812.4, 'trips': 64,
          'est_pickup_km': 100, 'est_trip_km': 500.5, 'act_pickup_km': null, 'act_trip_km': 510,
        }),
      ];
      final csv = telematicsListCsv(rows, TelematicsGroup.pair);
      expect(
        csv,
        'Driver,Driver ID,Plate,Vehicle,km driven online,Trips,To pickup est. km,To pickup actual km,'
        'Pickup to drop est. km,Pickup to drop actual km\r\n'
        '"Ahmad, bin Ali",D-1042,WXY 1234,Perodua Bezza,812.40,64,100.00,,500.50,510.00\r\n',
      );
      expect(telematicsListCsv(rows, TelematicsGroup.vehicle).split('\r\n').first, startsWith('Plate,Vehicle,km'));
      expect(rows.first.driverLabel, 'Ahmad, bin Ali (D-1042)');
      expect(rows.first.vehicleLabel, 'WXY 1234 · Perodua Bezza');
      expect(rows.first.key(TelematicsGroup.pair), 'd1|v1');
      expect(const TelematicsListRow().vehicleLabel, 'Vehicle not recorded');
      expect(
        telematicsCsvFileName(TelematicsGroup.driver, telematicsRange(TelematicsPeriod.week, _now)),
        'telematics-drivers-2026-10-19-2026-10-20.csv',
      );
    });
  });

  group('distance from GPS', () {
    test('driving adds up; a loose fix and a jump add nothing', () {
      final a = DistanceAccumulator();
      expect(a.add(_fix(3.0, 101.0, 0)), 0, reason: 'the first fix only anchors');
      expect(a.add(_fix(3.0 + _step, 101.0, 10)), closeTo(110.6, 1));
      expect(a.add(_fix(3.5, 101.0, 11, acc: 300)), 0, reason: 'too loose');
      expect(a.add(_fix(3.2, 101.0, 20)), 0, reason: '22 km in 10 s is a jump');
      expect(a.add(_fix(3.0 + 2 * _step, 101.0, 20)), closeTo(110.6, 1));
      expect(a.metres, closeTo(221.2, 2));
      expect(a.take(), closeTo(221.2, 2));
      expect(a.metres, 0);
    });

    test('a parked phone\'s wandering fixes add nothing; slow driving still counts', () {
      final a = DistanceAccumulator();
      a.add(_fix(3.0, 101.0, 0));
      for (var i = 1; i <= 30; i++) {
        // ±5 m around the same spot.
        a.add(_fix(3.0 + (i.isEven ? 0.00004 : -0.00004), 101.0, i * 5));
      }
      expect(a.metres, 0);
      // 4 m every 2 s: counted once it is past the step.
      for (var i = 1; i <= 10; i++) {
        a.add(_fix(3.0 + i * 0.000036, 101.0, 200 + i * 2));
      }
      expect(a.metres, closeTo(40, 6));
    });

    test('after three jumps in a row the phone really is elsewhere', () {
      final a = DistanceAccumulator();
      a.add(_fix(3.0, 101.0, 0));
      a.add(_fix(3.3, 101.0, 1));
      a.add(_fix(3.3, 101.0, 2));
      a.add(_fix(3.3, 101.0, 3));
      expect(a.metres, 0);
      expect(a.add(_fix(3.3 + _step, 101.0, 13)), closeTo(110.6, 1), reason: 'counting from the new place');
    });
  });

  group('the tracker', () {
    late StreamController<TelematicsFix> fixes;
    late List<(double, String)> online;
    late List<(String, String, double?, double?, double?)> checkpoints;
    double? odometer;
    var failOnline = false;

    TelematicsTracker make() => TelematicsTracker(
      fixes: () => fixes.stream,
      reportOnline: (km, source) async {
        if (failOnline) throw StateError('offline');
        online.add((km, source));
      },
      checkpoint: (id, stage, {km, odometerKm, estKm}) async => checkpoints.add((id, stage, km, odometerKm, estKm)),
      odometer: () async => odometer,
      routeKm: (from, to) async => 2.4,
      flushEvery: const Duration(hours: 1),
    );

    setUp(() {
      fixes = StreamController<TelematicsFix>.broadcast();
      online = [];
      checkpoints = [];
      odometer = null;
      failOnline = false;
    });

    Future<void> drive(int from, int legs, {int startSec = 0}) async {
      for (var i = 0; i <= legs; i++) {
        fixes.add(_fix(3.0 + (from + i) * _step, 101.0, startSec + i * 10));
      }
      await Future<void>.delayed(Duration.zero);
    }

    RideRequest ride(String status) => RideRequest({
      'id': 'r1',
      'status': status,
      'pickup_lat': 3.01,
      'pickup_lng': 101.0,
      'partner_accept_lat': 3.0,
      'partner_accept_lng': 101.0,
    });

    test('online: listens, counts, reports; a failed report goes with the next; offline stops', () async {
      final t = make();
      expect(t.listening, isFalse);
      t.setOnline(true);
      expect(t.listening, isTrue);
      await drive(0, 10);
      failOnline = true;
      await t.flush();
      expect(online, isEmpty);
      expect(t.unreportedKm, closeTo(1.106, 0.01));
      failOnline = false;
      await drive(20, 5, startSec: 200);
      t.setOnline(false);
      await Future<void>.delayed(Duration.zero);
      // The way from the last fix counted to the next is driven too.
      expect(online.single.$1, closeTo(1.106 * 2 + 0.553, 0.02));
      expect(online.single.$2, 'gps');
      expect(t.listening, isFalse);
      t.dispose();
    });

    test('with a reader linked the odometer\'s difference is reported', () async {
      odometer = 1000.0;
      final t = make();
      t.setOnline(true);
      await Future<void>.delayed(Duration.zero);
      await drive(0, 10);
      odometer = 1001.2;
      await t.flush();
      expect(online.single, (1.2, 'obd'));
      t.dispose();
    });

    test('a trip: the route estimate at accept, km to the pickup, km with the passenger', () async {
      final t = make();
      t.onRide(ride('accepted'));
      expect(t.listening, isTrue, reason: 'a trip listens even before going online');
      await Future<void>.delayed(Duration.zero);
      expect(checkpoints.single, ('r1', 'accept', null, null, 2.4));
      await drive(0, 9);
      t.onRide(ride('accepted'));
      t.onRide(ride('arrived'));
      await Future<void>.delayed(Duration.zero);
      expect(checkpoints.last.$2, 'arrive');
      expect(checkpoints.last.$3, closeTo(0.995, 0.01));
      await drive(100, 3, startSec: 500);
      t.onRide(ride('on_trip'));
      await drive(110, 20, startSec: 700);
      t.onRide(ride('completed'));
      await Future<void>.delayed(Duration.zero);
      expect(checkpoints.map((c) => c.$2), ['accept', 'arrive', 'start', 'complete']);
      expect(checkpoints.last.$3, closeTo(0.774 + 2.212, 0.03), reason: 'only what was driven from where the trip started');
      expect(t.listening, isFalse);
      t.dispose();
    });

    test('a trip first seen under way, or cancelled, reports nothing', () async {
      final t = make();
      t.onRide(ride('on_trip'));
      t.onRide(ride('completed'));
      t.onRide(ride('cancelled'));
      await Future<void>.delayed(Duration.zero);
      expect(checkpoints, isEmpty);
      expect(t.listening, isFalse);
      t.dispose();
    });

    test('switched off, it does nothing', () async {
      final t = TelematicsTracker(
        enabled: false,
        fixes: () => fixes.stream,
        reportOnline: (_, _) async => online.add((0, '')),
        checkpoint: (id, stage, {km, odometerKm, estKm}) async => checkpoints.add((id, stage, null, null, null)),
        odometer: () async => null,
        routeKm: (_, _) async => null,
      );
      t.setOnline(true);
      t.onRide(ride('accepted'));
      await t.flush();
      expect(t.listening, isFalse);
      expect(online, isEmpty);
      expect(checkpoints, isEmpty);
      t.dispose();
    });
  });

  group('dispatch', () {
    test('Telematics for fleet owners and stand people who may see reports', () {
      const fleet = DispatchGroup(id: 'g1', name: 'Sunlight', kind: GroupKind.fleet);
      const admin = DispatchStand(id: 's1', name: 'Pavilion', code: 'PAV', role: 'admin');
      const staff = DispatchStand(id: 's2', name: 'TBS', code: 'TBS', role: 'staff', perms: StandPerms());
      const reports = DispatchStand(id: 's3', name: 'KLCC', code: 'KLC', role: 'staff', perms: StandPerms(reports: true));
      expect(telematicsScopesFor(const DispatchRoles(fleets: [fleet], stands: [admin, staff, reports])).map((s) => s.id),
          ['g1', 's1', 's3']);
      expect(dispatchTabsFor(const DispatchRoles(stands: [staff])), isNot(contains('Telematics')));
      expect(dispatchTabsFor(const DispatchRoles(fleets: [fleet])), ['My fleet', 'Telematics']);
    });
  });

  for (final b in Brightness.values) {
    final mode = b == Brightness.dark ? ' (dark)' : '';

    testWidgets('driver: Side menu > Telematics$mode', (tester) async {
      tester.view.physicalSize = const Size(420, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = _FakeRepo();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserIdProvider.overrideWithValue('d1'),
            telematicsClockProvider.overrideWithValue(() => _now),
            telematicsRepositoryProvider.overrideWithValue(repo),
          ],
          child: MaterialApp(theme: appTheme(b), home: const TelematicsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.summaries.last.driverId, 'd1');
      expect(repo.summaries.last.range.bucket, TelematicsBucket.day, reason: 'this week by the day');
      expect(_text(tester, 'telematics-tile-online-value'), '50.0');
      expect(_text(tester, 'telematics-tile-trips-value'), '3');
      expect(_text(tester, 'telematics-tile-share-value'), '55%');
      expect(_text(tester, 'telematics-km-pickup-act'), '2.5');
      expect(_text(tester, 'telematics-km-trip-diff'), '+10.0%');
      expect(_text(tester, 'telematics-type-meter'), '1');
      expect(find.text('Taxi (meter)'), findsOneWidget);
      expect(find.text('With passenger'), findsOneWidget, reason: 'the legend');

      // A bar's numbers.
      await tester.tap(find.byKey(const ValueKey('telematics-bar-0')));
      await tester.pump();
      expect(find.byKey(const ValueKey('telematics-tooltip')), findsOneWidget);
      expect(find.text('With passenger 15.0 km'), findsOneWidget);

      // One vehicle.
      await tester.tap(find.byKey(const ValueKey('telematics-vehicle-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('WXY 1234 · Perodua Bezza').last);
      await tester.pumpAndSettle();
      expect(repo.summaries.last.vehicleId, 'v1');

      // Today, by the hour; then a custom range in day boxes.
      await tester.tap(find.text('Today'));
      await tester.pumpAndSettle();
      expect(repo.summaries.last.range.bucket, TelematicsBucket.hour);
      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('telematics-from')), findsOneWidget);
      expect(find.byKey(const ValueKey('telematics-to')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('driver: no actual km yet$mode', (tester) async {
      tester.view.physicalSize = const Size(420, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = _FakeRepo(
        fixed: TelematicsSummary.fromJson({
          'trips': 2,
          'km': {'est_trip': 12, 'with_actual': 0},
          'buckets': [
            {'start': '2026-10-19T00:00', 'trips': 2, 'trip_km': 12},
          ],
          'types': [{'kind': 'service:Ride', 'trips': 2}],
        }),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserIdProvider.overrideWithValue('d1'),
            telematicsClockProvider.overrideWithValue(() => _now),
            telematicsRepositoryProvider.overrideWithValue(repo),
          ],
          child: MaterialApp(theme: appTheme(b), home: const TelematicsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(_text(tester, 'telematics-tile-online-value'), '—');
      expect(_text(tester, 'telematics-km-trip-act'), '—');
      expect(_text(tester, 'telematics-km-trip-diff'), '—');
      expect(_text(tester, 'telematics-km-note'), contains('No actual km recorded'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('admin: Admin > Telematics$mode', (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = _FakeRepo();
      String? csv;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            moduleAccessProvider.overrideWith((ref, module) => AccessLevel.read),
            telematicsClockProvider.overrideWithValue(() => _now),
            telematicsRepositoryProvider.overrideWithValue(repo),
            earningsCsvSharerProvider.overrideWithValue((text, name, _) async {
              csv = text;
              return CsvShareOutcome.shared;
            }),
          ],
          child: MaterialApp(theme: appTheme(b), home: const AdminTelematicsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.summaries.last.scope, TelematicsScope.admin);
      expect(repo.summaries.last.driverId, isNull, reason: 'all drivers to start with');
      expect(find.text('All drivers in this period'), findsOneWidget);
      expect(find.text('Ahmad (D-1042)'), findsOneWidget);

      // Pick a driver from the searchable list.
      await tester.tap(find.byKey(const ValueKey('telematics-pick')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Siti (D-0877)').last);
      await tester.pumpAndSettle();
      expect(repo.summaries.last.driverId, 'd2');

      // Vehicles: the list is of vehicles now.
      await tester.tap(find.text('Vehicle'));
      await tester.pumpAndSettle();
      expect(repo.lists.last.group, TelematicsGroup.vehicle);
      expect(repo.summaries.last.driverId, isNull);
      await tester.tap(find.byKey(const ValueKey('telematics-row-v1')).first);
      await tester.pumpAndSettle();
      expect(repo.summaries.last.vehicleId, 'v1');

      await tester.tap(find.byKey(const ValueKey('telematics-export')));
      await tester.pumpAndSettle();
      expect(csv, startsWith('Plate,Vehicle,km driven online'));
      expect(tester.takeException(), isNull);
    });
  }
}

String _text(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(ValueKey(key))).data ?? '';

class _FakeRepo extends TelematicsRepository {
  _FakeRepo({this.fixed}) : super(null);

  final TelematicsSummary? fixed;
  final summaries = <TelematicsQuery>[];
  final lists = <TelematicsListQuery>[];

  @override
  Future<TelematicsSummary> summary(TelematicsQuery q) async {
    summaries.add(q);
    return fixed ??
        TelematicsSummary.fromJson({
          'mode': 'self',
          'online_recorded': true,
          'online_km': 50,
          'trips': 3,
          'km': {
            'est_pickup': 4, 'est_trip': 20, 'act_pickup': 2.5, 'act_trip': 22,
            'pickup_pairs': 1, 'trip_pairs': 2, 'est_pickup_paired': 2, 'act_pickup_paired': 2.5,
            'est_trip_paired': 20, 'act_trip_paired': 22, 'with_actual': 2, 'obd': 1,
          },
          'buckets': [
            {'start': '2026-10-19T00:00', 'trips': 2, 'pickup_km': 3, 'trip_km': 15, 'other_km': 10, 'online_km': 28},
            {'start': '2026-10-20T00:00', 'trips': 1, 'pickup_km': 1.5, 'trip_km': 8, 'other_km': 12.5, 'online_km': 22},
          ],
          'types': [{'kind': 'service:Ride', 'trips': 2}, {'kind': 'meter', 'trips': 1}],
        });
  }

  @override
  Future<List<TelematicsListRow>> list(TelematicsListQuery q) async {
    lists.add(q);
    Map<String, dynamic> row(String d, String name, String code, String v, String plate, double km) => {
      'driver_id': q.group == TelematicsGroup.vehicle ? null : d,
      'driver_name': q.group == TelematicsGroup.vehicle ? null : name,
      'driver_code': q.group == TelematicsGroup.vehicle ? null : code,
      'vehicle_id': q.group == TelematicsGroup.driver ? null : v,
      'plate': q.group == TelematicsGroup.driver ? null : plate,
      'vehicle': q.group == TelematicsGroup.driver ? null : 'Perodua Bezza',
      'online_km': km,
      'trips': 10,
      'est_trip_km': km / 2,
    };
    return [
      TelematicsListRow.fromJson(row('d1', 'Ahmad', 'D-1042', 'v1', 'WXY 1234', 812.4)),
      if (q.scope != TelematicsScope.self) TelematicsListRow.fromJson(row('d2', 'Siti', 'D-0877', 'v2', 'VBN 5521', 640.2)),
    ];
  }
}
