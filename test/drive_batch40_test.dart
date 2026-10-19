// Driver-side web tester items (batch 40): demo requests float as real
// ones do (118), the custom offer button is named (119), the request's age
// is not read as time left (120), the map chips say what they are and stay
// over the car (121), the demo job's sheet is capped and draws the way to
// the pickup (122), and the online card names the vehicle actually taken
// (123).
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/demo_mode.dart';
import 'package:get_ride/src/core/request_viewers.dart';
import 'package:get_ride/src/core/vehicle_assignment.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/partner_doc_check.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/vehicle_assignment_repository.dart';
import 'package:get_ride/src/features/partner/demo_jobs.dart';
import 'package:get_ride/src/features/partner/partner_screen.dart';
import 'package:get_ride/src/features/partner/request_sheet.dart';
import 'package:get_ride/src/features/partner/vehicle_picker.dart';
import 'package:get_ride/src/features/ride/demo_ride.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const here = LatLng(3.1579, 101.7123);

class _Rides implements RideRepository {
  @override
  Future<RideRequest?> ongoingForPartner() async => null;

  @override
  Future<RequestViewers> viewers(String requestId) async => RequestViewers.none;

  @override
  Future<void> markViewed(String requestId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AssignableVehicle car(String id, AssignableStatus status) => AssignableVehicle(
  vehicle: {'id': id, 'plate': 'WXY $id', 'make': 'Proton', 'model': 'Saga'},
  role: VehicleRole.driver,
  status: status,
);

Future<void> pumpDrive(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  bool demo = false,
  List<AssignableVehicle> vehicles = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final router = GoRouter(routes: [GoRoute(path: '/', builder: (_, _) => const PartnerScreen())]);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        partnerProvider.overrideWith(
          (ref) async => Partner({
            'id': 'p1',
            'status': 'approved',
            'name': 'Test Rider',
            'vehicle': 'Perodua Myvi',
            'plate': 'WXY 1234',
          }),
        ),
        openRequestsProvider.overrideWith((ref) => Stream.value(const <RideRequest>[])),
        rideRepositoryProvider.overrideWithValue(_Rides()),
        driverPositionProvider.overrideWithValue(() async => here),
        driverPositionStreamProvider.overrideWithValue(() => const Stream.empty()),
        profileProvider.overrideWith((ref) async => Profile({'id': 'me'})),
        assignableVehiclesProvider.overrideWith((ref) async => vehicles),
        partnerDocCheckProvider.overrideWithValue((_, {required teksi}) async => const []),
        demoSettingsProvider.overrideWithValue(DemoSettings(partnerRequests: demo)),
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

RideRequest request({Map<String, dynamic> extra = const {}}) => RideRequest({
  'id': 'r1',
  'rider_id': 'rider',
  'status': 'open',
  'fare': 20,
  'currency': 'MYR',
  'pickup_name': 'KLCC',
  'drop_name': 'KL Sentral',
  'pickup_lat': 3.1579,
  'pickup_lng': 101.7116,
  'drop_lat': 3.1340,
  'drop_lng': 101.6860,
  'distance_km': 7.4,
  'duration_min': 19,
  'offer_me': true,
  'created_at': DateTime.now().subtract(const Duration(seconds: 13)).toUtc().toIso8601String(),
  ...extra,
});

Future<void> pumpSheet(WidgetTester tester, {LatLng? me}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [rideRepositoryProvider.overrideWithValue(_Rides())],
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: RideRequestSheet(
              request: request(),
              shown: const Duration(seconds: 4),
              now: DateTime.now(),
              me: me ?? const LatLng(3.17, 101.70),
              awayKm: 1.8,
              onAccept: () async {},
              onSkip: () {},
              onOffer: (_) async {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  group('118 demo requests', () {
    testWidgets('on a phone the demo request floats on the map, the sheet held down, no waiting pill', (tester) async {
      await pumpDrive(tester, demo: true);
      await goOnline(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('waiting-for-requests')), findsOneWidget);
      await tester.pump(const Duration(seconds: 15));
      await tester.pump();
      final job = find.byKey(const ValueKey('demo-job'));
      expect(job, findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('floating-requests')), matching: job), findsOneWidget);
      final sheetTop = tester.getTopLeft(find.byKey(const ValueKey('map-sheet-handle'))).dy;
      expect(tester.getRect(job).bottom, lessThanOrEqualTo(sheetTop), reason: 'over the map, above the sheet');
      expect(tester.getRect(job).top, greaterThanOrEqualTo(0));
      expect(find.byKey(const ValueKey('waiting-for-requests')), findsNothing);
      // Declined: waiting again.
      await tester.tap(find.text('Decline'));
      await tester.pump();
      expect(find.byKey(const ValueKey('waiting-for-requests')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('on a desktop no "Waiting for requests" under a demo request', (tester) async {
      await pumpDrive(tester, demo: true, size: const Size(1366, 900));
      await goOnline(tester);
      await tester.pumpAndSettle();
      expect(find.text('New requests appear here instantly.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 15));
      await tester.pump();
      expect(find.byKey(const ValueKey('demo-job')), findsOneWidget);
      expect(find.text('New requests appear here instantly.'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('request sheet', () {
    testWidgets('119: the pencil is named "Offer another fare"', (tester) async {
      await pumpSheet(tester);
      expect(find.byTooltip('Offer another fare'), findsOneWidget);
      // The tooltip is the button's own (IconButton.tooltip), and the
      // button node carries the name (desktop 119).
      expect(
        find.descendant(of: find.byKey(const ValueKey('request-offer-custom')), matching: find.byTooltip('Offer another fare')),
        findsOneWidget,
      );
    });

    testWidgets("120: the request's age reads as an age, the seconds left stand on the bar", (tester) async {
      await pumpSheet(tester);
      expect(find.text('13 s ago'), findsOneWidget);
      expect(find.textContaining('sec.'), findsNothing);
      expect(tester.widget<Text>(find.byKey(const ValueKey('request-alert-seconds-left'))).data, '31s');
      final bar = tester.getRect(find.byKey(const ValueKey('request-alert-countdown')));
      final left = tester.getRect(find.byKey(const ValueKey('request-alert-seconds-left')));
      expect(left.left, greaterThanOrEqualTo(bar.right), reason: 'beside the bar');
    });

    testWidgets('121: the chips say what they are and stand over the car', (tester) async {
      // The car near the drop-off.
      await pumpSheet(tester, me: const LatLng(3.1342, 101.6862));
      expect(
        find.descendant(of: find.byKey(const ValueKey('request-chip-pickup')), matching: find.textContaining('To pickup')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: find.byKey(const ValueKey('request-chip-trip')), matching: find.text('Trip\n19 min · 7.4 km')),
        findsOneWidget,
      );
      // Drawn last: the car's layer is under them.
      final layers = find.byType(MarkerLayer);
      expect(find.descendant(of: layers.last, matching: find.byKey(const ValueKey('request-chip-trip'))), findsOneWidget);
      expect(find.descendant(of: layers.last, matching: find.byKey(const ValueKey('driver-heading'))), findsNothing);
      expect(find.descendant(of: layers.last, matching: find.byIcon(Icons.local_taxi)), findsNothing);
      expect(find.byIcon(Icons.local_taxi), findsOneWidget);
    });
  });

  group('122 demo job', () {
    Future<void> pumpJob(WidgetTester tester, Size size) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            demoSettingsProvider.overrideWithValue(const DemoSettings()),
            geoServiceProvider.overrideWithValue(GeoService(client: MockClient((_) async => http.Response('', 500)))),
          ],
          child: MaterialApp(home: DemoJobScreen(job: demoJob(math.Random(1), id: 'j'))),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('on a desktop the sheet is no wider than 760, and the way to the pickup is drawn', (tester) async {
      await pumpJob(tester, const Size(1366, 900));
      expect(tester.getSize(find.byKey(const ValueKey('demo-job-next'))).width, lessThanOrEqualTo(760));
      expect(find.byKey(const ValueKey('demo-job-to-pickup')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('demo-job-next')));
      await tester.pump();
      expect(find.byKey(const ValueKey('demo-job-to-pickup')), findsNothing, reason: 'at the pickup');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('on a phone the sheet keeps its width', (tester) async {
      await pumpJob(tester, const Size(390, 844));
      expect(tester.getSize(find.byKey(const ValueKey('demo-job-next'))).width, 390 - 32);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('123 vehicle on the online card', () {
    testWidgets('"No vehicle chosen" until one is taken, not the profile car', (tester) async {
      await pumpDrive(tester, vehicles: [car('1', AssignableStatus.available)]);
      expect(find.text('Test Rider · No vehicle chosen'), findsOneWidget);
      expect(find.textContaining('Perodua'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the vehicle taken, once there is one', (tester) async {
      await pumpDrive(tester, vehicles: [car('1', AssignableStatus.inUseByYou)]);
      expect(find.text('Test Rider · Proton Saga · WXY 1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the one usable vehicle comes picked out, still taken by a tap', (tester) async {
      AssignableVehicle? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => picked = await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      body: VehiclePickerSheet(
                        vehicles: [car('1', AssignableStatus.available), car('2', AssignableStatus.pendingReview)],
                        preselect: '1',
                      ),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.widget<ListTile>(find.byKey(const ValueKey('pick-1'))).selected, isTrue);
      expect(tester.widget<ListTile>(find.byKey(const ValueKey('pick-2'))).selected, isFalse);
      expect(picked, isNull, reason: 'nothing taken without a tap');
      await tester.tap(find.byKey(const ValueKey('pick-1')));
      await tester.pumpAndSettle();
      expect(picked?.id, '1');
    });
  });
}
