import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/partner_queue.dart';
import 'package:get_ride/src/core/vehicle_assignment.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/vehicle_assignment_repository.dart';
import 'package:get_ride/src/features/partner/partner_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:get_ride/src/data/partner_doc_check.dart';

const here = LatLng(3.1579, 101.7123);

class _FakeRides implements RideRepository {
  @override
  Future<RideRequest?> ongoingForPartner() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RideRequest _req(String id, double lat, {double fare = 12}) => RideRequest({
  'id': id,
  'status': 'open',
  'service': 'Teksi',
  'fare': fare,
  'currency': 'MYR',
  'distance_km': 5,
  'passengers': 1,
  'payment_mode': 'Cash',
  'pickup_name': 'From $id',
  'drop_name': 'To $id',
  'pickup_lat': lat,
  'pickup_lng': 101.7123,
  'drop_lat': 3.10,
  'drop_lng': 101.72,
});

void main() {
  test('the request picked on the map goes first, the rest keep their order', () {
    final q = [_req('a', 3.1), _req('b', 3.2), _req('c', 3.3)];
    expect(focusFirst(q, 'c').map((r) => r.id), ['c', 'a', 'b']);
    expect(focusFirst(q, 'a').map((r) => r.id), ['a', 'b', 'c']);
    expect(focusFirst(q, 'gone').map((r) => r.id), ['a', 'b', 'c']);
    expect(focusFirst(q, null).map((r) => r.id), ['a', 'b', 'c']);
  });

  group('screen', () {
    late StreamController<List<RideRequest>> open;

    setUp(() => open = StreamController<List<RideRequest>>.broadcast());
    tearDown(() => open.close());

    Future<void> pump(WidgetTester tester, {Size size = const Size(700, 1600)}) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      final router = GoRouter(
        routes: [GoRoute(path: '/', builder: (_, _) => const PartnerScreen())],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            partnerProvider.overrideWith((ref) async => Partner({'id': 'p1', 'status': 'approved', 'name': 'Ali'})),
            openRequestsProvider.overrideWith((ref) => open.stream),
            rideRepositoryProvider.overrideWithValue(_FakeRides()),
            driverPositionProvider.overrideWithValue(() async => here),
            profileProvider.overrideWith((ref) async => Profile({'id': 'me'})),
            assignableVehiclesProvider.overrideWith((ref) async => const <AssignableVehicle>[]),
            partnerDocCheckProvider.overrideWithValue((_, {required teksi}) async => const []),
            partnerTypeEntriesProvider.overrideWith(
              (ref) async => [
                (id: 'e', values: <String, dynamic>{'name': 'eHailing', 'vehicleRequired': false}),
              ],
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> goOnline(WidgetTester tester) async {
      await tester.tap(find.text('You are offline'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('offline, the map shows only the driver', (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('driver-home-map')), findsOneWidget);
      open.add([_req('a', 3.1585)]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('map-request-a')), findsNothing);
    });

    testWidgets('online, each request is pinned with its fare; a tap brings it to the top', (tester) async {
      await pump(tester);
      // Requests already open when the driver goes online queue without a spotlight.
      open.add([_req('near', 3.15), _req('far', 3.30, fare: 30)]);
      await tester.pumpAndSettle();
      await goOnline(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('map-request-near')), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('map-request-far')), matching: find.text('RM30.00')),
        findsOneWidget,
      );
      double y(String id) => tester.getTopLeft(find.byKey(ValueKey('queue-$id'))).dy;
      expect(y('near'), lessThan(y('far')));
      // The pin may sit under the cards floating on the map: press it directly.
      tester.widget<GestureDetector>(find.byKey(const ValueKey('map-request-far'))).onTap!();
      await tester.pumpAndSettle();
      expect(y('far'), lessThan(y('near')));
    });

    testWidgets('on a phone the requests float on the map and the sheet is held down', (tester) async {
      await pump(tester);
      final opened = tester.getTopLeft(find.byKey(const ValueKey('map-sheet-handle'))).dy;
      await goOnline(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('waiting-for-requests')), findsOneWidget, reason: 'on the map, not in the sheet');
      expect(find.text('New requests appear here instantly.'), findsNothing);

      open.add([_req('near', 3.15), _req('far', 3.30, fare: 30)]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('waiting-for-requests')), findsNothing);
      final list = find.byKey(const ValueKey('floating-requests'));
      // The first new one is spotlighted, the other queues: both on the map.
      expect(find.descendant(of: list, matching: find.textContaining('RM12.00')), findsWidgets);
      expect(find.descendant(of: list, matching: find.textContaining('RM30.00')), findsWidgets);

      // Held down: neither dragged up nor scrolled.
      final handle = find.byKey(const ValueKey('map-sheet-handle'));
      final top = tester.getTopLeft(handle).dy;
      expect(top, opened, reason: 'still all the way down, where it opened');
      await tester.drag(handle, const Offset(0, -400), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(handle).dy, top);

      // The last request taken: it flies out and the sheet is free again.
      open.add(const []);
      await tester.pumpAndSettle();
      expect(find.descendant(of: list, matching: find.textContaining('RM12.00')), findsNothing);
      await tester.drag(handle, const Offset(0, -400), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(handle).dy, lessThan(top - 200));
    });

    testWidgets('no top bar: the page buttons float, the menu at the far right', (tester) async {
      await pump(tester);
      expect(find.byType(AppBar), findsNothing);
      final menu = tester.getRect(find.byKey(const ValueKey('partner-menu-button')));
      final vehicles = tester.getRect(find.byTooltip('My vehicles'));
      expect(menu.left, greaterThan(vehicles.right), reason: 'the menu is the rightmost');
      expect(menu.top, lessThan(80), reason: 'at the top of the page');
      await tester.tap(find.byKey(const ValueKey('partner-menu-button')));
      await tester.pumpAndSettle();
    });

    testWidgets('the sheet starts all the way down, showing only the online switch', (tester) async {
      await pump(tester);
      double shown() => tester.widget<Opacity>(find.byKey(const ValueKey('map-sheet-body'))).opacity;
      // It opens all the way down, and stays there going online.
      expect(find.byKey(const ValueKey('partner-online')).hitTestable(), findsOneWidget);
      expect(shown(), 0, reason: 'starts fully down: the rest is hidden, not peeking');
      await goOnline(tester);
      await tester.pumpAndSettle();
      final handle = find.byKey(const ValueKey('map-sheet-handle'));
      expect(shown(), 0);
      await tester.drag(handle, const Offset(0, -400), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(shown(), 1);
    });

    testWidgets('the online switch comes before the service types', (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('partner-online')), findsOneWidget);
      expect(find.textContaining(' · ·'), findsNothing, reason: 'no empty parts in the subtitle');
    });

    testWidgets('on a wide screen the map sits beside the queue', (tester) async {
      await pump(tester, size: const Size(1400, 900));
      final map = tester.getRect(find.byKey(const ValueKey('driver-home-map')));
      expect(map.left, greaterThan(500));
      expect(map.height, greaterThan(800));
    });
  });
}
