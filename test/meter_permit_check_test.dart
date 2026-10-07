import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/driver_permit.dart';
import 'package:get_ride/src/core/vehicle_assignment.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/partner_doc_check.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/vehicle_assignment_repository.dart';
import 'package:get_ride/src/features/partner/driver_permit_screen.dart';
import 'package:get_ride/src/features/partner/partner_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

final today = DateTime(2026, 10, 6, 9);

class _FakeRides implements RideRepository {
  @override
  Future<RideRequest?> ongoingForPartner() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<void> pump(WidgetTester tester, DriverPermit permit, {String? plate}) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 1400);
    addTearDown(tester.view.reset);
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const PartnerScreen()),
        GoRoute(
          path: '/meter',
          builder: (_, _) => const Scaffold(body: Text('meter')),
        ),
        GoRoute(
          path: '/drive/onboarding',
          builder: (_, _) => const Scaffold(body: Text('documents')),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          partnerProvider.overrideWith(
            (ref) async => Partner({
              'id': 'p1',
              'status': 'approved',
              'name': 'Ali',
              'partner_types': ['TEKSI'],
            }),
          ),
          openRequestsProvider.overrideWith((ref) => const Stream.empty()),
          rideRepositoryProvider.overrideWithValue(_FakeRides()),
          profileProvider.overrideWith((ref) async => Profile({'id': 'me'})),
          driverPositionProvider.overrideWithValue(() async => const LatLng(3.15, 101.71)),
          requestAlertClockProvider.overrideWithValue(() => today),
          partnerDocCheckProvider.overrideWithValue((_, {required teksi}) async => const []),
          partnerTypeEntriesProvider.overrideWith(
            (ref) async => [
              (id: 't', values: <String, dynamic>{'name': 'TEKSI', 'vehicleRequired': false}),
            ],
          ),
          assignableVehiclesProvider.overrideWith((ref) async => const <AssignableVehicle>[]),
          driverPermitProvider.overrideWith((ref) async => permit),
          currentPlateProvider.overrideWith((ref) async => plate),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  // The Meter Digital button spins while its checks run, and behind the
  // permit dialog until that is answered, so this doesn't wait to settle.
  Future<void> openMeter(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Meter Digital'));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('a valid permit opens the meter', (tester) async {
    await pump(
      tester,
      DriverPermit(expiryDate: DateTime(2027, 1, 1), vehiclePlate: 'WXY 1234'),
      plate: 'wxy1234',
    );
    await openMeter(tester);
    expect(find.text('meter'), findsOneWidget);
  });

  testWidgets('an expired permit holds the meter and points at the documents', (tester) async {
    await pump(tester, DriverPermit(expiryDate: DateTime(2026, 10, 1)));
    await openMeter(tester);
    expect(find.byKey(const ValueKey('permit-block')), findsOneWidget);
    expect(find.text('Permit expired'), findsOneWidget);
    expect(find.text('meter'), findsNothing);
    await tester.tap(find.text('Update documents'));
    await tester.pumpAndSettle();
    expect(find.text('documents'), findsOneWidget);
  });

  testWidgets('another car than the permit names holds the meter', (tester) async {
    await pump(tester, const DriverPermit(vehiclePlate: 'WXY 1234'), plate: 'ABC 9');
    await openMeter(tester);
    expect(find.text('Vehicle mismatch'), findsOneWidget);
    expect(find.text('meter'), findsNothing);
  });

  testWidgets('an IC that differs from the profile holds the meter', (tester) async {
    await pump(tester, const DriverPermit(permitIcNumber: '900101-14-5555', profileIcCandidates: ['880202-10-1111']));
    await openMeter(tester);
    expect(find.text('IC number mismatch'), findsOneWidget);
  });
}
