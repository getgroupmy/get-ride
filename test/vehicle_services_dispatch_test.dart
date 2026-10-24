import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_categories.g.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_registry.dart';
import 'package:get_ride/src/admin/admin_repository.dart';
import 'package:get_ride/src/admin/admin_settings_models.dart';
import 'package:get_ride/src/admin/screens/catalogue/services_screens.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// No token refresh: its timer would outlive the test.
final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

class _Admin extends AdminRepository {
  _Admin() : super(_db);
  final saved = <({String? id, Map<String, dynamic> values})>[];

  @override
  Future<List<SettingEntry>> settings(SettingsCategory c) async => switch (c.key) {
    'vehicle-services' => [
      SettingEntry(
        id: 'ride',
        values: {
          'name': 'Ride',
          'costPerKm': 1,
          'costPerMin': 0.2,
          'minFareAmount': 5,
          'displayPriority': 1,
          'status': true,
          'futureKey': 'keep me',
          'searchRadiusMinKm': 2,
          'myRideWindowSec': 90,
        },
      ),
    ],
    'service-settings' => [
      SettingEntry(id: 'car', values: {'name': 'Car', 'displayPriority': 1}),
    ],
    _ => [],
  };

  @override
  Future<void> saveSetting(
    SettingsCategory c, {
    String? id,
    required Map<String, dynamic> values,
    int? position,
  }) async => saved.add((id: id, values: values));
}

void main() {
  Future<_Admin> pump(
    WidgetTester tester, {
    required Brightness brightness,
    required Size size,
    bool edit = true,
  }) async {
    final admin = _Admin();
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          supabaseProvider.overrideWithValue(_db),
          adminAccessProvider.overrideWith((_) async => AdminAccess([AdminGrant(page: '*', edit: edit)])),
          adminRepositoryProvider.overrideWithValue(admin),
        ],
        child: MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: const VehicleServicesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return admin;
  }

  Future<void> openEditor(WidgetTester tester) async {
    await tester.tap(find.text('Ride').first);
    await tester.pumpAndSettle();
    expect(find.text('Edit Vehicle Service'), findsOneWidget);
  }

  Future<void> enter(WidgetTester tester, String key, String text) async {
    final f = find.byKey(ValueKey('vs-$key'));
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.enterText(f, text);
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    final b = find.text('Save changes');
    await tester.ensureVisible(b);
    await tester.pumpAndSettle();
    await tester.tap(b);
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    for (final (label, size) in [('phone', const Size(390, 844)), ('desktop', const Size(1280, 900))]) {
      testWidgets('edits and saves the search radius and My Ride settings ($label, ${brightness.name})', (
        tester,
      ) async {
        final admin = await pump(tester, brightness: brightness, size: size);

        // The row summarises what the dispatch will use, defaults filled in.
        expect(find.byKey(const ValueKey('vs-dispatch-summary-ride')), findsOneWidget);
        expect(find.text('Radius 2–15 km · My Ride: no limit, 90 s'), findsOneWidget);

        await openEditor(tester);
        expect(find.text('Search radius'), findsOneWidget);
        expect(find.text('My Ride'), findsOneWidget);
        // Stored values are filled in; the rest show their default as a hint.
        expect(find.widgetWithText(TextField, '2'), findsWidgets);
        expect(find.text('Default 15'), findsOneWidget);
        expect(find.text('No limit'), findsOneWidget);

        // Max below min is refused on the field and on save.
        await enter(tester, 'searchRadiusMaxKm', '1');
        expect(find.textContaining('must be at least the starting radius'), findsOneWidget);
        await save(tester);
        expect(admin.saved, isEmpty);

        await enter(tester, 'searchRadiusMaxKm', '25');
        await enter(tester, 'searchWidenAfterSec', '45');
        await enter(tester, 'myRideMaxKm', '0');
        // The (hidden) hint plus the suffix: 0 reads as no limit.
        expect(find.text('No limit'), findsNWidgets(2));
        await enter(tester, 'myRideMaxKm', '12');
        await enter(tester, 'myRideWindowSec', '');
        await save(tester);

        final s = admin.saved.single;
        expect(s.id, 'ride');
        expect(s.values['searchRadiusMinKm'], 2);
        expect(s.values['searchRadiusMaxKm'], 25);
        expect(s.values['searchWidenAfterSec'], 45);
        expect(s.values['myRideMaxKm'], 12);
        expect(s.values.containsKey('myRideWindowSec'), isFalse, reason: 'blank: back to the default');
        expect(s.values['futureKey'], 'keep me', reason: 'keys the editor does not own survive a save');
        expect(s.values['name'], 'Ride');
        expect(tester.takeException(), isNull);
        await _drain(tester);
      });
    }
  }

  test('the old Search Radius list is marked replaced, not removed', () {
    expect(replacedCategories['search-radius'], 'Vehicle Services > Search radius');
    // Still a known category, so its rows don't resurface as raw JSON.
    expect(crudCategories.map((c) => c.key), contains('search-radius'));
  });

  testWidgets('read-only admins see the settings but cannot change them', (tester) async {
    final admin = await pump(tester, brightness: Brightness.dark, size: const Size(390, 844), edit: false);
    await openEditor(tester);
    for (final key in [
      'searchRadiusMinKm',
      'searchRadiusMaxKm',
      'searchWidenAfterSec',
      'myRideMaxKm',
      'myRideWindowSec',
    ]) {
      final field = tester.widget<TextField>(find.byKey(ValueKey('vs-$key')));
      expect(field.enabled, isFalse, reason: key);
    }
    await save(tester);
    expect(admin.saved, isEmpty);
    expect(tester.takeException(), isNull);
    await _drain(tester);
  });
}

/// Lets the "Saved" notice's timers run out.
Future<void> _drain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 1));
}
