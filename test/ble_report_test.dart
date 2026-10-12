// Admin → Bluetooth & safety report: lib/src/core/ble_report.dart and
// lib/src/admin/screens/security/ble_report_screen.dart.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/security/ble_report_screen.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/ble_report.dart';
import 'package:get_ride/src/data/reliability_repository.dart';

Map<String, dynamic> _json({int days = 7}) => {
  'days': days,
  'starts': {'ble': 6, 'pin': 3, 'none': 0, 'unknown': 1},
  'daily': [
    for (var i = 0; i < days; i++)
      {
        'day': DateTime.utc(2026, 10, 6 + i).toIso8601String().substring(0, 10),
        'ble': i == 6 ? 6 : 0,
        'pin': i == 5 ? 3 : 0,
        'other': i == 4 ? 1 : 0,
      },
  ],
  'handshake': {
    'rides': 10,
    'both_phones': 8,
    'seen_both_ways': 6,
    'reports': 40,
    'matched_reports': 30,
    'avg_rssi': -61.4,
  },
  'safety': {
    'far_apart': 1,
    'no_proximity': 1,
    'separations': 2,
    'answered_ok': 3,
    'lost_open': 1,
    'lost_found': 1,
    'lost_returned': 0,
    'lost_not_found': 0,
  },
};

final _trips = [
  {
    'request_id': 'r1',
    'kind': 'separated',
    'at': '2026-10-12T06:00:00Z',
    'ride_status': 'on_trip',
    'pickup_name': 'KLCC',
    'rider_name': 'Rina',
    'driver_name': 'Dan',
    'answered_ok': true,
    'start_method': 'pin',
  },
  {
    'request_id': 'r2',
    'kind': 'lost_item',
    'at': '2026-10-12T05:00:00Z',
    'pickup_name': 'Mid Valley',
    'detail': 'open: Blue umbrella',
  },
  {'request_id': 'r3', 'kind': 'nonsense', 'at': '2026-10-12T05:00:00Z'},
];

void main() {
  group('the report', () {
    test('read from ble_safety_report', () {
      final r = BleSafetyReport.fromJson(_json());
      expect(r.startsTotal, 10);
      expect(r.startsOther, 1);
      expect(r.daily, hasLength(7));
      expect(r.daily.last.ble, 6);
      expect(r.avgRssi, -61);
      expect(r.flagged, 4);
      expect(r.lostTotal, 2);
      expect(BleSafetyReport.fromJson(null).startsTotal, 0);
    });

    test('shares never divide by nothing', () {
      expect(reportShare(6, 10), '60%');
      expect(reportShare(1, 3), '33%');
      expect(reportShare(0, 0), '—');
    });

    test('flagged trips: known kinds only, with names', () {
      final list = BleReportTrip.listFrom(_trips);
      expect(list, hasLength(2), reason: 'an unknown kind is dropped');
      expect(list.first.kind, BleReportKind.separated);
      expect(list.first.people, 'Rina → Dan');
      expect(list.first.startedBy, 'Trip code');
      expect(list.first.answeredOk, isTrue);
      expect(list.last.people, 'Passenger → Driver');
      expect(bleReportKindLabel(BleReportKind.noProximity), contains('without the phones meeting'));
    });
  });

  group('the page', () {
    Future<void> pump(WidgetTester tester, {ThemeMode mode = ThemeMode.light, Object? report, Object? trips}) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            adminAccessProvider.overrideWith((ref) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
            bleSafetyReportProvider.overrideWith(
              (ref, days) async => BleSafetyReport.fromJson(report ?? _json(days: days)),
            ),
            bleReportTripsProvider.overrideWith((ref, days) async => BleReportTrip.listFrom(trips ?? _trips)),
          ],
          child: MaterialApp(
            theme: appTheme(Brightness.light),
            darkTheme: appTheme(Brightness.dark),
            themeMode: mode,
            home: const AdminBleReportScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('starts, the handshake, safety and flagged trips (${mode.name})', (tester) async {
        await pump(tester, mode: mode);
        expect(find.byKey(const ValueKey('ble-report-starts-total')), findsOneWidget);
        expect(find.text('Bluetooth 6 (60%)'), findsOneWidget);
        expect(find.text('Trip code 3 (30%)'), findsOneWidget);
        expect(find.byKey(const ValueKey('ble-report-daily-bars')), findsOneWidget);
        expect(find.text('75% of rides where both took part'), findsOneWidget);
        expect(find.text('-61 dBm'), findsOneWidget);
        expect(find.text('Apart mid-trip'), findsWidgets);
        expect(find.byKey(const ValueKey('ble-report-trip-r1-separated')), findsOneWidget);
        expect(find.byKey(const ValueKey('ble-report-trip-r2-lostItem')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the chart has a table view', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('ble-report-table-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ble-report-daily-table')), findsOneWidget);
      expect(find.byKey(const ValueKey('ble-report-daily-bars')), findsNothing);
    });

    testWidgets('a trip opens its details', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('ble-report-trip-r2-lostItem')));
      await tester.pumpAndSettle();
      expect(find.text('open: Blue umbrella'), findsOneWidget);
      expect(find.text('Copy ride ID'), findsOneWidget);
    });

    testWidgets('the period changes what is asked for', (tester) async {
      await pump(tester);
      await tester.tap(find.text('30 days'));
      await tester.pumpAndSettle();
      expect(find.text('Last 30 days, Malaysian time'), findsOneWidget);
    });

    testWidgets('nothing yet reads as nothing, not as an error', (tester) async {
      await pump(tester, report: <String, dynamic>{'days': 7}, trips: const []);
      expect(find.text('No trips started in this period.'), findsOneWidget);
      expect(find.text('Nothing flagged in this period.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
