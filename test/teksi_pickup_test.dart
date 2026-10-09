// Start Pickup on the TEKSI permit screen (Expo `partner-teksi`): the
// permit's checks with the vehicle re-pick, "Select tariff", the trip summary
// and "Confirm your trip", then the meter with the hire running on the tariff.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/meter_logic.dart';
import 'package:get_ride/src/core/driver_permit.dart';
import 'package:get_ride/src/core/street_hail.dart';
import 'package:get_ride/src/core/teksi_tariff.dart';
import 'package:get_ride/src/core/vehicle_assignment.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/vehicle_assignment_repository.dart';
import 'package:get_ride/src/features/meter/meter_providers.dart';
import 'package:get_ride/src/features/meter/meter_screen.dart' show MeterLaunch;
import 'package:get_ride/src/features/partner/driver_permit_screen.dart';
import 'package:get_ride/src/features/partner/teksi_pickup.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _today = DateTime(2026, 10, 9, 9);

AssignableVehicle _car(String id, String plate, {bool mine = false}) => AssignableVehicle(
  vehicle: {'id': id, 'plate': plate, 'make': 'Proton', 'model': 'Saga'},
  role: VehicleRole.driver,
  status: mine ? AssignableStatus.inUseByYou : AssignableStatus.available,
);

/// Two cars: the one being driven, and the one the permit names.
class _Vehicles implements VehicleAssignmentRepository {
  _Vehicles(this.driving);
  String driving;
  final claimed = <String>[];

  @override
  Future<List<AssignableVehicle>> assignable() async => [
    _car('a', 'ABC 9', mine: driving == 'a'),
    _car('w', 'WXY 1234', mine: driving == 'w'),
  ];

  @override
  Future<void> claim(String vehicleId) async {
    claimed.add(vehicleId);
    driving = vehicleId;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

const _klcc = HailDestination(name: 'KLCC', latitude: 3.158, longitude: 101.712, routeKm: 8.2, routeMin: 18);

void main() {
  group('tariffs', () {
    final builtIn = resolveMeterProfile(const []);
    test('the built-in card bills on the tariff picked, Old where none was', () {
      expect(tariffKeysApply(builtIn), isTrue);
      expect(ratesForTariff(builtIn, TeksiTariff.newTariff), same(tariffRates['new']));
      expect(ratesForTariff(builtIn, null), same(tariffRates['old']));
      expect(tariffRateLabel(builtIn, TeksiTariff.newTariff), 'New Tariff');
      expect(tariffSummaryLines(builtIn, TeksiTariff.newTariff), [
        'RM4.00 base fare',
        '+ RM1.00 per KM',
        '+ RM0.30 per minute',
      ]);
      expect(TeksiTariff.oldTariff.lines.first, 'a) RM4.00 per KM or part');
      expect(TeksiTariff.newTariff.keyLabel, 'NEW RATES');
      expect(TeksiTariff.fromId('old'), TeksiTariff.oldTariff);
      expect(TeksiTariff.fromId('x'), isNull);
    });

    test("an operator's card wins over the tariff", () {
      final card = resolveMeterProfile([
        defaultMeterProfile.copyWith(
          id: 'm',
          level: 'master',
          label: () => 'KL Operator',
          rates: tariffRates['new']!.copyWith(flagFare: 6),
        ),
      ]);
      expect(tariffKeysApply(card), isFalse);
      expect(ratesForTariff(card, TeksiTariff.oldTariff).flagFare, 6);
      expect(tariffRateLabel(card, TeksiTariff.oldTariff), 'KL Operator');
      expect(tariffSummaryLines(card, TeksiTariff.oldTariff), ['Rate card: KL Operator']);
    });

    test('the two tariffs price a trip as Expo calculateFare does', () {
      // 8.2 km in 18 min. New: 4 + 8.2 + 5.40.
      expect(hailEstimate(TeksiTariff.newTariff.rates, _klcc), closeTo(17.60, 0.01));
      // Old: 4 + 0.35 × max(36 blocks of 200 m, time past the first km in 36 s).
      final old = hailEstimate(TeksiTariff.oldTariff.rates, _klcc)!;
      expect(old, greaterThanOrEqualTo(4 + 36 * 0.35));
    });
  });

  group('Start Pickup', () {
    late _Vehicles vehicles;
    Object? launched;

    Future<void> pump(WidgetTester tester, DriverPermit permit, {String driving = 'w'}) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(500, 1000);
      addTearDown(tester.view.reset);
      vehicles = _Vehicles(driving);
      launched = null;
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const DriverPermitScreen()),
          GoRoute(
            path: '/meter/destination',
            builder: (c, _) => Scaffold(
              body: TextButton(onPressed: () => c.pop(_klcc), child: const Text('pick KLCC')),
            ),
          ),
          GoRoute(
            path: '/meter',
            builder: (_, st) {
              launched = st.extra;
              return const Scaffold(body: Text('meter'));
            },
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
            driverPermitProvider.overrideWith((ref) async => permit),
            vehicleAssignmentRepositoryProvider.overrideWithValue(vehicles),
            teksiTodayProvider.overrideWithValue(() => _today),
            teksiPositionProvider.overrideWithValue(() async => const LatLng(3.15, 101.71)),
            geoServiceProvider.overrideWithValue(GeoService(client: MockClient((_) async => http.Response('', 500)))),
            meterCardsProvider.overrideWith((ref) async => const <MeterProfile>[]),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> tap(WidgetTester tester, Finder f) async {
      await tester.ensureVisible(f);
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    testWidgets('a valid permit: tariff, destination, summary, confirm, then the meter running', (tester) async {
      await pump(tester, DriverPermit(expiryDate: DateTime(2027, 1, 1), vehiclePlate: 'WXY 1234'));
      expect(find.text('DRIVER PERMIT'), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('permit-start-pickup')));

      expect(find.text('Select tariff'), findsOneWidget);
      expect(find.text('Choose the fare structure for this pickup.'), findsOneWidget);
      expect(find.text('New Tariff'), findsOneWidget);
      expect(find.text('Old Tariff'), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('tariff-option-new')));

      await tap(tester, find.text('pick KLCC'));
      expect(find.text('Trip summary'), findsOneWidget);
      expect(find.text('8.2 km'), findsOneWidget);
      expect(find.text('18 min'), findsOneWidget);
      expect(find.text('RM 18'), findsOneWidget, reason: 'RM17.60, rounded up as Expo shows it');
      expect(find.text('+ RM1.00 per KM'), findsOneWidget);

      // Edit goes back to the destination.
      await tap(tester, find.byKey(const ValueKey('trip-summary-edit')));
      expect(find.text('pick KLCC'), findsOneWidget);
      await tap(tester, find.text('pick KLCC'));
      await tap(tester, find.byKey(const ValueKey('trip-summary-start')));

      expect(find.text('READY TO ROLL'), findsOneWidget);
      expect(find.text('Confirm your trip'), findsOneWidget);
      expect(find.text('PICKUP'), findsOneWidget);
      expect(find.text('DROP-OFF'), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('confirm-trip-start')));

      expect(find.text('meter'), findsOneWidget);
      final l = launched! as MeterLaunch;
      expect(l.tariff, TeksiTariff.newTariff);
      expect(l.destination!.name, 'KLCC');
      expect(l.startHire, isTrue);
    });

    testWidgets('dismissing the tariff sheet stays on the permit', (tester) async {
      await pump(tester, DriverPermit(expiryDate: DateTime(2027, 1, 1)));
      await tap(tester, find.byKey(const ValueKey('permit-start-pickup')));
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('Select tariff'), findsNothing);
      expect(find.text('DRIVER PERMIT'), findsOneWidget);
    });

    testWidgets('an expired permit stops at its popup', (tester) async {
      await pump(tester, DriverPermit(expiryDate: DateTime(2026, 10, 1)));
      await tap(tester, find.byKey(const ValueKey('permit-start-pickup')));
      expect(find.text('Permit expired'), findsOneWidget);
      expect(find.text('Select tariff'), findsNothing);
    });

    testWidgets('another car: pick again until it matches, then the tariff', (tester) async {
      await pump(tester, const DriverPermit(vehiclePlate: 'WXY 1234'), driving: 'a');
      await tap(tester, find.byKey(const ValueKey('permit-start-pickup')));
      expect(find.text('Vehicle mismatch'), findsOneWidget);
      expect(find.textContaining('Selected vehicle: ABC 9'), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('teksi-select-vehicle')));

      // Still the wrong one: told so, and offered another pick.
      await tap(tester, find.text('ABC 9 · Proton Saga'));
      expect(find.text("Still doesn't match"), findsOneWidget);
      await tap(tester, find.text('Choose another'));
      await tap(tester, find.text('WXY 1234 · Proton Saga'));
      expect(vehicles.claimed, ['w']);
      expect(find.text('Select tariff'), findsOneWidget);
    });

    testWidgets('cancelling the mismatch stays on the permit', (tester) async {
      await pump(tester, const DriverPermit(vehiclePlate: 'WXY 1234'), driving: 'a');
      await tap(tester, find.byKey(const ValueKey('permit-start-pickup')));
      await tap(tester, find.text('Cancel'));
      expect(find.text('Select tariff'), findsNothing);
      expect(vehicles.claimed, isEmpty);
    });
  });
}
