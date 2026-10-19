import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_repository.dart';
import 'package:get_ride/src/admin/screens/commission_screen.dart';
import 'package:get_ride/src/admin/screens/geo/geo_data.dart' show regionsProvider;
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart' show RegionEntry;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/commission_promotions.dart';
import 'package:get_ride/src/core/commission_settings.dart';
import 'package:get_ride/src/core/partner_statement.dart';
import 'package:get_ride/src/features/partner/earnings_screen.dart'
    show CsvShareOutcome, EarningsTotalsCard, earningsCsvSharerProvider;
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:get_ride/src/admin/screens/meterapp/display_store.dart' show settingsEntriesProvider;

import 'quiet_live.dart';
import 'text_contrast.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

final _now = DateTime.now().toUtc();

class _Admin extends AdminRepository {
  _Admin() : super(_db);

  List<CommissionPromotion> promotions = [
    CommissionPromotion(
      id: 'p1',
      name: 'Raya week',
      rate: 0.05,
      startsAt: _now.subtract(const Duration(days: 1)),
      endsAt: _now.add(const Duration(days: 6)),
      city: 'Kajang',
      state: 'Selangor',
      country: 'Malaysia',
    ),
    CommissionPromotion(
      id: 'p2',
      name: 'Next month',
      rate: 0,
      startsAt: _now.add(const Duration(days: 30)),
      endsAt: _now.add(const Duration(days: 60)),
    ),
  ];
  final saved = <CommissionPromotion>[];
  final deleted = <String>[];
  final reports = <CommissionReportGroup>[];

  @override
  Future<List<CommissionPromotion>> commissionPromotions() async => promotions;

  @override
  Future<void> saveCommissionPromotion(CommissionPromotion p) async => saved.add(p);

  @override
  Future<void> deleteCommissionPromotion(String id) async => deleted.add(id);

  @override
  Future<List<({String name, int trips})>> commissionServiceNames() async => const [(name: 'car', trips: 40)];

  @override
  Future<List<CommissionReportRow>> commissionReport(DateTime from, DateTime to, CommissionReportGroup group) async {
    reports.add(group);
    return group == CommissionReportGroup.driver
        ? const [
            CommissionReportRow(key: 'u1', label: 'Ali', detail: 'GR201A', trips: 3, meterTrips: 1, base: 120, commission: 14.1),
          ]
        : const [
            CommissionReportRow(key: '2026-10-01', trips: 2, base: 100, commission: 12.5),
            CommissionReportRow(key: '2026-10-02', trips: 1, meterTrips: 1, base: 70, commission: 5.6),
          ];
  }

  @override
  Future<List<BelowCreditDriver>> driversBelowCredit() async => const [
    BelowCreditDriver(uid: 'u9', name: 'Debt Driver', displayId: 'GR9', balance: -60, floor: -50),
  ];

  @override
  Future<List<CommissionTier>> commissionTiers() async => const [];

  @override
  Future<CommissionConfig> commissionConfig() async => const CommissionConfig();

  @override
  Future<List<({String name, int trips})>> surchargeNamesSeen() async => const [];

  @override
  Future<List<Map<String, dynamic>>> commissionRates() async => const [
        {'id': 'm1', 'level': 'master', 'rate': 0.2, 'active': true},
        {'id': 'c1', 'level': 'city', 'rate': 0.125, 'city': 'Kajang', 'state': 'Selangor', 'country': 'Malaysia', 'active': true},
      ];

  @override
  Future<List<Map<String, dynamic>>> unchargedCommissions() async => const [];
}

final _regions = [
  RegionEntry(id: 'c', values: {'country': 'Malaysia'}),
  RegionEntry(id: 's', values: {'country': 'Malaysia', 'state': 'Selangor'}),
  RegionEntry(id: 'k', values: {'country': 'Malaysia', 'state': 'Selangor', 'city': 'Kajang'}),
  RegionEntry(id: 'b', values: {'country': 'Malaysia', 'state': 'Selangor', 'city': 'Bangi'}),
];

Future<(_Admin, List<String>)> _pump(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  bool edit = true,
  Size size = const Size(900, 2000),
  Map<String, String> colors = const {},
  double textScale = 1,
}) async {
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final admin = _Admin();
  final exported = <String>[];
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        supabaseProvider.overrideWithValue(_db),
        ...quietLiveOverrides,
        adminAccessProvider.overrideWith((_) async => AdminAccess([AdminGrant(page: '*', edit: edit)])),
        adminRepositoryProvider.overrideWithValue(admin),
        regionsProvider.overrideWith((_) async => _regions),
        // Vehicle Services names the 'car' key "CAR".
        settingsEntriesProvider('vehicle-services').overrideWith(
          (_) async => const [
            {'id': 'v1', 'values': {'name': 'CAR'}},
          ],
        ),
        earningsCsvSharerProvider.overrideWithValue((String csv, String name, Rect? origin) async {
          exported.add('$name\n$csv');
          return CsvShareOutcome.downloaded;
        }),
      ],
      child: MaterialApp(theme: appTheme(brightness, colors: colors), home: const AdminCommissionScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return (admin, exported);
}

Future<void> _openTab(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

void main() {
  test('a promotion service reads as Vehicle Services names it, else capitalised', () {
    expect(promoServiceLabel('get xl', const ['Car', 'GET XL']), 'GET XL');
    expect(promoServiceLabel('premium', const []), 'Premium');
    expect(promoServiceLabel('moto_bike', const []), 'Moto Bike');
    expect(promoServiceLabel('meter', const ['Meter']), 'Meter / TEKSI');
  });

  group('promotions (logic)', () {
    final mondayMorning = DateTime.utc(2020, 6, 1, 0); // 08:00 in Malaysia
    CommissionPromotion promo({
      double rate = 0.05,
      List<int> weekdays = const [],
      int? from,
      int? to,
      String? city,
      List<String> services = const [],
      int? newDriverDays,
      bool active = true,
    }) => CommissionPromotion(
      name: 'x',
      rate: rate,
      active: active,
      startsAt: DateTime.utc(2020),
      endsAt: DateTime.utc(2021),
      city: city,
      services: services,
      weekdays: weekdays,
      timeFrom: from,
      timeTo: to,
      newDriverDays: newDriverDays,
    );
    bool fits(CommissionPromotion p, {DateTime? at, DateTime? local, String? service = 'car', String? city = 'Kajang',
            DateTime? joined}) =>
        p.fits(at: at ?? mondayMorning, local: local ?? DateTime(2020, 6, 1, 8), service: service, city: city, joined: joined);

    test('days and hours, past midnight too', () {
      final mornings = promo(weekdays: [1, 2, 3, 4, 5], from: 7 * 60, to: 10 * 60);
      expect(fits(mornings), isTrue);
      expect(fits(mornings, local: DateTime(2020, 6, 1, 11)), isFalse);
      expect(fits(mornings, local: DateTime(2020, 6, 6, 8)), isFalse, reason: 'a Saturday');
      final nights = promo(from: 22 * 60, to: 6 * 60);
      expect(nights.inHours(DateTime(2020, 6, 1, 23, 30)), isTrue);
      expect(nights.inHours(DateTime(2020, 6, 2, 5)), isTrue);
      expect(nights.inHours(DateTime(2020, 6, 2, 12)), isFalse);
      expect(mornings.hoursLabel, 'Mon–Fri 07:00–10:00');
      expect(promo(weekdays: [6, 7]).hoursLabel, 'Sat, Sun');
      expect(nights.hoursLabel, '22:00–06:00');
    });

    test('when, where, which service, new drivers, on or off', () {
      expect(fits(promo(), at: DateTime.utc(2021, 2)), isFalse, reason: 'ended');
      expect(fits(promo(active: false)), isFalse);
      expect(fits(promo(city: 'kajang ')), isTrue);
      expect(fits(promo(city: 'Kajang'), city: 'Bangi'), isFalse);
      expect(fits(promo(city: 'Kajang'), city: null), isFalse, reason: 'a named place must be the trip\'s');
      expect(fits(promo(services: [meterServiceName]), service: 'car'), isFalse);
      expect(fits(promo(services: [meterServiceName]), service: 'meter'), isTrue);
      final welcome = promo(newDriverDays: 30);
      expect(fits(welcome, joined: DateTime.utc(2020, 5, 20)), isTrue);
      expect(fits(welcome, joined: DateTime.utc(2020, 4, 1)), isFalse);
      expect(fits(welcome), isFalse, reason: 'unknown joining day');
    });

    test('the lowest rate wins; never raises; a personal rate stays', () {
      final a = promo(rate: 0.10), b = promo(rate: 0.05), high = promo(rate: 0.30);
      final best = applyCommissionPromotions(0.15, 'city', [a, b, high]);
      expect(best.rate, 0.05);
      expect(best.promotion, b);
      expect(applyCommissionPromotions(0.15, 'master', [high]).promotion, isNull);
      expect(applyCommissionPromotions(0.05, 'master', [b]).promotion, isNull, reason: 'a tie stays with the rate');
      expect(applyCommissionPromotions(0.25, 'user', [b]).rate, 0.25);
    });

    test('rows read back the same', () {
      final p = CommissionPromotion.fromRow({
        'id': 'x', 'name': 'Nights', 'rate': '0.0500', 'active': true,
        'starts_at': '2026-10-01T00:00:00+00:00', 'ends_at': '2026-11-01T00:00:00+00:00',
        'country': 'Malaysia', 'state': ' ', 'services': ['Meter', 'car'], 'weekdays': [5, 1],
        'time_from': '22:00:00', 'time_to': '06:00:00', 'new_driver_days': 30,
      });
      expect(p.state, isNull);
      expect(p.services, ['meter', 'car']);
      expect(p.weekdays, [1, 5]);
      expect(p.timeFrom, 22 * 60);
      expect(p.toRow()['time_to'], '06:00');
      expect(CommissionPromotion.fromRow(p.toRow()..['id'] = 'x'), p);
      expect(p.summary, '5% · Malaysia · Mon, Fri 22:00–06:00 · Meter / TEKSI, Car · New drivers, first 30 days');
      expect(p.statusAt(DateTime.utc(2026, 10, 15)), 'Running');
      expect(p.statusAt(DateTime.utc(2026, 9, 15)), 'Scheduled');
      expect(p.statusAt(DateTime.utc(2026, 11, 15)), 'Ended');
      expect(p.copyWith(active: false).statusAt(DateTime.utc(2026, 10, 15)), 'Off');
    });
  });

  group('reports (logic)', () {
    const rows = [
      CommissionReportRow(key: 'u1', label: 'Ali, "Bob"', detail: 'GR201A', trips: 3, meterTrips: 1, base: 120, commission: 14.1),
      CommissionReportRow(key: 'u2', trips: 1, base: 50, commission: 2.5),
    ];

    test('labels', () {
      expect(commissionReportLabel(const CommissionReportRow(key: '2026-10-05'), CommissionReportGroup.day), 'Mon 5 Oct 2026');
      expect(commissionReportLabel(const CommissionReportRow(key: '2026-10-05'), CommissionReportGroup.week),
          'Week of 5 Oct 2026');
      expect(commissionReportLabel(const CommissionReportRow(key: '2026-10-01'), CommissionReportGroup.month), 'Oct 2026');
      expect(commissionReportLabel(const CommissionReportRow(key: '|'), CommissionReportGroup.state), 'Unknown');
      expect(commissionReportLabel(rows[1], CommissionReportGroup.driver), 'Unknown driver');
    });

    test('the CSV: a line per row, escaped, then the total', () {
      final csv = commissionReportCsv(rows, CommissionReportGroup.driver).split('\n');
      expect(csv.first, 'driver,driver_id,partner_id,trips,meter_trips,charged_on,commission');
      expect(csv[1], '"Ali, ""Bob""",u1,GR201A,3,1,120.00,14.10');
      expect(csv.last, 'Total,,,4,1,170.00,16.60');
      final byDay = commissionReportCsv(const [CommissionReportRow(key: '2026-10-05', trips: 1, commission: 1)],
          CommissionReportGroup.day);
      expect(byDay.split('\n').first, 'day,trips,meter_trips,charged_on,commission');
      expect(byDay.split('\n')[1], '2026-10-05,1,0,0.00,1.00');
      final byCity = commissionReportCsv(
          const [CommissionReportRow(key: 'k', label: 'Kajang', detail: 'Selangor, Malaysia', commission: 1)],
          CommissionReportGroup.city);
      expect(byCity.split('\n')[1], 'Kajang,"Selangor, Malaysia",0,0,0.00,1.00');
    });

    test('below the limit', () {
      final d = BelowCreditDriver.fromRow(
          {'partner_id': 'u9', 'name': 'Debt', 'display_id': null, 'balance': '-60.5', 'credit_floor': -50});
      expect(d.shortBy, 10.5);
      expect(belowCreditCsv([d]).split('\n')[1], 'Debt,u9,,,-60.50,-50.00,10.50');
    });

    test('statement totals carry the meter trips', () {
      expect(StatementTotals.fromJson({'trips': 3, 'meterTrips': 1}).meterTrips, 1);
      expect(StatementTotals.fromJson({'trips': 3}).meterTrips, 0);
    });
  });

  for (final b in Brightness.values) {
    testWidgets('Earnings: meter trips shown with the trips, only when there are some (${b.name})', (tester) async {
      Future<void> card(Map<String, Object> totals) => tester.pumpWidget(MaterialApp(
        theme: appTheme(b),
        home: Scaffold(body: EarningsTotalsCard(totals: StatementTotals.fromJson(totals), money: (v) => 'RM $v')),
      ));
      await card({'trips': 3, 'meterTrips': 1, 'net': 40});
      expect(find.text('Of which meter / TEKSI'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('earnings-meter-trips'))).data, '1');
      await card({'trips': 3, 'net': 40});
      expect(find.byKey(const ValueKey('earnings-meter-trips')), findsNothing);
    });

    group('Admin → Commission → Promotions and Reports (${b.name})', () {
      testWidgets('Rates at 1.3x: the rate alone is the title, the level and place under it; the explainer is folded '
          '(${b.name})', (tester) async {
        await _pump(tester, brightness: b, size: const Size(412, 2000), textScale: 1.3);
        final title = tester.widget<Text>(find.byKey(const ValueKey('commission-rate-m1')));
        expect(title.data, '20.00%');
        expect(title.maxLines, 1);
        expect(find.textContaining('Master'), findsWidgets);
        expect(find.textContaining('City · Kajang, Selangor, Malaysia'), findsOneWidget);
        expect(find.byKey(const ValueKey('commission-how')), findsOneWidget);
        expect(find.byKey(const ValueKey('commission-how-text')), findsNothing, reason: 'folded at first');
        await tester.tap(find.text('How rates are chosen'));
        await tester.pumpAndSettle();
        final how = tester.widget<Text>(find.byKey(const ValueKey('commission-how-text'))).data!;
        expect(how, contains('user > suburb > city'));
        expect(how, isNot(contains('→')));
        expect(tester.takeException(), isNull);
      });

      testWidgets('Edit promotion: services by their Vehicle Services names; From and To are rounded rectangles '
          '(${b.name})', (tester) async {
        await _pump(tester, brightness: b, size: const Size(412, 2000));
        await tester.ensureVisible(find.byKey(const ValueKey('commission-tab-promotions')));
        await tester.pumpAndSettle();
        await _openTab(tester, 'commission-tab-promotions');
        await tester.tap(find.byKey(const ValueKey('commission-promo-add')));
        await tester.pumpAndSettle();
        final chip = tester.widget<FilterChip>(find.byKey(const ValueKey('promo-service-car')));
        expect((chip.label as Text).data, 'CAR', reason: 'the Vehicle Services name, not the key');
        expect((tester.widget<FilterChip>(find.byKey(const ValueKey('promo-service-meter'))).label as Text).data,
            'Meter / TEKSI');
        for (final key in ['promo-from', 'promo-to']) {
          final button = tester.widget<OutlinedButton>(find.byKey(ValueKey(key)));
          expect(button.style?.shape?.resolve({}), isA<RoundedRectangleBorder>(), reason: '$key is not an ellipse');
        }
        expect(tester.takeException(), isNull);
      });

      testWidgets('promotions at 412 px: the details run the full card width under the title row (${b.name})',
          (tester) async {
        await _pump(tester, brightness: b, size: const Size(412, 2000));
        await tester.ensureVisible(find.byKey(const ValueKey('commission-tab-promotions')));
        await tester.pumpAndSettle();
        await _openTab(tester, 'commission-tab-promotions');
        final card = tester.getRect(find.byKey(const ValueKey('commission-promo-p1')));
        final details = tester.getRect(find.byKey(const ValueKey('commission-promo-details-p1')));
        final toggle = tester.getRect(find.byKey(const ValueKey('commission-promo-active-p1')));
        expect(details.top, greaterThanOrEqualTo(toggle.bottom - 1), reason: 'below the switch, not beside it');
        expect(details.width, greaterThan(card.width - 48), reason: 'the full width, not a 180 px column');
        // Tapping the card still opens it.
        await tester.tap(find.byKey(const ValueKey('commission-promo-details-p1')));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      for (final faint in [false, true]) {
        testWidgets('promotions read at 360 px${faint ? ', with a faint admin grey' : ''} (${b.name})', (tester) async {
          await _pump(
            tester,
            brightness: b,
            size: const Size(360, 2000),
            colors: faint ? {'textSecondary': b == Brightness.light ? '#C8C8C8' : '#4A4A4A'} : const {},
          );
          await tester.ensureVisible(find.byKey(const ValueKey('commission-tab-promotions')));
          await tester.pumpAndSettle();
          await _openTab(tester, 'commission-tab-promotions');
          expect(find.text('Raya week'), findsOneWidget);
          expect(unreadableTexts(tester, find.byType(Scaffold).first), isEmpty);
          // (A faint admin grey also fades every field label app-wide: the
          // dialog is checked with the theme's own colours.)
          if (faint) return;
          await tester.tap(find.byKey(const ValueKey('commission-promo-add')));
          await tester.pumpAndSettle();
          expect(unreadableTexts(tester, find.byType(AlertDialog)), isEmpty, reason: 'the add dialog');
        });
      }

      testWidgets('promotions: listed, added with a place, a service and days, turned off, deleted', (tester) async {
        final (admin, _) = await _pump(tester, brightness: b);
        await _openTab(tester, 'commission-tab-promotions');
        expect(find.text('Raya week'), findsOneWidget);
        expect(find.text('Running'), findsOneWidget);
        expect(find.text('Scheduled'), findsOneWidget);
        expect(find.textContaining('5% · Kajang, Selangor, Malaysia'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('commission-promo-add')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('promo-save')));
        await tester.pumpAndSettle();
        expect(find.text('Give the promotion a name'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('promo-name')), 'Kajang mornings');
        await tester.enterText(find.byKey(const ValueKey('promo-rate')), '2.5');

        // Where: Malaysia → Selangor → Kajang, from the region lists.
        await tester.tap(find.byKey(const ValueKey('promo-country-/')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Malaysia').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('promo-state-Malaysia/')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Selangor').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('promo-city-Malaysia/Selangor')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Kajang').last);
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.byKey(const ValueKey('promo-service-meter')));
        await tester.tap(find.byKey(const ValueKey('promo-service-meter')));
        await tester.ensureVisible(find.byKey(const ValueKey('promo-day-1')));
        await tester.tap(find.byKey(const ValueKey('promo-day-1')));
        await tester.tap(find.byKey(const ValueKey('promo-day-2')));
        await tester.ensureVisible(find.byKey(const ValueKey('promo-hours')));
        await tester.tap(find.byKey(const ValueKey('promo-hours')));
        await tester.pumpAndSettle();
        expect(find.text('From 07:00'), findsOneWidget);
        await tester.ensureVisible(find.byKey(const ValueKey('promo-new-drivers')));
        await tester.tap(find.byKey(const ValueKey('promo-new-drivers')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('promo-days')), '14');
        await tester.tap(find.byKey(const ValueKey('promo-save')));
        await tester.pumpAndSettle();

        final p = admin.saved.single;
        expect(p.id, isNull);
        expect(p.name, 'Kajang mornings');
        expect(p.rate, 0.025);
        expect((p.country, p.state, p.city), ('Malaysia', 'Selangor', 'Kajang'));
        expect(p.services, [meterServiceName]);
        expect(p.weekdays, [1, 2]);
        expect((p.timeFrom, p.timeTo), (7 * 60, 10 * 60));
        expect(p.newDriverDays, 14);
        expect(p.endsAt.difference(p.startsAt), const Duration(days: 7));

        await tester.tap(find.byKey(const ValueKey('commission-promo-active-p1')));
        await tester.pumpAndSettle();
        expect(admin.saved.last.id, 'p1');
        expect(admin.saved.last.active, isFalse);

        await tester.tap(find.byKey(const ValueKey('commission-promo-delete-p1')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        expect(admin.deleted, ['p1']);
        expect(tester.takeException(), isNull);
      });

      testWidgets('promotions: read-only admins change nothing', (tester) async {
        await _pump(tester, brightness: b, edit: false);
        await _openTab(tester, 'commission-tab-promotions');
        expect(find.byKey(const ValueKey('commission-promo-add')), findsNothing);
        expect(find.byKey(const ValueKey('commission-promo-delete-p1')), findsNothing);
        expect(tester.widget<Switch>(find.byKey(const ValueKey('commission-promo-active-p1'))).onChanged, isNull);
      });

      testWidgets('reports: totals by period and driver, CSV, drivers under the limit', (tester) async {
        final (admin, exported) = await _pump(tester, brightness: b);
        await _openTab(tester, 'commission-tab-reports');
        expect(admin.reports, [CommissionReportGroup.day]);
        expect(find.text('Thu 1 Oct 2026'), findsOneWidget);
        expect(tester.widget<Text>(find.byKey(const ValueKey('report-total'))).data, contains('18.10'));
        expect(find.text('Debt Driver'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('report-group')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Driver').last);
        await tester.pumpAndSettle();
        expect(admin.reports.last, CommissionReportGroup.driver);
        expect(find.text('Ali'), findsOneWidget);
        expect(find.textContaining('GR201A · 3 trips · 1 meter'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('report-export')));
        await tester.pumpAndSettle();
        expect(exported.single, startsWith('commission-driver-'));
        expect(exported.single, contains('Ali,u1,GR201A,3,1,120.00,14.10'));
        expect(find.textContaining('Downloaded'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('below-credit-export')));
        await tester.pumpAndSettle();
        expect(exported.last, contains('Debt Driver,u9,GR9,,-60.00,-50.00,10.00'));
        expect(tester.takeException(), isNull);
      });
    });
  }
}
