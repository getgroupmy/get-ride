// The driver's Services page (0263) on a phone, light and dark: the car
// card, the tabs, a switch saved for this car with its toast, a greyed-out
// service with its reason, a padlock row that says who set it, the street
// hail and add-on rows (the guide dog always on), and no car in use.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/driver_services.dart';
import 'package:get_ride/src/core/ride_assistance.dart';
import 'package:get_ride/src/core/ride_option_settings.dart';
import 'package:get_ride/src/core/ride_pets.dart';
import 'package:get_ride/src/data/driver_extras_repository.dart';
import 'package:get_ride/src/data/driver_services_repository.dart';
import 'package:get_ride/src/data/live_tables.dart';
import 'package:get_ride/src/data/ride_option_providers.dart';
import 'package:get_ride/src/data/ride_pet_repository.dart' show petConfigProvider;
import 'package:get_ride/src/features/partner/driver_services_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _QuietLive extends LiveTables {
  @override
  Map<String, int> build() => const {};
}

class _FakeRepo extends DriverServicesRepository {
  _FakeRepo() : super(SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false)));
  final saved = <String>[];

  @override
  Future<void> setSwitch(String vehicleId, String key, bool on) async => saved.add('$vehicleId $key $on');
}

class _FakeExtras extends DriverExtrasRepository {
  _FakeExtras() : super(SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false)));
  Set<String>? set;

  @override
  Future<void> setMine(Set<String> off) async => set = off;
}

final _overview = DriverServicesOverview(
  car: const DriverCar(
    id: 'v1',
    plate: 'WXY 1234',
    make: 'Perodua',
    model: 'Bezza',
    color: 'Silver',
    vehicleType: 'Sedan',
    energy: 'Petrol',
    serviceId: 'r',
  ),
  types: const ['eHailing'],
  orderEnforced: true,
  services: const [
    ServiceFacts(id: 'r', name: 'Ride', typeNames: ['Car'], maxPax: 4, description: 'Ride · Ride (Saver)'),
    ServiceFacts(id: 'c', name: 'Comfort', typeNames: ['Car'], maxPax: 4, lock: ServiceLock(on: false), on: false),
    ServiceFacts(id: 's', name: '6-seater', typeNames: ['Car'], maxPax: 6, orderOk: false),
    ServiceFacts(id: 't', name: 'Teksi', typeNames: ['Car'], partnerOk: false),
    ServiceFacts(id: 'd', name: 'Delivery', typeNames: ['Delivery']),
  ],
  keys: const {
    DriverServiceKey.hailDestination: KeyState(lock: ServiceLock(on: true), on: true),
  },
);

Future<(_FakeRepo, _FakeExtras)> _pump(
  WidgetTester tester,
  Brightness b, {
  DriverServicesOverview? overview,
  Size size = const Size(360, 2400),
}) async {
  final repo = _FakeRepo();
  final extras = _FakeExtras();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        liveTablesProvider.overrideWith(_QuietLive.new),
        myDriverServicesProvider.overrideWith((ref) async => overview ?? _overview),
        driverServicesRepositoryProvider.overrideWithValue(repo),
        driverExtrasRepositoryProvider.overrideWithValue(extras),
        driverServicesRegionOffProvider.overrideWith((ref) async => const <String>{}),
        myExtrasOffProvider.overrideWith((ref) async => {'pet:cat'}),
        rideOptionsConfigProvider.overrideWithValue(RideOptionsConfig.fromSettings(const {})),
        petConfigProvider.overrideWithValue(PetConfig.fromSettings(const {})),
        assistanceCatalogueProvider.overrideWithValue(AssistanceCatalogue.fromSettings(const {})),
      ],
      child: MaterialApp(theme: appTheme(b), home: const DriverServicesScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return (repo, extras);
}

Switch _switch(WidgetTester tester, String key) =>
    tester.widget<Switch>(find.byKey(ValueKey('driver-service-switch-$key')));

void main() {
  for (final b in Brightness.values) {
    testWidgets('a phone, ${b.name}: the car, the tabs and the rows', (tester) async {
      await _pump(tester, b);
      expect(tester.takeException(), isNull);
      expect(find.text('Services'), findsOneWidget);
      expect(find.textContaining('beta', findRichText: true), findsNothing);
      expect(find.text('WXY 1234'), findsOneWidget);
      expect(find.text('Perodua Bezza · Silver'), findsOneWidget);
      expect(find.text('eHailing · Sedan · Petrol'), findsOneWidget);
      expect(find.text('Change car'), findsOneWidget);
      expect(find.text('Transport'), findsOneWidget);
      expect(find.text('Deliveries'), findsOneWidget);

      // Greyed out with the reason, switch off and disabled.
      expect(find.byKey(const ValueKey('driver-service-reason-6seater')), findsOneWidget);
      expect(find.text('This car has 4 seats'), findsOneWidget);
      expect(find.text('Not in your partner type'), findsOneWidget);
      expect(_switch(tester, '6seater').value, isFalse);
      expect(_switch(tester, '6seater').onChanged, isNull);

      // Kept off by get.ride: padlock, disabled.
      expect(find.text('Kept off by get.ride'), findsOneWidget);
      expect(_switch(tester, 'comfort').onChanged, isNull);
      // Street hail with destination kept on.
      expect(find.text('Kept on by get.ride'), findsOneWidget);
      expect(_switch(tester, 'hail:destination').value, isTrue);
      expect(_switch(tester, 'hail:meter').onChanged, isNotNull);

      // Add-ons: the guide dog always on.
      expect(find.text('Add-ons'), findsOneWidget);
      expect(find.text('Always on: required by law'), findsOneWidget);
      expect(_switch(tester, 'extra:assist:guide-dog').value, isTrue);
      expect(_switch(tester, 'extra:assist:guide-dog').onChanged, isNull);

      // Nothing runs off the side of a phone.
      final page = tester.getRect(find.byKey(const ValueKey('driver-services')));
      for (final e in find.byType(Switch).evaluate()) {
        final r = tester.getRect(find.byWidget(e.widget));
        expect(r.right, lessThanOrEqualTo(page.right));
      }
    });
  }

  testWidgets('a switch is saved for this car, with its toast', (tester) async {
    final (repo, _) = await _pump(tester, Brightness.light);
    await tester.tap(find.byKey(const ValueKey('driver-service-switch-ride')));
    await tester.pump();
    expect(repo.saved, ['v1 ride false']);
    expect(find.text("Ride off. You won't get these requests."), findsOneWidget);
    expect(_switch(tester, 'ride').value, isFalse);
  });

  testWidgets("an add-on goes to the driver's add-on list", (tester) async {
    final (repo, extras) = await _pump(tester, Brightness.dark);
    final dog = find.byKey(const ValueKey('driver-service-switch-extra:pet:dog'));
    await tester.ensureVisible(dog);
    await tester.tap(dog);
    await tester.pump();
    expect(extras.set, {'pet:cat', 'pet:dog'});
    expect(repo.saved, isEmpty);
    expect(find.textContaining('off. You won'), findsOneWidget);
  });

  testWidgets('a padlock row says who set it', (tester) async {
    await _pump(tester, Brightness.light);
    await tester.tap(find.byKey(const ValueKey('driver-service-row-comfort')));
    await tester.pump();
    expect(find.text('Set by get.ride. Contact support to change it.'), findsOneWidget);
  });

  testWidgets('Deliveries shows the delivery services only', (tester) async {
    await _pump(tester, Brightness.dark);
    await tester.tap(find.text('Deliveries'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('driver-service-switch-delivery')), findsOneWidget);
    expect(find.byKey(const ValueKey('driver-service-switch-ride')), findsNothing);
    expect(find.text('Street hail'), findsNothing);
  });

  testWidgets('no car in use: choose one first', (tester) async {
    await _pump(tester, Brightness.light, overview: const DriverServicesOverview());
    expect(find.text('Choose the car you are driving'), findsOneWidget);
    expect(find.byKey(const ValueKey('driver-services-pick-car')), findsOneWidget);
  });
}
