// Admin > Services & catalogue > Driver service locks (0263): the page in
// light and dark, wide and on a phone: who the locks apply to, a row per
// service with Driver decides / Keep on / Keep off and how many drivers have
// it off, Until, Save, the current locks (filter, edit, remove) and who
// changed what. Read-only without the edit grant.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/admin_registry.dart';
import 'package:get_ride/src/admin/screens/catalogue/driver_service_locks_screen.dart';
import 'package:get_ride/src/admin/screens/catalogue/partner_type_services_screen.dart'
    show partnerTypeNamesForServicesProvider, partnerTypeServicesPath;
import 'package:get_ride/src/admin/screens/geo/geo_data.dart' show regionVehicleTypesProvider, regionsProvider;
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart' show RegionEntry, ServiceOption;
import 'package:get_ride/src/admin/screens/sub_admins_screen.dart' show grantablePages;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/driver_services.dart';
import 'package:get_ride/src/core/ride_assistance.dart';
import 'package:get_ride/src/core/ride_option_settings.dart';
import 'package:get_ride/src/core/ride_pets.dart';
import 'package:get_ride/src/data/driver_services_repository.dart';
import 'package:get_ride/src/data/live_tables.dart';
import 'package:get_ride/src/data/ride_option_providers.dart';
import 'package:get_ride/src/data/ride_pet_repository.dart' show petConfigProvider;
import 'package:supabase_flutter/supabase_flutter.dart';

class _QuietLive extends LiveTables {
  @override
  Map<String, int> build() => const {};
}

class _QuietAdminLive extends AdminLiveTables {
  @override
  Map<String, int> build() => const {};
}

class _FakeRepo extends DriverServicesRepository {
  _FakeRepo() : super(SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false)));
  final saves = <({List<LockTarget> targets, Map<String, String> rules, DateTime? until, String? note})>[];
  final removed = <String>[];

  @override
  Future<int> saveLocks(List<LockTarget> targets, Map<String, String> rules, {DateTime? until, String? note}) async {
    saves.add((targets: targets, rules: rules, until: until, note: note));
    return rules.length;
  }

  @override
  Future<void> removeLocks(Iterable<String> ids) async => removed.addAll(ids);
}

final _locks = [
  LockRule(
    id: 'l1',
    scope: LockScope.driver,
    driverId: 'd1',
    serviceKey: 'ride',
    on: false,
    createdBy: 'a1',
    updatedBy: 'a1',
    updatedAt: DateTime.utc(2026, 10, 21, 3),
    note: 'Late cancels',
  ),
  LockRule(
    id: 'l2',
    scope: LockScope.region,
    country: 'Malaysia',
    state: 'Selangor',
    serviceKey: 'hail:destination',
    on: true,
    until: DateTime.utc(2099, 1, 1),
    updatedBy: 'a1',
    updatedAt: DateTime.utc(2026, 10, 20, 3),
  ),
];

final _events = [
  LockEvent(
    action: 'added',
    scope: LockScope.driver,
    target: const LockTarget(scope: LockScope.driver, driverId: 'd1'),
    serviceKey: 'ride',
    on: false,
    actorId: 'a1',
    at: DateTime.utc(2026, 10, 21, 3),
  ),
];

Future<_FakeRepo> _pump(WidgetTester tester, Brightness b, {Size size = const Size(1300, 2600), bool canEdit = true}) async {
  final repo = _FakeRepo();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        liveTablesProvider.overrideWith(_QuietLive.new),
        adminLiveTablesProvider.overrideWith(_QuietAdminLive.new),
        pageAccessProvider.overrideWith((ref, page) => canEdit ? AccessLevel.edit : AccessLevel.read),
        driverServicesRepositoryProvider.overrideWithValue(repo),
        driverServiceLocksProvider.overrideWith((ref) async => _locks),
        driverServiceOffCountsProvider.overrideWith((ref) async => {'ride': 3, 'hail:meter': 1}),
        driverServiceLockEventsProvider.overrideWith((ref) async => _events),
        lockFleetsProvider.overrideWith((ref) async => [(id: 'f1', name: 'KL Airport Cabs')]),
        lockPeopleProvider.overrideWith((ref, ids) async => {'d1': 'Aisyah', 'd2': 'Ben', 'a1': 'Admin One'}),
        lockPeopleSearchProvider.overrideWithValue((q) async => [
              {'id': 'd1', 'name': 'Aisyah', 'phone': '+60100000001'},
              {'id': 'd2', 'name': 'Ben', 'phone': '+60100000002'},
            ]),
        partnerTypeNamesForServicesProvider.overrideWith((ref) async => ['eHailing', 'Teksi']),
        regionVehicleTypesProvider.overrideWith((ref) async => const [
              ServiceOption(id: 'r', name: 'Ride'),
              ServiceOption(id: 'c', name: 'Comfort'),
            ]),
        regionsProvider.overrideWith((ref) async => [
              RegionEntry(id: 'my', values: {'country': 'Malaysia'}),
              RegionEntry(id: 'sel', values: {'country': 'Malaysia', 'state': 'Selangor'}),
            ]),
        rideOptionsConfigProvider.overrideWithValue(RideOptionsConfig.fromSettings(const {})),
        petConfigProvider.overrideWithValue(PetConfig.fromSettings(const {})),
        assistanceCatalogueProvider.overrideWithValue(AssistanceCatalogue.fromSettings(const {})),
      ],
      child: MaterialApp(theme: appTheme(b), home: const DriverServiceLocksScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

SegmentedButton<LockChoice> _seg(WidgetTester tester, String key) =>
    tester.widget<SegmentedButton<LockChoice>>(find.byKey(ValueKey('dsl-seg-$key')));

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  test('listed under Services & catalogue after Partner type services, grantable, followed live', () {
    final i = allAdminEntries.indexWhere((e) => e.path == partnerTypeServicesPath);
    final e = allAdminEntries[i + 1];
    expect(e.path, driverServiceLocksPath);
    expect(e.title, 'Driver service locks');
    expect(e.section, 'Services & catalogue');
    expect(e.pages, [driverServiceLocksPage]);
    expect(grantablePages, contains(driverServiceLocksPage));
    expect(liveSettingTables, contains('driver_service_locks'));
    expect(liveAdminTables, containsAll(['driver_service_prefs', 'driver_service_lock_events']));
  });

  for (final b in Brightness.values) {
    testWidgets('the form, the locks and the log (${b.name}, wide)', (tester) async {
      final repo = await _pump(tester, b);
      expect(tester.takeException(), isNull);

      for (final w in ['One driver', 'Several drivers', 'Partner type', 'Fleet', 'Region', 'Everyone']) {
        expect(find.descendant(of: find.byKey(const ValueKey('dsl-form')), matching: find.text(w)), findsOneWidget, reason: w);
      }
      // A row per service, street hail and add-on, with the off counts; never the guide dog.
      expect(find.byKey(const ValueKey('dsl-rule-ride')), findsOneWidget);
      expect(find.byKey(const ValueKey('dsl-rule-hail:meter')), findsOneWidget);
      expect(find.byKey(const ValueKey('dsl-rule-extra:child-seat')), findsOneWidget);
      expect(find.byKey(const ValueKey('dsl-rule-extra:assist:guide-dog')), findsNothing);
      expect(find.text('Services · 3 drivers have it off'), findsOneWidget);
      expect(find.text('Street hail · 1 driver has it off'), findsOneWidget);

      // The current locks and the log.
      expect(find.byKey(const ValueKey('dsl-group-driver|d1|||||')), findsOneWidget);
      expect(find.text('Ride: Kept off'), findsOneWidget);
      expect(find.textContaining('Street hail with destination: Kept on until'), findsOneWidget);
      expect(find.text('Selangor, Malaysia'), findsOneWidget);
      expect(find.textContaining('Set by Admin One'), findsWidgets);
      expect(find.text('Admin One kept Ride off for Aisyah'), findsOneWidget);

      // Filter: regions only.
      await _tap(tester, find.byKey(const ValueKey('dsl-filter-region')));
      expect(find.byKey(const ValueKey('dsl-group-driver|d1|||||')), findsNothing);
      expect(find.text('Selangor, Malaysia'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('dsl-filter-all')));

      // Edit loads the target and its saved choices.
      await _tap(tester, find.byKey(const ValueKey('dsl-edit-driver|d1|||||')));
      expect(find.text('Aisyah'), findsWidgets);
      expect(_seg(tester, 'ride').selected, {LockChoice.off});
      expect(_seg(tester, 'comfort').selected, {LockChoice.driver});

      // Keep the meter on as well, and save.
      await _tap(tester, find.byKey(const ValueKey('dsl-on-hail:meter')));
      await _tap(tester, find.byKey(const ValueKey('dsl-save')));
      expect(repo.saves.length, 1);
      expect(repo.saves.single.targets, [const LockTarget(scope: LockScope.driver, driverId: 'd1')]);
      expect(repo.saves.single.rules['ride'], 'off');
      expect(repo.saves.single.rules['hail:meter'], 'on');
      expect(repo.saves.single.rules['comfort'], 'driver');
      expect(repo.saves.single.note, 'Late cancels');
      expect(find.text('Locks saved. Drivers see them straight away.'), findsOneWidget);

      // Remove asks first.
      await _tap(tester, find.byKey(const ValueKey('dsl-remove-driver|d1|||||')));
      expect(find.text('Remove these locks?'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('dsl-remove-yes')));
      expect(repo.removed, ['l1']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('several drivers, everyone, until (${b.name}, phone)', (tester) async {
      final repo = await _pump(tester, b, size: const Size(380, 3600));
      expect(tester.takeException(), isNull);

      // Several drivers from a search.
      await _tap(tester, find.byKey(const ValueKey('dsl-who-several')));
      await _tap(tester, find.byKey(const ValueKey('dsl-add-drivers')));
      await tester.enterText(find.byKey(const ValueKey('dsl-driver-search')), 'a');
      await _tap(tester, find.byKey(const ValueKey('dsl-driver-find')));
      expect(find.text('Type at least two characters.'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('dsl-driver-search')), 'ai');
      await _tap(tester, find.byKey(const ValueKey('dsl-driver-find')));
      await _tap(tester, find.byKey(const ValueKey('dsl-driver-d1')));
      await _tap(tester, find.byKey(const ValueKey('dsl-driver-d2')));
      await _tap(tester, find.byKey(const ValueKey('dsl-driver-done')));
      expect(find.text('2 drivers selected. Add more'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('dsl-off-comfort')));
      await _tap(tester, find.byKey(const ValueKey('dsl-save')));
      expect(repo.saves.last.targets.map((t) => t.driverId), ['d1', 'd2']);
      expect(repo.saves.last.rules['comfort'], 'off');

      // Everyone, until a date typed in the boxes.
      await _tap(tester, find.byKey(const ValueKey('dsl-who-everyone')));
      expect(find.text('All drivers'), findsOneWidget);
      Finder box(String part) =>
          find.descendant(of: find.byKey(const ValueKey('dsl-until')), matching: find.byKey(ValueKey('date-box-$part')));
      await tester.enterText(box('day'), '15');
      await tester.enterText(box('month'), '01');
      await tester.enterText(box('year'), '2099');
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const ValueKey('dsl-on-ride')));
      await _tap(tester, find.byKey(const ValueKey('dsl-save')));
      expect(repo.saves.last.targets, [const LockTarget.everyone()]);
      expect(repo.saves.last.rules['ride'], 'on');
      expect(repo.saves.last.until, DateTime(2099, 1, 15, 23, 59, 59));
      expect(tester.takeException(), isNull);
    });

    testWidgets('read-only without the edit grant (${b.name})', (tester) async {
      await _pump(tester, b, size: const Size(390, 2600), canEdit: false);
      expect(find.byKey(const ValueKey('dsl-save')), findsNothing);
      expect(find.byKey(const ValueKey('dsl-edit-driver|d1|||||')), findsNothing);
      expect(_seg(tester, 'ride').onSelectionChanged, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a region from the list', (tester) async {
    final repo = await _pump(tester, Brightness.light);
    await _tap(tester, find.byKey(const ValueKey('dsl-who-region')));
    await _tap(tester, find.byKey(const ValueKey('dsl-pick-region')));
    final picker = find.byWidgetPredicate((w) => w.runtimeType.toString().startsWith('_SearchDialog'));
    await _tap(tester, find.descendant(of: picker, matching: find.text('Selangor, Malaysia')));
    // The saved lock for Selangor fills the form.
    expect(_seg(tester, 'hail:destination').selected, {LockChoice.on});
    await _tap(tester, find.byKey(const ValueKey('dsl-save')));
    expect(repo.saves.last.targets, [const LockTarget(scope: LockScope.region, country: 'Malaysia', state: 'Selangor')]);
    expect(repo.saves.last.rules['hail:destination'], 'on');
    final d = DateTime.utc(2099, 1, 1).toLocal();
    expect(repo.saves.last.until, DateTime(d.year, d.month, d.day, 23, 59, 59), reason: 'the saved end date');
  });
}
