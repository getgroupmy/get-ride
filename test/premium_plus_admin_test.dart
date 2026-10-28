// Admin › Premium and GET.Plus (migration 0316): the rules (Default and a
// region, every value editable, a region rule only overriding what it
// sets), the members and the revenue, in light and dark, wide and on a
// phone, read-only without the edit grant.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/admin_registry.dart';
import 'package:get_ride/src/admin/screens/geo/geo_data.dart' show regionsProvider;
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart' show RegionEntry;
import 'package:get_ride/src/admin/screens/premium_plus/premium_plus_screen.dart';
import 'package:get_ride/src/admin/screens/sub_admins_screen.dart' show grantablePages;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/premium_plus.dart';
import 'package:get_ride/src/data/live_tables.dart';
import 'package:get_ride/src/data/premium_plus_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'notice.dart';
import 'quiet_live.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

class _Repo extends PremiumPlusRepository {
  _Repo() : super(_db);

  List<PremiumPlusPlace> list = [
    const PremiumPlusPlace(id: 'd', level: 'default', rules: {
      'premiumOn': true, 'premiumMaxCarAge': 5, 'premiumModels': <String>[], 'premiumMinRating': 4.8,
      'premiumMinTrips': 200, 'plusOn': true, 'plusPrice': 19.9, 'plusDiscountPct': 10, 'plusMaxDiscount': 0,
      'plusFreeCancels': 2, 'plusPriority': true, 'plusGraceDays': 3,
    }),
    const PremiumPlusPlace(id: 'kl', level: 'city', country: 'Malaysia', state: 'Kuala Lumpur', city: 'Kuala Lumpur',
        rules: {'premiumMaxCarAge': 4}),
  ];
  final saved = <PremiumPlusPlace>[];
  final deleted = <String>[];
  final memberQueries = <({String? status, String? search})>[];

  @override
  Future<List<PremiumPlusPlace>> places() async => list;
  @override
  Future<PremiumPlusPlace> savePlace(PremiumPlusPlace p) async {
    saved.add(p);
    return p;
  }

  @override
  Future<void> deletePlace(String id) async => deleted.add(id);

  @override
  Future<PlusMembersPage> members({String? status, String? search, int limit = 50, int offset = 0}) async {
    memberQueries.add((status: status, search: search));
    return (
      total: 2,
      rows: [
        PlusMemberRow(riderId: 'r1', name: 'Aina Test', phone: '+60100000001', status: PlusStatus.active, live: true,
            periodEnd: DateTime(2026, 11, 28), price: 19.9, paid: 39.8, saved: 12.5, place: 'Kuala Lumpur, Malaysia'),
        PlusMemberRow(riderId: 'r2', name: 'Badrul Test', status: PlusStatus.grace, live: true,
            graceUntil: DateTime(2026, 10, 31), price: 19.9),
      ],
    );
  }

  @override
  Future<PlusRevenue> revenue({int days = 30}) async => PlusRevenue(
    days: days, active: 4, grace: 1, cancelling: 1, joins: 3, renewals: 2, failed: 1, fees: 99.5, discounts: 31.2,
    discountedRides: 14, waivedPaid: 4.8, freeCancels: 2, commissionOnMemberRides: 60, net: 63.5,
  );
}

final _regions = [
  RegionEntry(id: 'my', values: {'country': 'Malaysia'}),
  RegionEntry(id: 'sel', values: {'country': 'Malaysia', 'state': 'Selangor'}),
  RegionEntry(id: 'kl', values: {'country': 'Malaysia', 'state': 'Kuala Lumpur', 'city': 'Kuala Lumpur'}),
];

Future<_Repo> _pump(WidgetTester tester, {Brightness b = Brightness.light, Size size = const Size(1300, 2200),
    bool canEdit = true}) async {
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
        premiumPlusRepositoryProvider.overrideWithValue(repo),
        regionsProvider.overrideWith((ref) async => _regions),
      ],
      child: MaterialApp(theme: appTheme(b), home: const PremiumPlusScreen()),
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

String _value(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey('pp-value-$key'))).data ?? '';

void main() {
  test('listed under Services & catalogue, grantable, followed live', () {
    final e = allAdminEntries.firstWhere((e) => e.path == premiumPlusPath);
    expect(premiumPlusPath, '/admin/m/premium-plus');
    expect(e.section, 'Services & catalogue');
    expect(e.pages, [premiumPlusPage]);
    expect(grantablePages, contains(premiumPlusPage));
    expect(liveSettingTables, contains('premium_plus_places'));
  });

  for (final b in Brightness.values) {
    testWidgets('Default: every value editable, models, save (${b.name})', (tester) async {
      final repo = await _pump(tester, b: b);
      expect(find.text('Premium service'), findsOneWidget);
      expect(find.text('GET.Plus rider membership'), findsOneWidget);
      expect(_value(tester, 'premiumMaxCarAge'), '5 years old');
      expect(_value(tester, 'plusDiscountPct'), '10%');
      expect(find.byKey(const ValueKey('pp-models-any')), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('pp-save'))).onPressed, isNull);
      expect(find.textContaining('→'), findsNothing);

      await _tap(tester, find.byTooltip('Raise Car at most'));
      await _tap(tester, find.byTooltip('Lower Driver rating at least'));
      await _tap(tester, find.byTooltip('Raise Discount on rides'));
      await _tap(tester, find.byTooltip('Raise Free cancels a month'));
      expect(_value(tester, 'premiumMaxCarAge'), '6 years old');
      expect(_value(tester, 'premiumMinRating'), '4.7');
      expect(_value(tester, 'plusDiscountPct'), '11%');

      await _tap(tester, find.byKey(const ValueKey('pp-model-add')));
      await tester.enterText(find.byKey(const ValueKey('pp-model-name')), '  Toyota   Camry ');
      await _tap(tester, find.byKey(const ValueKey('pp-model-save')));
      expect(find.byKey(const ValueKey('pp-model-Toyota Camry')), findsOneWidget);

      await _tap(tester, find.byKey(const ValueKey('pp-plusPriority')));
      await _tap(tester, find.byKey(const ValueKey('pp-save')));
      final s = repo.saved.single;
      expect(s.id, 'd');
      expect(s.rules['premiumMaxCarAge'], 6);
      expect(s.rules['premiumMinRating'], 4.7);
      expect(s.rules['plusDiscountPct'], 11);
      expect(s.rules['plusFreeCancels'], 3);
      expect(s.rules['plusPriority'], isFalse);
      expect(s.rules['premiumModels'], ['Toyota Camry']);
    });
  }

  testWidgets('a region rule: inherited values, set here, reset, add and remove', (tester) async {
    final repo = await _pump(tester);
    await _tap(tester, find.byKey(const ValueKey('pp-place-malaysia|kuala lumpur|kuala lumpur')));
    expect(_value(tester, 'premiumMaxCarAge'), '4 years old');
    expect(find.text('As the place above'), findsWidgets);
    expect(find.byKey(const ValueKey('pp-reset-premiumMaxCarAge')), findsOneWidget);
    expect(find.byKey(const ValueKey('pp-reset-plusPrice')), findsNothing);

    // Set the price here, then take the age back to Default's.
    await _tap(tester, find.byTooltip('Raise Price a month'));
    await _tap(tester, find.byKey(const ValueKey('pp-reset-premiumMaxCarAge')));
    expect(_value(tester, 'premiumMaxCarAge'), '5 years old');
    await _tap(tester, find.byKey(const ValueKey('pp-save')));
    expect(repo.saved.single.id, 'kl');
    expect(repo.saved.single.rules, {'plusPrice': 20.9});

    // A new rule for Selangor, from the regions.
    await _tap(tester, find.byKey(const ValueKey('pp-add-region')));
    expect(find.text('Kuala Lumpur · city'), findsNothing, reason: 'already has a rule');
    await _tap(tester, find.text('Selangor · state'));
    await _tap(tester, find.byKey(const ValueKey('pp-plusOn')));
    await _tap(tester, find.byKey(const ValueKey('pp-save')));
    final added = repo.saved.last;
    expect([added.id, added.level, added.country, added.state, added.rules], [null, 'state', 'Malaysia', 'Selangor', {'plusOn': false}]);

    // Remove Kuala Lumpur's.
    await _tap(tester, find.byKey(const ValueKey('pp-place-malaysia|kuala lumpur|kuala lumpur')));
    await _tap(tester, find.byKey(const ValueKey('pp-remove')));
    await _tap(tester, find.byKey(const ValueKey('pp-remove-confirm')));
    expect(repo.deleted, ['kl']);
  });

  testWidgets('on a phone, read-only', (tester) async {
    await _pump(tester, size: const Size(390, 2600), canEdit: false);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('pp-save')), findsNothing);
    expect(find.byKey(const ValueKey('pp-add-region')), findsNothing);
    expect(find.byKey(const ValueKey('pp-model-add')), findsNothing);
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('pp-plusOn'))).onChanged, isNull);
  });

  for (final b in Brightness.values) {
    testWidgets('members and revenue (${b.name})', (tester) async {
      final repo = await _pump(tester, b: b, size: const Size(900, 1600));
      await _tap(tester, find.byKey(const ValueKey('pp-view-members')));
      expect(find.text('2 members'), findsOneWidget);
      expect(find.text('Aina Test'), findsOneWidget);
      expect(find.textContaining('Payment due by 31 Oct 2026'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('pp-members-search')), 'aina');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const ValueKey('pp-members-grace')));
      expect(repo.memberQueries.last, (status: 'grace', search: 'aina'));

      await _tap(tester, find.byKey(const ValueKey('pp-view-revenue')));
      expect(tester.widget<Text>(find.byKey(const ValueKey('pp-revenue-active'))).data, '4');
      expect(tester.widget<Text>(find.byKey(const ValueKey('pp-revenue-fees'))).data, contains('99.50'));
      expect(tester.widget<Text>(find.byKey(const ValueKey('pp-revenue-net'))).data, contains('63.50'));
      expect(tester.takeException(), isNull);
    });
  }
}
