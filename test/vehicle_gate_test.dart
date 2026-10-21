import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/partner_modes.dart';
import 'package:get_ride/src/core/vehicle_assignment.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/partner_doc_check.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/vehicle_assignment_repository.dart';
import 'package:get_ride/src/features/partner/partner_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';

/// A driver can't go online, send an offer or accept a request without a
/// vehicle in use (the rider's offer card shows its plate and car).

AssignableVehicle _v(String id, String plate, AssignableStatus status, {VehicleRole role = VehicleRole.owner}) =>
    AssignableVehicle(vehicle: {'id': id, 'plate': plate, 'make': 'Proton', 'model': 'Saga'}, role: role, status: status);

class _Vehicles implements VehicleAssignmentRepository {
  _Vehicles(this.vehicles);

  List<AssignableVehicle> vehicles;
  final claimed = <String>[];
  var sessionChecks = 0;

  void drive(String? id) => vehicles = [
    for (final v in vehicles)
      AssignableVehicle(
        vehicle: v.vehicle,
        role: v.role,
        status: v.id == id ? AssignableStatus.inUseByYou : (v.inUseByMe ? AssignableStatus.available : v.status),
      ),
  ];

  @override
  Future<List<AssignableVehicle>> assignable() async => vehicles;

  @override
  Future<bool> hasSession() async {
    sessionChecks++;
    return vehicles.any((v) => v.inUseByMe);
  }

  @override
  Future<void> claim(String vehicleId) async {
    claimed.add(vehicleId);
    drive(vehicleId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Rides implements RideRepository {
  final offered = <String>[];

  @override
  Future<RideRequest?> ongoingForPartner() async => null;

  @override
  Future<RideRequest?> submitOffer(
    String id,
    double amount,
    Partner? partner, {
    double? lat,
    double? lng,
    String? fallbackName,
    String? fallbackPhone,
  }) async {
    offered.add(id);
    // This rider auto-accepts: the ride is taken in the same write.
    return RideRequest({'id': id, 'status': 'accepted', 'partner_id': 'me'});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RideRequest _req(String id) => RideRequest({
  'id': id,
  'status': 'open',
  'service': 'eHailing',
  'fare': 12,
  'ride_fare': 12,
  'currency': 'MYR',
  'distance_km': 5,
  'passengers': 1,
  'payment_mode': 'Cash',
});

void main() {
  group('vehicleGateFor', () {
    test('a vehicle in use: ready', () {
      final g = vehicleGateFor([
        _v('a', 'A 1', AssignableStatus.available),
        _v('b', 'B 2', AssignableStatus.inUseByYou),
      ]);
      expect(g.kind, VehicleGateKind.ready);
    });

    test('exactly one that can be driven: taken for the driver', () {
      final g = vehicleGateFor([
        _v('a', 'A 1', AssignableStatus.pendingReview),
        _v('b', 'B 2', AssignableStatus.available, role: VehicleRole.driver),
        _v('c', 'C 3', AssignableStatus.incomplete),
      ]);
      expect(g.kind, VehicleGateKind.takeOnly);
      expect(g.vehicle?.id, 'b');
    });

    test('several that can be driven: the driver picks', () {
      final g = vehicleGateFor([
        _v('a', 'A 1', AssignableStatus.available),
        _v('b', 'B 2', AssignableStatus.available),
      ]);
      expect(g.kind, VehicleGateKind.choose);
      expect(g.vehicle, isNull);
    });

    test('none that can be driven: finish the own half set-up one, else see why, else add one', () {
      final finish = vehicleGateFor([
        _v('a', 'A 1', AssignableStatus.pendingReview),
        _v('b', 'B 2', AssignableStatus.incomplete),
      ]);
      expect(finish.kind, VehicleGateKind.finish);
      expect(finish.vehicle?.id, 'b');

      // Someone else's half set-up car is not this driver's to finish.
      final waiting = [
        _v('a', 'A 1', AssignableStatus.pendingReview),
        _v('b', '', AssignableStatus.incomplete, role: VehicleRole.driver),
        _v('c', 'C 3', AssignableStatus.contactAdmin),
      ];
      expect(vehicleGateFor(waiting).kind, VehicleGateKind.waiting);
      expect(
        vehicleGateWaitingLines(waiting),
        'A 1: An admin is still reviewing this vehicle.\n'
        "Proton Saga: The owner hasn't finished setting it up.\n"
        'C 3: This vehicle is locked. Contact an admin.',
      );

      expect(vehicleGateFor(const []).kind, VehicleGateKind.add);
    });

    test('a claim refused as not approved has its own words', () {
      expect(claimVehicleErrorMessage(Exception('vehicle_not_approved')), "This vehicle isn't approved to drive yet.");
    });
  });

  group('partner screen', () {
    late _Vehicles vehicles;
    late _Rides rides;
    late StreamController<List<RideRequest>> open;

    setUp(() {
      rides = _Rides();
      open = StreamController<List<RideRequest>>.broadcast();
    });
    tearDown(() => open.close());

    Future<void> pump(WidgetTester tester, {Brightness brightness = Brightness.light}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 1400);
      addTearDown(tester.view.reset);
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const PartnerScreen()),
          GoRoute(path: '/drive/vehicles', builder: (_, _) => const Scaffold(body: Text('my vehicles'))),
          GoRoute(path: '/drive/trip/:id', builder: (_, s) => Scaffold(body: Text('trip ${s.pathParameters['id']}'))),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserIdProvider.overrideWithValue('me'),
            partnerProvider.overrideWith(
              (ref) async => Partner({'id': 'p1', 'status': 'approved', 'name': 'Ali', 'partner_types': ['eHailing']}),
            ),
            profileProvider.overrideWith((ref) async => Profile({'id': 'me'})),
            rideRepositoryProvider.overrideWithValue(rides),
            openRequestsProvider.overrideWith((ref) => open.stream),
            vehicleAssignmentRepositoryProvider.overrideWithValue(vehicles),
            assignableVehiclesProvider.overrideWith((ref) => ref.watch(vehicleAssignmentRepositoryProvider).assignable()),
            partnerTypeEntriesProvider.overrideWith(
              (ref) async => <PartnerTypeEntry>[
                (id: 'e', values: <String, dynamic>{'name': 'eHailing', 'vehicleRequired': true}),
              ],
            ),
            partnerDocCheckProvider.overrideWithValue((partner, {required teksi}) async => const []),
          ],
          child: MaterialApp.router(theme: ThemeData(brightness: brightness), routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> pumpOpen(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> goOnline(WidgetTester tester) async {
      await tester.tap(find.text('You are offline'));
      await pumpOpen(tester);
    }

    for (final b in Brightness.values) {
      testWidgets('going online with one approved vehicle takes it, no questions (${b.name})', (tester) async {
        vehicles = _Vehicles([
          _v('v1', 'WXY 1', AssignableStatus.available),
          _v('v2', 'WXY 2', AssignableStatus.pendingReview),
        ]);
        await pump(tester, brightness: b);
        await goOnline(tester);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('vehicle-required')), findsNothing);
        expect(vehicles.claimed, ['v1']);
        expect(find.text('You are online'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('going online with no approved vehicle says why, with the way to the vehicles page', (tester) async {
      vehicles = _Vehicles([_v('v1', 'WXY 1', AssignableStatus.pendingReview)]);
      await pump(tester);
      await goOnline(tester);
      expect(find.byKey(const ValueKey('vehicle-required')), findsOneWidget);
      expect(find.text('No vehicle ready to drive'), findsOneWidget);
      expect(find.textContaining('WXY 1: An admin is still reviewing this vehicle.'), findsOneWidget);
      await tester.tap(find.text('My vehicles'));
      await tester.pumpAndSettle();
      expect(find.text('my vehicles'), findsOneWidget);
      expect(vehicles.claimed, isEmpty);
    });

    testWidgets('going online with several asks which one, and the one picked is taken', (tester) async {
      vehicles = _Vehicles([
        _v('v1', 'WXY 1', AssignableStatus.available),
        _v('v2', 'WXY 2', AssignableStatus.available),
      ]);
      await pump(tester);
      await goOnline(tester);
      expect(find.text('Choose a vehicle'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('vehicle-required-go')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pick-v2')));
      await tester.pumpAndSettle();
      expect(vehicles.claimed, ['v2']);
      expect(find.text('You are online'), findsOneWidget);
    });

    /// Online with [first] in use; then the session ends (another phone, an
    /// admin) and the vehicles are [after].
    Future<void> onlineThenSessionEnds(WidgetTester tester, List<AssignableVehicle> after) async {
      vehicles = _Vehicles([_v('v1', 'WXY 1', AssignableStatus.inUseByYou)]);
      await pump(tester);
      await goOnline(tester);
      await tester.pumpAndSettle();
      expect(find.text('You are online'), findsOneWidget);
      vehicles.vehicles = after;
      open.add([_req('r1')]);
      await tester.pumpAndSettle();
    }

    testWidgets('accepting without a vehicle in use asks for one and sends nothing', (tester) async {
      await onlineThenSessionEnds(tester, [
        _v('v1', 'WXY 1', AssignableStatus.available),
        _v('v2', 'WXY 2', AssignableStatus.available),
      ]);
      await tester.tap(find.byKey(const ValueKey('request-alert-accept')));
      // The request's button may spin behind the dialog: don't settle.
      await pumpOpen(tester);
      expect(vehicles.sessionChecks, 1, reason: 'the session is read fresh before the offer');
      expect(find.byKey(const ValueKey('vehicle-required')), findsOneWidget);
      expect(find.textContaining('before you can accept a request'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(rides.offered, isEmpty, reason: 'no offer without a vehicle');
      expect(vehicles.claimed, isEmpty);
    });

    testWidgets('accepting without a vehicle in use, with no approved vehicle: says why, sends nothing',
        (tester) async {
      await onlineThenSessionEnds(tester, [_v('v1', 'WXY 1', AssignableStatus.contactAdmin)]);
      await tester.tap(find.byKey(const ValueKey('request-alert-accept')));
      // The request's button may spin behind the dialog: don't settle.
      await pumpOpen(tester);
      expect(find.text('No vehicle ready to drive'), findsOneWidget);
      await tester.tap(find.text('My vehicles'));
      await tester.pumpAndSettle();
      expect(find.text('my vehicles'), findsOneWidget);
      expect(rides.offered, isEmpty);
    });

    testWidgets('accepting with one approved vehicle not in use takes it first, then sends the offer', (tester) async {
      await onlineThenSessionEnds(tester, [_v('v1', 'WXY 1', AssignableStatus.available)]);
      await tester.tap(find.byKey(const ValueKey('request-alert-accept')));
      await tester.pumpAndSettle();
      expect(vehicles.claimed, ['v1']);
      expect(rides.offered, ['r1']);
      expect(find.text('trip r1'), findsOneWidget);
    });

    testWidgets('accepting with a vehicle in use sends the offer at once', (tester) async {
      vehicles = _Vehicles([_v('v1', 'WXY 1', AssignableStatus.inUseByYou)]);
      await pump(tester);
      await goOnline(tester);
      await tester.pumpAndSettle();
      open.add([_req('r1')]);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('request-alert-accept')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('vehicle-required')), findsNothing);
      expect(vehicles.claimed, isEmpty);
      expect(rides.offered, ['r1']);
    });
  });
}
