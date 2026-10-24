import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_repository.dart';
import 'package:get_ride/src/admin/screens/fare_tariffs_screen.dart';
import 'package:get_ride/src/admin/screens/geo/geo_data.dart';
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// No token refresh: its timer would outlive the test.
final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

class _Geo extends GeoAdminRepository {
  _Geo() : super(_db);

  @override
  Future<List<RegionEntry>> regions() async => [
    RegionEntry(id: 'my', values: {'country': 'Malaysia', 'currencyName': 'MYR'}),
    RegionEntry(id: 'sel', values: {'country': 'Malaysia', 'state': 'Selangor'}),
    RegionEntry(id: 'sg', values: {'country': 'Singapore', 'currencyName': 'SGD'}),
  ];

  @override
  Future<List<ServiceOption>> services() async => const [
    ServiceOption(id: 'car', name: 'Car'),
    ServiceOption(id: 'bike', name: 'Bike'),
  ];

  @override
  Future<List<ServiceVehicle>> serviceVehicles() async => const [
    (id: 'ride', name: 'Ride', types: ['Car']),
    (id: 'premium', name: 'Premium', types: ['Car']),
    (id: 'moto', name: 'Moto', types: ['Bike']),
  ];
}

class _Admin extends AdminRepository {
  _Admin({this.many = false}) : super(_db);
  final saved = <Map<String, dynamic>>[];
  final bool many;

  @override
  Future<List<Map<String, dynamic>>> fareTariffs() async => [
    {'id': 't1', 'level': 'master', 'currency': 'MYR', 'base_fare': 4, 'per_km': 1},
    if (many)
      for (var i = 2; i < 10; i++) {'id': 't$i', 'level': 'country', 'country': 'Malaysia', 'currency': 'MYR', 'base_fare': i, 'per_km': 1},
  ];

  @override
  Future<void> saveFareTariff(Map<String, dynamic> row) async => saved.add(row);
}

void main() {
  Future<_Admin> pump(WidgetTester tester, Brightness brightness) async {
    final admin = _Admin();
    await tester.binding.setSurfaceSize(const Size(1000, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          supabaseProvider.overrideWithValue(_db),
          adminAccessProvider.overrideWith((_) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
          geoAdminRepositoryProvider.overrideWithValue(_Geo()),
          adminRepositoryProvider.overrideWithValue(admin),
        ],
        child: MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: const AdminFareTariffsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return admin;
  }

  Future<void> choose(WidgetTester tester, Finder dropdown, String item) async {
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text(item).last);
    await tester.pumpAndSettle();
  }

  // Web round 40 (180): from 600 wide Add tariff is in the app bar (it sat
  // over the filters and the first card's Edit fare at 915 x 412); on a
  // phone it floats, and the last card scrolls clear of it.
  for (final dark in [false, true]) {
    for (final (size, scale) in const [
      (Size(1280, 768), 1.0),
      (Size(915, 412), 1.0),
      (Size(915, 412), 1.3),
      (Size(360, 640), 1.0),
      (Size(360, 640), 1.3),
    ]) {
      testWidgets('Add tariff at ${size.width.toInt()}x${size.height.toInt()} @$scale (${dark ? 'dark' : 'light'})',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              supabaseProvider.overrideWithValue(_db),
              adminAccessProvider.overrideWith((_) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
              geoAdminRepositoryProvider.overrideWithValue(_Geo()),
              adminRepositoryProvider.overrideWithValue(_Admin(many: true)),
            ],
            child: MaterialApp(
              theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
              builder: (c, child) => MediaQuery(
                data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: const AdminFareTariffsScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final add = find.text('Add tariff');
        expect(add, findsOneWidget);
        if (size.width >= 600) {
          expect(find.byType(FloatingActionButton), findsNothing, reason: 'nothing floats over the cards');
          expect(find.descendant(of: find.byType(AppBar), matching: add), findsOneWidget);
          // Nothing over the first card's buttons.
          final first = find.descendant(of: find.byType(ListView), matching: find.byType(Card)).at(1);
          expect(tester.getRect(add).overlaps(tester.getRect(first)), isFalse);
        } else {
          final scroll = tester.state<ScrollableState>(
            find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable)).first,
          );
          // A lazy list learns its full length as it scrolls: to the end until
          // the end stays put.
          for (var i = 0; i < 5; i++) {
            scroll.position.jumpTo(scroll.position.maxScrollExtent);
            await tester.pumpAndSettle();
          }
          final fab = tester.getRect(find.byType(FloatingActionButton));
          final cards = find.descendant(of: find.byType(ListView), matching: find.byType(Card));
          expect(tester.getRect(cards.last).bottom, lessThanOrEqualTo(fab.top - 8), reason: 'the last card clear of the button');
        }
        expect(tester.takeException(), isNull);
        // Let the live tables' disconnect timer run out.
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(minutes: 1));
      });
    }
  }

  for (final brightness in Brightness.values) {
    testWidgets('"How a booking is priced" is one folded row that opens; no arrow glyph (${brightness.name})',
        (tester) async {
      await pump(tester, brightness);
      final how = find.byKey(const ValueKey('fare-tariffs-how'));
      expect(how, findsOneWidget);
      expect(find.text('How a booking is priced'), findsOneWidget);
      expect(find.byKey(const ValueKey('fare-tariffs-how-text')), findsNothing, reason: 'folded at first');
      await tester.tap(find.text('How a booking is priced'));
      await tester.pumpAndSettle();
      final text = tester.widget<Text>(find.byKey(const ValueKey('fare-tariffs-how-text')));
      expect(text.data, contains('suburb > city > state > country > everywhere'));
      expect(text.data, isNot(contains('→')));
      expect(tester.takeException(), isNull);
      // Let the live tables' disconnect timer run out.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));
    });

    testWidgets('pick a place and Car, then set Premium\'s own fare (${brightness.name})', (tester) async {
      final admin = await pump(tester, brightness);

      // Every service, everywhere: the master card prices it.
      expect(find.byKey(const ValueKey('tariff-row-all')), findsOneWidget);
      expect(find.byKey(const ValueKey('tariff-row-moto')), findsOneWidget);

      // Car lists only Car's vehicle services.
      await choose(tester, find.byKey(const ValueKey('tariff-filter-type')), 'Car');
      expect(find.byKey(const ValueKey('tariff-row-ride')), findsOneWidget);
      expect(find.byKey(const ValueKey('tariff-row-premium')), findsOneWidget);
      expect(find.byKey(const ValueKey('tariff-row-moto')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('tariff-row-premium')),
          matching: find.textContaining('From Everywhere'),
        ),
        findsOneWidget,
      );

      // The countries come from Country / States / Cities.
      await choose(tester, find.byKey(const ValueKey('tariff-filter-country-')), 'Malaysia');
      expect(find.text('Car · Malaysia'), findsOneWidget);
      // ...and the states under the one picked.
      await tester.tap(find.byKey(const ValueKey('tariff-filter-state-Malaysia-')));
      await tester.pumpAndSettle();
      expect(find.text('Selangor').last, findsOneWidget);
      expect(find.text('Singapore'), findsNothing);
      await tester.tap(find.text('All of Malaysia').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('tariff-row-premium-set')));
      await tester.pumpAndSettle();
      expect(find.text('Add fare tariff'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('tariff-base')), '10');
      await tester.enterText(find.byKey(const ValueKey('tariff-km')), '3');
      await tester.tap(find.byKey(const ValueKey('tariff-save')));
      await tester.pumpAndSettle();

      final row = admin.saved.single;
      expect(row['level'], 'country');
      expect(row['country'], 'Malaysia');
      expect(row['service_type'], 'car');
      expect(row['vehicle_service'], 'premium');
      expect(row['currency'], 'MYR');
      expect(row['base_fare'], 10);
      expect(row['per_km'], 3);
      await _drain(tester);
    });
  }

  testWidgets('a new card picks its place from the region lists and takes the country\'s currency', (tester) async {
    final admin = await pump(tester, Brightness.light);
    await tester.tap(find.text('Add tariff'));
    await tester.pumpAndSettle();
    await choose(tester, find.byKey(const ValueKey('tariff-country-')), 'Singapore');
    expect(find.widgetWithText(TextField, 'SGD'), findsOneWidget);
    await choose(tester, find.byKey(const ValueKey('tariff-service-type')), 'Bike');
    await choose(tester, find.byKey(const ValueKey('tariff-vehicle-bike')), 'Moto');
    await tester.tap(find.byKey(const ValueKey('tariff-vehicle-bike')));
    await tester.pumpAndSettle();
    expect(find.text('Ride'), findsOneWidget, reason: 'only on the page behind: the menu offers Bike vehicles');
    await tester.tap(find.text('Moto').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('tariff-km')), '0.8');
    await tester.tap(find.byKey(const ValueKey('tariff-save')));
    await tester.pumpAndSettle();
    final row = admin.saved.single;
    expect(row['country'], 'Singapore');
    expect(row['currency'], 'SGD');
    expect(row['service_type'], 'bike');
    expect(row['vehicle_service'], 'moto');
    await _drain(tester);
  });

  testWidgets('a card with no country says so on the Country field, not in a line below', (tester) async {
    final admin = await pump(tester, Brightness.light);
    await tester.tap(find.text('Add tariff'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('tariff-km')), '0.8');
    await tester.tap(find.byKey(const ValueKey('tariff-save')));
    await tester.pumpAndSettle();
    expect(admin.saved, isEmpty);
    expect(find.text('Enter the country'), findsOneWidget, reason: 'under the field');
    expect(find.byKey(const ValueKey('tariff-error')), findsNothing, reason: 'no detached line');
    await tester.tap(find.text('Cancel'));
    await _drain(tester);
  });
}

/// Lets the "Tariff saved" notice's timers run out.
Future<void> _drain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 1));
}
