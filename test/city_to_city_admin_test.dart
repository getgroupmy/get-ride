// Admin → City to City (migration 0306): the settings page, the route rules
// and fares page with its editor, and Commission → Per service, in light and
// dark, wide and on a phone, read-only without the edit grant.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/admin_registry.dart';
import 'package:get_ride/src/admin/screens/city_to_city/city_to_city_routes_screen.dart';
import 'package:get_ride/src/admin/screens/city_to_city/city_to_city_settings_screen.dart';
import 'package:get_ride/src/admin/screens/commission_screen.dart' show commissionRatesProvider;
import 'package:get_ride/src/admin/screens/commission_service_tab.dart';
import 'package:get_ride/src/admin/screens/geo/geo_data.dart' show regionVehicleTypesProvider, regionsProvider;
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart' show RegionEntry, ServiceOption;
import 'package:get_ride/src/admin/screens/sub_admins_screen.dart' show grantablePages;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/city_to_city.dart';
import 'package:get_ride/src/core/fare.dart' show ServiceRates;
import 'package:get_ride/src/core/fare_tariff.dart';
import 'package:get_ride/src/data/city_to_city_repository.dart';
import 'package:get_ride/src/data/live_tables.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'notice.dart';
import 'quiet_live.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

const _my = 'Malaysia';
final _kl = const C2cPlace(level: 'city', country: _my, state: 'Kuala Lumpur', city: 'Kuala Lumpur');

class _Repo extends CityToCityRepository {
  _Repo() : super(_db);

  C2cSettings stored = const C2cSettings();
  final savedSettings = <C2cSettings>[];
  final savedRules = <C2cRule>[];
  final deleted = <String>[];
  final active = <(String, bool)>[];
  final added = <(String, String)>[];
  final removed = <String>[];
  final rates = <(String, double?)>[];
  List<C2cRule> list = [
    C2cRule(
      id: 'r1',
      from: [_kl, const C2cPlace(level: 'state', country: _my, state: 'Selangor')],
      to: [const C2cPlace(level: 'state', country: _my, state: 'Perak')],
      addOnAmount: 20,
      rangeMode: C2cRangeMode.set,
      rangeLow: 130,
      rangeHigh: 150,
      position: 1,
    ),
    C2cRule(
      id: 'r2',
      from: [_kl],
      to: [const C2cPlace(level: 'state', country: _my, state: 'Penang')],
      fareMode: C2cFareMode.fixed,
      fixedFare: 190,
      rangeMode: C2cRangeMode.set,
      rangeLow: 180,
      rangeHigh: 210,
      bookAheadDays: 30,
      yearsMode: C2cYearsMode.off,
      active: false,
      position: 2,
    ),
  ];

  @override
  Future<C2cSettings> settings() async => stored;
  @override
  Future<void> saveSettings(C2cSettings s) async => savedSettings.add(stored = s);
  @override
  Future<List<C2cRule>> rules() async => list;
  @override
  Future<void> saveRule(C2cRule r) async => savedRules.add(r);
  @override
  Future<void> setRuleActive(String id, bool on) async => active.add((id, on));
  @override
  Future<void> deleteRule(String id) async => deleted.add(id);
  @override
  Future<List<C2cCountryPermit>> countryPermits() async => const [
    C2cCountryPermit(id: 'cp1', country: _my, permitTypeId: 'psv', name: 'PSV licence', position: 1),
  ];
  @override
  Future<void> addCountryPermit(String country, String permitTypeId, {int position = 0}) async =>
      added.add((country, permitTypeId));
  @override
  Future<void> removeCountryPermit(String id) async => removed.add(id);
  @override
  Future<List<C2cPermitType>> permitTypes() async => const [
    (id: 'psv', name: 'PSV licence', country: _my, appliesTo: 'driver'),
    (id: 'evp', name: 'EVP', country: _my, appliesTo: 'vehicle'),
  ];
  @override
  Future<Map<String, double>> serviceRates() async => const {'prem': 0.18};
  @override
  Future<void> setServiceRate(String id, String name, double? rate) async => rates.add((id, rate));
  @override
  Future<List<FareTariff>> fareCards() async => [
    FareTariff.fromRow({
      'level': 'city', 'country': _my, 'state': 'Kuala Lumpur', 'city': 'Kuala Lumpur',
      'base_fare': 3, 'per_km': 0.4, 'per_minute': 0.2, 'vehicle_service': 'c2c',
    }),
  ];
  @override
  Future<C2cService> service() async =>
      (id: 'c2c', types: const <String>{}, rates: const ServiceRates(perKm: 0.45, perMinute: 0.15), active: false);
}

final _regions = [
  RegionEntry(id: 'my', values: {'country': _my}),
  RegionEntry(id: 'kl', values: {'country': _my, 'state': 'Kuala Lumpur'}),
  RegionEntry(id: 'klc', values: {'country': _my, 'state': 'Kuala Lumpur', 'city': 'Kuala Lumpur'}),
  RegionEntry(id: 'sel', values: {'country': _my, 'state': 'Selangor'}),
  RegionEntry(id: 'pk', values: {'country': _my, 'state': 'Perak'}),
  RegionEntry(id: 'ipoh', values: {'country': _my, 'state': 'Perak', 'city': 'Ipoh'}),
  RegionEntry(id: 'sg', values: {'country': 'Singapore'}),
];

Future<_Repo> _pump(
  WidgetTester tester,
  Widget home, {
  Brightness b = Brightness.light,
  Size size = const Size(1300, 2400),
  bool canEdit = true,
}) async {
  final repo = _Repo();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        ...quietLiveOverrides,
        pageAccessProvider.overrideWith((ref, page) => canEdit ? AccessLevel.edit : AccessLevel.read),
        cityToCityRepositoryProvider.overrideWithValue(repo),
        regionsProvider.overrideWith((ref) async => _regions),
        regionVehicleTypesProvider.overrideWith((ref) async => const [
          ServiceOption(id: 'ride', name: 'Ride'),
          ServiceOption(id: 'prem', name: 'Premium'),
          ServiceOption(id: 'c2c', name: 'City to City'),
        ]),
        commissionRatesProvider.overrideWith((ref) async => [
          {'id': 'm', 'level': 'master', 'rate': 0.2, 'active': true},
          {'id': 's', 'level': 'state', 'country': _my, 'state': 'Selangor', 'rate': 0.15, 'active': true},
          {'id': 'u', 'level': 'user', 'user_id': 'x', 'rate': 0.05, 'active': true},
        ]),
      ],
      child: MaterialApp(theme: appTheme(b), home: home),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await closeAnyNotice(tester);
  await tester.ensureVisible(f.first);
  await tester.pumpAndSettle();
  await tester.tap(f.first);
  await tester.pumpAndSettle();
}

void main() {
  test('listed under Services & catalogue, grantable, followed live', () {
    final settings = allAdminEntries.firstWhere((e) => e.path == cityToCityPath);
    final routes = allAdminEntries.firstWhere((e) => e.path == cityToCityRoutesPath);
    expect(cityToCityPath, '/admin/m/city-to-city');
    expect(cityToCityRoutesPath, '/admin/m/city-to-city-routes');
    expect([settings.section, routes.section], ['Services & catalogue', 'Services & catalogue']);
    expect(settings.pages, [c2cPage]);
    expect(routes.pages, [c2cPage]);
    expect(grantablePages, contains(c2cPage));
    expect(liveSettingTables,
        containsAll(['city_to_city_settings', 'c2c_country_permits', 'c2c_route_rules', 'commission_service_rates']));
  });

  for (final b in Brightness.values) {
    testWidgets('settings: cancel fee, payment, years, permits, where offered (${b.name})', (tester) async {
      final repo = await _pump(tester, const CityToCitySettingsScreen(), b: b);
      expect(find.text('Cancelling'), findsOneWidget);
      expect(find.byKey(const ValueKey('c2c-fee')), findsOneWidget);
      expect(find.textContaining('Free to cancel until 24 hours before, then RM 20.'), findsOneWidget);
      expect(find.byKey(const ValueKey('c2c-service-off')), findsOneWidget, reason: 'the service is off');
      expect(find.text('PSV licence (driver)'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('c2c-settings-save'))).onPressed, isNull,
          reason: 'nothing changed yet');

      await _tap(tester, find.byTooltip('Raise Fee'));
      await _tap(tester, find.byTooltip('Lower Free until'));
      expect(find.textContaining('Free to cancel until 18 hours before, then RM 25.'), findsOneWidget);

      await _tap(tester, find.byKey(const ValueKey('c2c-pay-app')));
      await _tap(tester, find.byKey(const ValueKey('c2c-pay-cash')));
      expect(find.text('Keep at least one method on.'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('c2c-settings-save'))).onPressed, isNull);
      await _tap(tester, find.byKey(const ValueKey('c2c-pay-cash')));

      await _tap(tester, find.byTooltip('Raise Minimum years driving'));
      expect(find.text('4 years'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-settings-save')));
      expect(repo.savedSettings.single.cancelFeeAmount, 25);
      expect(repo.savedSettings.single.cancelFreeHours, 18);
      expect([repo.savedSettings.single.payInApp, repo.savedSettings.single.payCash], [false, true]);
      expect(repo.savedSettings.single.minYears, 4);

      // A permit for Malaysia: the ones not there yet, searchable.
      await _tap(tester, find.byKey(const ValueKey('c2c-permit-add-Malaysia')));
      expect(find.text('EVP'), findsOneWidget);
      await _tap(tester, find.text('EVP'));
      expect(repo.added, [(_my, 'evp')]);
      await _tap(tester, find.byTooltip('Remove PSV licence'));
      expect(repo.removed, ['cp1']);
    });
  }

  testWidgets('settings on a phone, read-only', (tester) async {
    await _pump(tester, const CityToCitySettingsScreen(), size: const Size(400, 2600), canEdit: false);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('c2c-settings-save')), findsNothing);
    expect(find.byKey(const ValueKey('c2c-permit-add-Malaysia')), findsNothing);
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('c2c-fee-on'))).onChanged, isNull);
  });

  for (final b in Brightness.values) {
    testWidgets('routes: the rules, the default, the editor and its example (${b.name})', (tester) async {
      final repo = await _pump(tester, const CityToCityRoutesScreen(), b: b);
      expect(find.byKey(const ValueKey('c2c-default-text')), findsOneWidget);
      expect(find.textContaining('Fare card + RM 0, range Auto ± 8%'), findsOneWidget);
      expect(find.text('Kuala Lumpur · city'), findsNWidgets(2));
      expect(find.textContaining('Fixed RM 190', findRichText: true), findsOneWidget);
      expect(find.textContaining('RM 130 to RM 150', findRichText: true), findsOneWidget);
      expect(find.textContaining('Off', findRichText: true), findsOneWidget);
      expect(find.textContaining('→'), findsNothing);

      await _tap(tester, find.byKey(const ValueKey('c2c-rule-active-r2')));
      expect(repo.active, [('r2', true)]);

      // Kuala Lumpur's City to City card: 3 + 0.4 × 205 + 0.2 × 160 = 117, + RM 20.
      await _tap(tester, find.byKey(const ValueKey('c2c-rule-edit-r1')));
      expect(find.text('Suggested RM 137, range RM 130 to RM 150'), findsOneWidget);
      await _tap(tester, find.byTooltip('Raise Add-on, fixed'));
      expect(find.text('Suggested RM 142, range RM 130 to RM 150'), findsOneWidget);
      await _tap(tester, find.text('Auto ±%'));
      expect(find.text('Suggested RM 142, range RM 131 to RM 153'), findsOneWidget);
      await _tap(tester, find.text('Set years'));
      await _tap(tester, find.byTooltip('Raise Years'));
      await _tap(tester, find.byKey(const ValueKey('c2c-edit-ahead-30')));
      await _tap(tester, find.byKey(const ValueKey('c2c-edit-save')));
      final saved = repo.savedRules.single;
      expect([saved.id, saved.addOnAmount, saved.rangeMode, saved.yearsMode, saved.minYears, saved.bookAheadDays],
          ['r1', 25.0, C2cRangeMode.auto, C2cYearsMode.set, 4, 30]);

      // A new rule needs places on both ends.
      await _tap(tester, find.byKey(const ValueKey('c2c-rule-add')));
      expect(find.text('Add at least one place to From and To.'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('c2c-edit-save'))).onPressed, isNull);
      await _tap(tester, find.byKey(const ValueKey('c2c-edit-from-add')));
      await _tap(tester, find.text('Kuala Lumpur · city').last);
      await _tap(tester, find.byKey(const ValueKey('c2c-edit-to-add')));
      await _tap(tester, find.text('Ipoh · city').last);
      await _tap(tester, find.text('Fixed fare'));
      expect(find.textContaining('The fare card is not used.'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('c2c-edit-save')));
      final added = repo.savedRules.last;
      expect([added.id, added.from.single.name, added.to.single.name, added.fareMode],
          [null, 'Kuala Lumpur', 'Ipoh', C2cFareMode.fixed]);
      expect(added.fixedFare, isNotNull);

      // The default: the fare card only.
      await _tap(tester, find.byKey(const ValueKey('c2c-default-edit')));
      expect(find.textContaining('Applies to any City to City trip'), findsOneWidget);
      await _tap(tester, find.byTooltip('Raise Add-on, percent'));
      await _tap(tester, find.byKey(const ValueKey('c2c-edit-save')));
      expect(repo.savedSettings.single.defaultAddOnPercent, 1);
    });
  }

  testWidgets('routes on a phone: search, delete, read-only view', (tester) async {
    final repo = await _pump(tester, const CityToCityRoutesScreen(), size: const Size(400, 2000));
    expect(tester.takeException(), isNull);
    await _tap(tester, find.byKey(const ValueKey('c2c-rule-edit-r2')));
    await _tap(tester, find.byKey(const ValueKey('c2c-edit-delete')));
    await _tap(tester, find.text('Delete').last);
    expect(repo.deleted, ['r2']);
  });

  testWidgets('routes read-only: View, no switches', (tester) async {
    await _pump(tester, const CityToCityRoutesScreen(), canEdit: false);
    expect(find.text('View'), findsWidgets);
    expect(tester.widget<Switch>(find.byKey(const ValueKey('c2c-rule-active-r1'))).onChanged, isNull);
  });

  for (final b in Brightness.values) {
    testWidgets('commission per service: own rate, preview, which rate wins (${b.name})', (tester) async {
      final repo = await _pump(
        tester,
        const Scaffold(body: CommissionServiceTab(canEdit: true)),
        b: b,
      );
      expect(find.text('Which rate wins (first match)'), findsOneWidget);
      expect(find.byKey(const ValueKey('commission-service-rate-prem')), findsOneWidget);
      expect(find.text('18%'), findsOneWidget);

      await _tap(tester, find.descendant(
          of: find.byKey(const ValueKey('commission-service-c2c')), matching: find.text('City to City')));
      await _tap(tester, find.byKey(const ValueKey('commission-service-place-1')));
      expect(find.textContaining('No own rate for City to City, so the Selangor, Malaysia rate of 15% applies.'),
          findsOneWidget);
      await _tap(tester, find.descendant(
          of: find.byKey(const ValueKey('commission-service-mode-c2c')), matching: find.text('Own rate')));
      expect(find.byKey(const ValueKey('commission-service-rate-c2c')), findsOneWidget);
      await _tap(tester, find.byTooltip('Raise City to City rate'));
      expect(tester.widget<Text>(find.byKey(const ValueKey('commission-service-rate-c2c'))).data, '12.5%');
      expect(tester.widget<Text>(find.byKey(const ValueKey('commission-service-used'))).data, '12.5%');
      expect(find.textContaining('City to City has its own 12.5%'), findsOneWidget);
      await _tap(tester, find.descendant(
          of: find.byKey(const ValueKey('commission-service-mode-prem')), matching: find.text('Place rate')));
      await _tap(tester, find.byKey(const ValueKey('commission-service-save')));
      expect(repo.rates, containsAll([('c2c', 0.125), ('prem', null)]));
    });
  }
}
