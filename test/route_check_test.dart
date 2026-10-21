import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/trip_safety.dart';
import 'package:get_ride/src/features/ride/route_check.dart';
import 'package:latlong2/latlong.dart';

// A straight road north from KLCC, about 3.3 km.
const _route = [LatLng(3.1579, 101.7116), LatLng(3.1879, 101.7116)];

/// [m] metres east of the road at [north] metres up it.
LatLng _at(double north, double east) =>
    LatLng(3.1579 + north / 111320.0, 101.7116 + east / (111320.0 * 0.99848));

void main() {
  final t0 = DateTime.utc(2026, 10, 21, 14);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

  group('distance to the route', () {
    test('metres from the nearest point of the line', () {
      expect(distanceToRouteM(_at(1000, 0), _route), lessThan(2));
      expect(distanceToRouteM(_at(1000, 600), _route), closeTo(600, 5));
      expect(distanceToRouteM(_at(-400, 0), _route), closeTo(400, 5), reason: 'before the start: to the end point');
      expect(distanceToRouteM(_at(0, 0), const []), double.infinity);
    });
  });

  group('the deviation detector', () {
    test('off by 500 m or more for 2 minutes asks once', () {
      final d = RouteDeviationDetector(route: _route, settings: const SafetySettings());
      // Moving along the road: nothing.
      for (var i = 0; i < 10; i++) {
        expect(d.add(_at(i * 100.0, 0), at(i * 10)), isNull);
      }
      // Off by 600 m, still moving (north along a parallel road).
      expect(d.add(_at(1000, 600), at(100)), isNull);
      expect(d.add(_at(1100, 600), at(160)), isNull);
      final alert = d.add(_at(1200, 600), at(220));
      expect(alert?.kind, RouteAlertKind.offRoute);
      expect(alert?.offM, closeTo(600, 5));
      expect(alert?.since, at(100));
      expect(d.add(_at(1300, 600), at(280)), isNull, reason: 'once');
    });
    test('499 m off is on the route; going back resets it', () {
      final d = RouteDeviationDetector(route: _route, settings: const SafetySettings());
      expect(d.add(_at(0, 499), at(0)), isNull);
      expect(d.add(_at(100, 499), at(200)), isNull);
      expect(d.add(_at(200, 700), at(210)), isNull);
      expect(d.add(_at(300, 0), at(300)), isNull, reason: 'back on the route');
      expect(d.add(_at(400, 700), at(310)), isNull);
      expect(d.add(_at(500, 700), at(429)), isNull, reason: 'off again, the 2 minutes start over');
      expect(d.add(_at(600, 700), at(430))?.kind, RouteAlertKind.offRoute);
    });
    test('stopped for 5 minutes asks', () {
      final d = RouteDeviationDetector(route: _route, settings: const SafetySettings());
      expect(d.add(_at(1000, 0), at(0)), isNull);
      expect(d.add(_at(1010, 5), at(120)), isNull, reason: 'GPS jitter is not moving');
      expect(d.add(_at(1005, 0), at(299)), isNull);
      final alert = d.add(_at(1000, 10), at(300));
      expect(alert?.kind, RouteAlertKind.stopped);
      expect(d.add(_at(1000, 10), at(400)), isNull, reason: 'once');
      expect(d.add(_at(1500, 0), at(420)), isNull, reason: 'moving again');
    });
    test('the admin\'s numbers, and off when switched off', () {
      const s = SafetySettings(routeOffM: 200, routeOffMin: 1, stoppedMin: 1);
      final d = RouteDeviationDetector(route: _route, settings: s);
      d.add(_at(0, 250), at(0));
      expect(d.add(_at(100, 250), at(60))?.kind, RouteAlertKind.offRoute);
      final off = RouteDeviationDetector(route: _route, settings: const SafetySettings(routeCheck: false));
      off.add(_at(0, 5000), at(0));
      expect(off.add(_at(0, 5000), at(3600)), isNull);
    });
    test('the question', () {
      final c = routeAlertCopy(RouteAlert(RouteAlertKind.offRoute, offM: 600, since: t0), minutes: 2);
      expect(c.title, 'Your car has left the planned route');
      expect(c.body, 'It is 600 m off the route for 2 minutes. Is everything OK?');
      expect(RouteAlertKind.offRoute.db, 'off_route');
      expect(RouteAlertKind.stopped.db, 'stopped');
      expect(routeAnswerWindow(const SafetySettings()), const Duration(seconds: 60));
    });
  });

  group('sharing at night', () {
    test('10 pm to 6 am', () {
      DateTime h(int hour, [int minute = 0]) => DateTime(2026, 10, 21, hour, minute);
      expect(tripShareAtNight(h(21, 59)), isFalse);
      expect(tripShareAtNight(h(22)), isTrue);
      expect(tripShareAtNight(h(0, 30)), isTrue);
      expect(tripShareAtNight(h(5, 59)), isTrue);
      expect(tripShareAtNight(h(6)), isFalse);
      expect(tripShareAtNight(h(13)), isFalse);
    });
    test('the rider\'s choice', () {
      final night = DateTime(2026, 10, 21, 23), day = DateTime(2026, 10, 21, 12);
      expect(TripShareMode.parse(null), TripShareMode.night, reason: 'the default');
      expect(tripSharedAt(TripShareMode.night, night), isTrue);
      expect(tripSharedAt(TripShareMode.night, day), isFalse);
      expect(tripSharedAt(TripShareMode.always, day), isTrue);
      expect(tripSharedAt(TripShareMode.never, night), isFalse);
      expect([for (final m in TripShareMode.values) m.label],
          ['Every trip', 'At night only (10 pm to 6 am)', 'Never']);
    });
  });

  for (final dark in [false, true]) {
    testWidgets('the sheet counts down to no answer (${dark ? 'dark' : 'light'})', (tester) async {
      String? answer = 'none';
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async => answer = await openRouteSheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Your car has left the planned route'), findsOneWidget);
      expect(find.text('No answer in 3 s: we tell your emergency contacts and support.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('No answer in 2 s: we tell your emergency contacts and support.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(answer, 'no_answer');
    });
  }

  testWidgets('I\'m OK answers it', (tester) async {
    String? answer;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(onPressed: () async => answer = await openRouteSheet(context), child: const Text('open')),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('route-check-ok')));
    await tester.pumpAndSettle();
    expect(answer, 'ok');
  });
}

/// The sheet on its own, as the watcher opens it.
Future<String?> openRouteSheet(BuildContext context) => Navigator.of(context).push<String>(
  _SheetRoute(
    builder: (_) => Scaffold(
      body: RouteCheckSheet(
        alert: RouteAlert(RouteAlertKind.offRoute, offM: 600, since: DateTime.utc(2026)),
        minutes: 2,
        wait: const Duration(seconds: 3),
      ),
    ),
  ),
);

class _SheetRoute<T> extends PageRouteBuilder<T> {
  _SheetRoute({required WidgetBuilder builder})
    : super(pageBuilder: (context, _, _) => builder(context));
}
