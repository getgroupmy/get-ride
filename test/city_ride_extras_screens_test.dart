// City ride extras (migration 0314) on screen, in light and dark: the admin
// page (Default and a region rule, wide and on a phone, read-only without
// the edit grant), the rider's luggage and waiting rows, the waiting clock,
// the rider's tip card and the driver's tip and cash tip card.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/admin_registry.dart';
import 'package:get_ride/src/admin/screens/city_ride_extras_screen.dart';
import 'package:get_ride/src/admin/screens/geo/geo_data.dart' show regionsProvider;
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart' show RegionEntry;
import 'package:get_ride/src/admin/screens/sub_admins_screen.dart' show grantablePages;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/city_ride_extras.dart';
import 'package:get_ride/src/core/partner_type_rules.dart' show RegionScope;
import 'package:get_ride/src/data/city_ride_extras_repository.dart';
import 'package:get_ride/src/data/live_tables.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/ride/city_extras_parts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'notice.dart';
import 'quiet_live.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

const _kl = RegionScope(country: 'Malaysia', state: 'Kuala Lumpur', city: 'Kuala Lumpur');

class _Repo extends CityRideExtrasRepository {
  _Repo() : super(_db);

  List<ExtrasPlace> list = const [
    ExtrasPlace(id: 'd', rules: {
      'luggage': {'freeBags': 1},
    }),
    ExtrasPlace(id: 'kl', scope: _kl),
  ];
  final saved = <ExtrasPlace>[];
  final deleted = <String>[];
  final tips = <(String, double, TipMethod)>[];
  final cash = <(bool, double?)>[];
  Map<String, dynamic> terms = _canTip;

  @override
  Future<List<ExtrasPlace>> places() async => list;
  @override
  Future<void> savePlace(ExtrasPlace p) async => saved.add(p);
  @override
  Future<void> deletePlace(String id) async => deleted.add(id);
  @override
  Future<TipTerms> tipTerms(String rideId) async => TipTerms.fromJson(terms);
  @override
  Future<void> tip(String rideId, double amount, TipMethod method) async => tips.add((rideId, amount, method));
  @override
  Future<void> cashTip(String rideId, {required bool on, double? amount}) async => cash.add((on, amount));
}

const _canTip = <String, dynamic>{
  'on': true,
  'presets': [2, 5, 10],
  'min': 1,
  'max': 100,
  'days': 3,
  'commissionPercent': 0,
  'until': '2026-10-30T10:00:00Z',
  'currency': 'MYR',
  'driverName': 'Hafiz Rahman',
  'canTip': true,
};

final _regions = [
  RegionEntry(id: 'my', values: {'country': 'Malaysia'}),
  RegionEntry(id: 'kl', values: {'country': 'Malaysia', 'state': 'Kuala Lumpur'}),
  RegionEntry(id: 'klc', values: {'country': 'Malaysia', 'state': 'Kuala Lumpur', 'city': 'Kuala Lumpur'}),
];

Future<_Repo> _pump(
  WidgetTester tester,
  Widget home, {
  Brightness b = Brightness.light,
  Size size = const Size(1300, 2000),
  bool canEdit = true,
  _Repo? repo,
  bool settle = true,
}) async {
  final r = repo ?? _Repo();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        ...quietLiveOverrides,
        pageAccessProvider.overrideWith((ref, page) => canEdit ? AccessLevel.edit : AccessLevel.read),
        cityRideExtrasRepositoryProvider.overrideWithValue(r),
        regionsProvider.overrideWith((ref) async => _regions),
      ],
      child: MaterialApp(theme: appTheme(b), home: home),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // A clock ticks every second: never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
  return r;
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await closeAnyNotice(tester);
  await tester.ensureVisible(f.first);
  await tester.pumpAndSettle();
  await tester.tap(f.first);
  await tester.pumpAndSettle();
}

String _value(WidgetTester tester, String section, String key) =>
    tester.widget<Text>(find.byKey(ValueKey('extras-$section-$key-value'))).data!;

RideRequest _ride(Map<String, dynamic> extra) => RideRequest({
  'id': 'ride-1',
  'status': 'completed',
  'fare': 20,
  'currency': 'MYR',
  'rider_name': 'Farah Tan',
  'partner_name': 'Hafiz Rahman',
  ...extra,
});

Widget _host(Widget child) => Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child));

void main() {
  test('listed under Services & catalogue, grantable, followed live', () {
    final e = allAdminEntries.firstWhere((e) => e.path == cityRideExtrasPath);
    expect(e.section, 'Services & catalogue');
    expect(e.title, 'City ride extras');
    expect(e.pages, [cityRideExtrasPage]);
    expect(grantablePages, contains(cityRideExtrasPage));
    expect(liveSettingTables, containsAll(['city_ride_extra_places', 'ride_tips']));
  });

  for (final b in Brightness.values) {
    testWidgets('admin: Default\'s cards, edited and saved (${b.name})', (tester) async {
      final repo = await _pump(tester, const CityRideExtrasScreen(), b: b);
      for (final s in ['tips', 'waiting', 'luggage']) {
        expect(find.byKey(ValueKey('extras-card-$s')), findsOneWidget);
      }
      expect(find.text('Default (everywhere)'), findsOneWidget);
      expect(_value(tester, 'luggage', 'freeBags'), '1', reason: 'Default\'s own value');
      expect(_value(tester, 'tips', 'preset2'), 'RM5');
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('extras-save'))).onPressed, isNull);

      await _tap(tester, find.byTooltip('Raise Then per minute'));
      expect(_value(tester, 'waiting', 'perMinute'), contains('0.35'));
      await _tap(tester, find.byKey(const ValueKey('extras-on-tips')));
      expect(find.byKey(const ValueKey('extras-tips-preset1')), findsNothing, reason: 'off: no values shown');
      await _tap(tester, find.byKey(const ValueKey('extras-save')));
      await closeAnyNotice(tester);
      final saved = repo.saved.single;
      expect(saved.isDefault, isTrue);
      expect(saved.rules['waiting'], containsPair('perMinute', 0.35));
      expect(saved.rules['tips'], containsPair('on', false));
      expect(saved.rules['luggage'], {'freeBags': 1}, reason: 'what was there is kept');
    });

    testWidgets('admin: a region rule sets only the cards it overrides (${b.name})', (tester) async {
      final repo = await _pump(tester, const CityRideExtrasScreen(), b: b);
      await _tap(tester, find.byKey(ValueKey('extras-rule-${_kl.key}')));
      expect(find.text('Kuala Lumpur, Kuala Lumpur, Malaysia'), findsOneWidget);
      final setHere = find.byKey(const ValueKey('extras-set-here-waiting'));
      expect(tester.widget<CheckboxListTile>(setHere).value, isFalse);
      expect(find.text('Uses the built-in values'), findsWidgets);
      expect(tester.widget<IconButton>(
        find.descendant(of: find.byKey(const ValueKey('extras-waiting-cap')), matching: find.byType(IconButton)).last,
      ).onPressed, isNull, reason: 'inherited: read here');

      await _tap(tester, setHere);
      await _tap(tester, find.byTooltip('Raise Most charged'));
      expect(_value(tester, 'waiting', 'cap'), 'RM7');
      await _tap(tester, find.byKey(const ValueKey('extras-save')));
      await closeAnyNotice(tester);
      final saved = repo.saved.single;
      expect(saved.id, 'kl');
      expect(saved.rules.keys, ['waiting']);
      expect(saved.rules['waiting'], {'on': true, 'freeMinutes': 3, 'perMinute': 0.3, 'cap': 7.0, 'radiusM': 150});

      await _tap(tester, find.byKey(const ValueKey('extras-remove-rule')));
      await closeAnyNotice(tester);
      expect(repo.deleted, ['kl']);
    });
  }

  testWidgets('admin: on a phone, and read-only without the edit grant', (tester) async {
    await _pump(tester, const CityRideExtrasScreen(), size: const Size(390, 844), canEdit: false);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('extras-save')), findsNothing);
    expect(find.byKey(const ValueKey('extras-add-rule')), findsNothing);
    expect(tester.widget<Switch>(find.byKey(const ValueKey('extras-on-tips'))).onChanged, isNull);
  });

  for (final b in Brightness.values) {
    testWidgets('booking: bags with what they add, and the waiting rule (${b.name})', (tester) async {
      var bags = 3;
      await _pump(
        tester,
        Scaffold(
          body: StatefulBuilder(
            builder: (context, set) => CityExtrasBookingRows(
              luggage: const LuggageRules(),
              waiting: const WaitingRules(),
              bags: bags,
              onBags: (n) => set(() => bags = n),
              money: (v) => 'RM${v.toStringAsFixed(2)}',
            ),
          ),
        ),
        b: b,
        size: const Size(390, 844),
      );
      expect(find.text('Luggage'), findsOneWidget);
      expect(find.text('2 free, then RM2.00 a bag · + RM2.00'), findsOneWidget);
      expect(find.textContaining('the first 3 minutes after your driver arrives are free'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('luggage-up')));
      await _tap(tester, find.byKey(const ValueKey('luggage-up')));
      expect(bags, 5);
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('luggage-up'))).onPressed, isNull, reason: 'five at most');
      await _tap(tester, find.byKey(const ValueKey('luggage-down')));
      expect(bags, 4);
    });

    testWidgets('the waiting clock: free time, then the charge (${b.name})', (tester) async {
      final from = DateTime.utc(2026, 10, 28, 10);
      Map<String, dynamic> arrived() => {
        'status': 'arrived',
        'waiting_from': from.toIso8601String(),
        'waiting_terms': {'freeMinutes': 3, 'perMinute': 0.5, 'cap': 6},
      };
      await _pump(
        tester,
        _host(WaitingClockCard(ride: _ride(arrived()), now: () => from.add(const Duration(seconds: 30)))),
        b: b,
        size: const Size(390, 844),
        settle: false,
      );
      expect(find.text('Free waiting'), findsOneWidget);
      expect(find.text('2:30 free left'), findsOneWidget);
      await _pump(
        tester,
        _host(WaitingClockCard(ride: _ride(arrived()), now: () => from.add(const Duration(minutes: 9, seconds: 20)))),
        b: b,
        size: const Size(390, 844),
        settle: false,
      );
      expect(find.text('Waiting charge running'), findsOneWidget);
      expect(find.textContaining('3.00'), findsOneWidget);
      expect(WaitingClockCard.shows(_ride({'status': 'arrived'})), isFalse, reason: 'no clock: nothing');
    });

    testWidgets('the rider tips a preset from GET.coin (${b.name})', (tester) async {
      final repo = await _pump(tester, _host(TipCard(ride: _ride({}))), b: b, size: const Size(390, 844));
      expect(find.text('Tip Hafiz?'), findsOneWidget);
      expect(find.textContaining('All of it goes to Hafiz.'), findsOneWidget);
      expect(find.text('Enter an amount'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('tip-preset-5.00')));
      await _tap(tester, find.text('GET.coin'));
      expect(find.text('Tip RM5'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('tip-send')));
      expect(repo.tips, [('ride-1', 5.0, TipMethod.coin)]);
      expect(find.textContaining('sent to Hafiz'), findsOneWidget);
    });
  }

  testWidgets('another amount out of range is refused before sending; Not now leaves it for the receipt', (tester) async {
    final repo = await _pump(tester, _host(TipCard(ride: _ride({}))), size: const Size(390, 844));
    await _tap(tester, find.byKey(const ValueKey('tip-other')));
    await tester.enterText(find.byKey(const ValueKey('tip-amount')), '0.2');
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const ValueKey('tip-send')));
    await pumpNotice(tester);
    expect(find.textContaining('Type any amount from'), findsOneWidget);
    await closeNotice(tester);
    expect(repo.tips, isEmpty);
    await _tap(tester, find.byKey(const ValueKey('tip-not-now')));
    expect(find.textContaining('You can tip from the receipt until'), findsOneWidget);
  });

  testWidgets('a tip already given is shown; tips off show nothing', (tester) async {
    final repo = _Repo()
      ..terms = {
        ..._canTip,
        'canTip': false,
        'why': 'tipped',
        'tip': {'amount': 5, 'method': 'get_wallet', 'driverAmount': 5},
      };
    await _pump(tester, _host(TipCard(ride: _ride({}))), repo: repo, size: const Size(390, 844));
    expect(find.textContaining('You tipped RM5 with GET.wallet'), findsOneWidget);
    final off = _Repo()..terms = {..._canTip, 'on': false};
    await _pump(tester, _host(TipCard(ride: _ride({}))), repo: off, size: const Size(390, 844));
    expect(find.byKey(const ValueKey('tip-card')), findsNothing);
  });

  for (final b in Brightness.values) {
    testWidgets('the driver sees the tip and marks a cash tip (${b.name})', (tester) async {
      final repo = _Repo()
        ..terms = {
          ..._canTip,
          'canTip': false,
          'why': 'not_rider',
          'commissionPercent': 10,
          'tip': {'amount': 5, 'method': 'get_wallet', 'driverAmount': 4.5},
        };
      await _pump(tester, _host(DriverTipCard(ride: _ride({}))), repo: repo, b: b, size: const Size(390, 844));
      expect(find.textContaining('Farah tipped RM5.00 (RM4.50 after commission).'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('driver-cash-tip')));
      expect(repo.cash, [(true, null)]);
      await tester.enterText(find.byKey(const ValueKey('driver-cash-tip-amount')), '3');
      await _tap(tester, find.byKey(const ValueKey('driver-cash-tip-save')));
      expect(repo.cash.last, (true, 3.0));
    });
  }
}
