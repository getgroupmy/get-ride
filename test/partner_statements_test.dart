// Partner statements (migration 0201): the periods and totals the app reads,
// the Statements page (download, offline copy, language), the public
// verification page, and Admin → Partner statements (light and dark).
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/commerce/partner_statements_screen.dart';
import 'package:get_ride/src/core/driver_earnings.dart' show EarningsPeriod;
import 'package:get_ride/src/core/partner_statement.dart';
import 'package:get_ride/src/data/partner_statement_repository.dart';
import 'package:get_ride/src/features/partner/statement_verify_screen.dart';
import 'package:get_ride/src/features/partner/statements_screen.dart';

class _FakeRepo implements PartnerStatementRepository {
  _FakeRepo({this.offline = false, this.cachedCopy});

  final bool offline;
  final Uint8List? cachedCopy;
  final downloads = <String>[];
  final savedSettings = <StatementSettings>[];
  final credited = <(String, double, String)>[];
  final adjusted = <(String, double, String)>[];
  StatementLang lang = StatementLang.en;

  @override
  Future<List<StatementPeriod>> periods(StatementType type, {int limit = 12, DateTime? before}) async => [
    StatementPeriod(
      type: type,
      start: DateTime.utc(2026, 10, 12),
      end: DateTime.utc(2026, 10, 18),
      status: StatementStatus.provisional,
      net: 120.5,
      trips: 9,
    ),
    StatementPeriod(
      type: type,
      start: DateTime.utc(2026, 10, 5),
      end: DateTime.utc(2026, 10, 11),
      status: StatementStatus.revised,
      net: 300,
      trips: 21,
    ),
  ];

  @override
  Future<({StatementDownload info, Uint8List bytes})> download(StatementPeriod p, StatementLang lang) async {
    downloads.add('${p.type.name}-${isoDate(p.start)}-${lang.name}');
    if (offline) throw const StatementError('offline');
    return (
      info: const StatementDownload(
        url: 'https://signed',
        fileName: 'getride-statement.pdf',
        statementNo: 'GR-W-2026-000001',
        status: StatementStatus.revised,
      ),
      bytes: Uint8List.fromList([37, 80, 68, 70]),
    );
  }

  @override
  Future<Uint8List?> cached(StatementPeriod p, StatementLang lang) async => cachedCopy;

  @override
  Future<StatementLang> savedLang() async => lang;

  @override
  Future<void> saveLang(StatementLang l) async => lang = l;

  @override
  Future<PayoutAccount?> payoutAccount() async => null;

  @override
  Future<StatementSettings> saveSettings(StatementSettings s) async {
    savedSettings.add(s);
    return s;
  }

  @override
  Future<List<({String name, int trips})>> surchargeNames() async => const [
    (name: 'Airport', trips: 40),
    (name: 'Night', trips: 12),
  ];

  @override
  Future<List<StatementEntry>> entries(String kind, {int limit = 100}) async => [
    StatementEntry(
      id: 'e1',
      kind: kind,
      partnerName: 'Ahmad',
      partnerId: 'GR201A',
      amount: kind == 'incentive' ? 15 : -2,
      label: kind == 'incentive' ? 'Two-trip week' : 'Toll refunded twice',
      at: DateTime(2026, 10, 12),
      byName: 'Ops',
    ),
  ];

  @override
  Future<void> creditIncentive(String partner, double amount, String label) async =>
      credited.add((partner, amount, label));

  @override
  Future<void> postAdjustment(String partner, double amount, String reason, DateTime? effective) async =>
      adjusted.add((partner, amount, reason));

  @override
  Future<StatementVerification?> verify(String token) async => token == 'a1b2c3d4e5f6a1b2c3d4e5f6'
      ? StatementVerification.fromJson({
          'statementNo': 'GR-W-2026-000001',
          'initials': 'ABA',
          'type': 'weekly',
          'periodStart': '2026-09-07',
          'periodEnd': '2026-09-13',
          'net': 58.3,
          'final': true,
          'revisedAt': '2026-09-20T01:00:00Z',
          'issuedAt': '2026-09-20T01:00:00Z',
        })
      : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('periods and totals', () {
    test('totals read the server\'s numbers, strings or numbers', () {
      final t = StatementTotals.fromJson({'net': '58.3', 'trips': 2, 'taxes': 1.74, 'passThrough': 6.74});
      expect(t.net, 58.3);
      expect(t.trips, 2);
      expect(t.taxes, 1.74);
      expect(t.incentives, 0);
      expect(StatementTotals.fromJson(null).net, 0);
    });

    test('Malaysia days, whatever the device clock zone', () {
      // 23:30 UTC on 14 Oct is 07:30 on the 15th in Malaysia.
      expect(malaysiaDate(DateTime.utc(2026, 10, 14, 23, 30)), DateTime.utc(2026, 10, 15));
      expect(malaysiaMidnight(DateTime.utc(2026, 10, 15)), DateTime.utc(2026, 10, 14, 16));
    });

    test('weeks start Monday, or Sunday when the admin says so', () {
      final thu = DateTime.utc(2026, 10, 15);
      expect(statementWeekStart(thu), DateTime.utc(2026, 10, 12));
      expect(statementWeekStart(thu, sunday: true), DateTime.utc(2026, 10, 11));
      expect(statementWeekStart(DateTime.utc(2026, 10, 11), sunday: true), DateTime.utc(2026, 10, 11));
      expect(statementWeekStart(DateTime.utc(2026, 10, 11)), DateTime.utc(2026, 10, 5));
    });

    test('the Earnings page\'s periods, to the end of today', () {
      final now = DateTime.utc(2026, 10, 15, 2);
      final today = earningsRange(EarningsPeriod.today, now);
      expect(today.from, DateTime.utc(2026, 10, 14, 16));
      expect(today.to, DateTime.utc(2026, 10, 15, 16));
      expect(earningsRange(EarningsPeriod.week, now).from, DateTime.utc(2026, 10, 11, 16));
      expect(earningsRange(EarningsPeriod.week, now, sunday: true).from, DateTime.utc(2026, 10, 10, 16));
      expect(earningsRange(EarningsPeriod.month, now).from, DateTime.utc(2026, 9, 30, 16));
      expect(earningsWeeksRange(now).from, DateTime.utc(2026, 8, 23, 16));
    });

    test('labels, statuses and the tax-season pin', () {
      StatementPeriod p(StatementType type, DateTime s, DateTime e) =>
          StatementPeriod(type: type, start: s, end: e, status: StatementStatus.finalised, net: 0, trips: 0);
      expect(p(StatementType.weekly, DateTime(2026, 9, 7), DateTime(2026, 9, 13)).label, '7 – 13 Sep 2026');
      expect(p(StatementType.weekly, DateTime(2026, 9, 28), DateTime(2026, 10, 4)).label, '28 Sep – 4 Oct 2026');
      expect(p(StatementType.monthly, DateTime(2026, 9), DateTime(2026, 9, 30)).label, 'Sep 2026');
      expect(p(StatementType.annual, DateTime(2025), DateTime(2025, 12, 31)).label, '2025');
      expect(
        p(StatementType.weekly, DateTime(2026, 9, 7), DateTime(2026, 9, 13)).cacheName(StatementLang.ms),
        'statement-weekly-2026-09-07-ms.pdf',
      );
      expect(StatementStatus.parse('final'), StatementStatus.finalised);
      expect(StatementStatus.parse('final', revisedAt: '2026-09-20'), StatementStatus.revised);
      expect(StatementStatus.parse('provisional'), StatementStatus.provisional);
      expect(taxSeasonYear(DateTime.utc(2027, 3, 1)), 2026);
      expect(taxSeasonYear(DateTime.utc(2027, 4, 30, 12)), 2026);
      expect(taxSeasonYear(DateTime.utc(2027, 5, 2)), isNull);
    });

    test('settings: read, cleaned on the way out, compared by value', () {
      final s = StatementSettings.fromJson({
        'weekStart': 'sunday',
        'earningSurcharges': ['Airport', ' ', 'Night'],
        'showBank': true,
        'companyName': 'PUNCAK NIAGA BERSAMA SDN. BHD.',
      });
      expect(s.weekStartsSunday, isTrue);
      expect(s.earningSurcharges, ['Airport', 'Night']);
      expect(s.toJson()['weekStart'], 'sunday');
      expect(s, StatementSettings.fromJson(s.toJson()));
      expect(s == s.copyWith(showBank: false), isFalse);
      expect(StatementSettings.fromJson(null).weekStartsSunday, isFalse);
    });

    test('payout account numbers and verify tokens', () {
      expect(payoutAccountError('1234-5678 9012'), isNull);
      expect(payoutAccountError('12ab'), isNotNull);
      expect(isStatementToken('a1b2c3d4e5f6a1b2c3d4e5f6'), isTrue);
      expect(isStatementToken('../etc'), isFalse);
      expect(statementErrorMessage(null, status: 429), contains('this hour'));
      expect(statementErrorMessage('There is no statement for that period.'), 'There is no statement for that period.');
    });
  });

  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';

    group('Statements page ($mode)', () {
      Future<(_FakeRepo, List<(String, String)>)> pump(WidgetTester tester, _FakeRepo repo) async {
        final opened = <(String, String)>[];
        await tester.binding.setSurfaceSize(const Size(420, 1400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              partnerStatementRepositoryProvider.overrideWithValue(repo),
              statementSettingsProvider.overrideWith((_) async => const StatementSettings(showBank: true)),
              statementPdfOpenerProvider.overrideWithValue((context, bytes, name, title) async {
                opened.add((name, title));
              }),
            ],
            child: MaterialApp(theme: dark ? ThemeData.dark() : ThemeData.light(), home: const StatementsScreen()),
          ),
        );
        await tester.pumpAndSettle();
        return (repo, opened);
      }

      testWidgets('lists periods with their status; a tap downloads in the chosen language', (tester) async {
        final (repo, opened) = await pump(tester, _FakeRepo());
        expect(find.text('Provisional'), findsOneWidget);
        expect(find.text('Revised'), findsOneWidget);
        expect(find.textContaining('9 trips'), findsOneWidget);
        expect(find.byKey(const ValueKey('statements-payout')), findsOneWidget);

        await tester.tap(find.text('Bahasa Melayu'));
        await tester.pumpAndSettle();
        expect(repo.lang, StatementLang.ms, reason: 'remembered on the device');

        await tester.tap(find.byKey(const ValueKey('statement-weekly-2026-10-05')));
        await tester.pumpAndSettle();
        expect(repo.downloads, ['weekly-2026-10-05-ms']);
        expect(opened.single.$1, 'getride-statement.pdf');
        expect(opened.single.$2, contains('5 – 11 Oct 2026'));
      });

      testWidgets('offline, the copy on the device opens', (tester) async {
        final (repo, opened) = await pump(
          tester,
          _FakeRepo(offline: true, cachedCopy: Uint8List.fromList([37, 80, 68, 70])),
        );
        await tester.tap(find.byKey(const ValueKey('statement-weekly-2026-10-12')));
        await tester.pumpAndSettle();
        expect(opened, hasLength(1));
        expect(find.textContaining('copy saved on this device'), findsOneWidget);
      });

      testWidgets('offline with no copy: says so, opens nothing', (tester) async {
        final (_, opened) = await pump(tester, _FakeRepo(offline: true));
        await tester.tap(find.byKey(const ValueKey('statement-weekly-2026-10-12')));
        await tester.pumpAndSettle();
        expect(opened, isEmpty);
        expect(find.text('offline'), findsOneWidget);
      });
    });

    testWidgets('verification page ($mode)', (tester) async {
      final repo = _FakeRepo();
      Future<void> open(String token) async {
        await tester.pumpWidget(
          ProviderScope(
            key: UniqueKey(),
            overrides: [partnerStatementRepositoryProvider.overrideWithValue(repo)],
            child: MaterialApp(
              theme: dark ? ThemeData.dark() : ThemeData.light(),
              home: StatementVerifyScreen(token: token),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await open('a1b2c3d4e5f6a1b2c3d4e5f6');
      expect(tester.widget<Text>(find.byKey(const ValueKey('verify-no'))).data, 'GR-W-2026-000001');
      expect(tester.widget<Text>(find.byKey(const ValueKey('verify-net'))).data, contains('58.30'));
      expect(tester.widget<Text>(find.byKey(const ValueKey('verify-status'))).data, 'Revised');
      expect(find.text('A.B.A'), findsOneWidget);

      await open('ffffffffffffffffffffffff');
      expect(find.byKey(const ValueKey('verify-unknown')), findsOneWidget);
      await open('not-a-token');
      expect(find.byKey(const ValueKey('verify-unknown')), findsOneWidget);
    });

    group('Admin → Partner statements ($mode)', () {
      Future<_FakeRepo> pump(WidgetTester tester, {bool edit = true}) async {
        final repo = _FakeRepo();
        await tester.binding.setSurfaceSize(const Size(500, 2400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              adminAccessProvider.overrideWith((_) async => AdminAccess([AdminGrant(page: '*', edit: edit)])),
              partnerStatementRepositoryProvider.overrideWithValue(repo),
              statementSettingsProvider.overrideWith(
                (_) async => const StatementSettings(companyName: 'PUNCAK NIAGA BERSAMA SDN. BHD.'),
              ),
            ],
            child: MaterialApp(
              theme: dark ? ThemeData.dark() : ThemeData.light(),
              home: const AdminPartnerStatementsScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return repo;
      }

      testWidgets('marks a surcharge as earnings, Sunday weeks, the bank line; saves', (tester) async {
        final repo = await pump(tester);
        expect(find.byKey(const ValueKey('statements-save')), findsNothing, reason: 'nothing changed yet');
        await tester.tap(find.byKey(const ValueKey('statements-surcharge-Airport')));
        await tester.pump();
        await tester.tap(find.text('Sunday – Saturday'));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('statements-bank')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('statements-save')));
        await tester.pumpAndSettle();
        final s = repo.savedSettings.single;
        expect(s.earningSurcharges, ['Airport']);
        expect(s.weekStartsSunday, isTrue);
        expect(s.showBank, isTrue);
        expect(s.companyName, 'PUNCAK NIAGA BERSAMA SDN. BHD.');
      });

      testWidgets('credits an incentive after confirming', (tester) async {
        final repo = await pump(tester);
        await tester.tap(find.byKey(const ValueKey('statements-tab-incentives')));
        await tester.pumpAndSettle();
        expect(find.text('Two-trip week'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('statements-new-incentive')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('entry-partner')), 'GR201A');
        await tester.enterText(find.byKey(const ValueKey('entry-amount')), '-5');
        await tester.enterText(find.byKey(const ValueKey('entry-label')), 'Rainy day bonus');
        await tester.tap(find.byKey(const ValueKey('entry-submit')));
        await tester.pumpAndSettle();
        expect(find.text('An incentive is more than 0'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('entry-amount')), '12.50');
        await tester.tap(find.byKey(const ValueKey('entry-submit')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Credit').last);
        await tester.pumpAndSettle();
        expect(repo.credited, [('GR201A', 12.5, 'Rainy day bonus')]);
      });

      testWidgets('posts a minus adjustment', (tester) async {
        final repo = await pump(tester);
        await tester.tap(find.byKey(const ValueKey('statements-tab-adjustments')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('statements-new-adjustment')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('entry-partner')), '60120000201');
        await tester.enterText(find.byKey(const ValueKey('entry-amount')), '-2');
        await tester.enterText(find.byKey(const ValueKey('entry-label')), 'Toll refunded twice');
        await tester.tap(find.byKey(const ValueKey('entry-submit')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Post').last);
        await tester.pumpAndSettle();
        expect(repo.adjusted, [('60120000201', -2.0, 'Toll refunded twice')]);
      });

      testWidgets('view-only admins change nothing', (tester) async {
        await pump(tester, edit: false);
        expect(
          tester.widget<CheckboxListTile>(find.byKey(const ValueKey('statements-surcharge-Airport'))).onChanged,
          isNull,
        );
        await tester.tap(find.byKey(const ValueKey('statements-tab-incentives')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('statements-new-incentive')), findsNothing);
      });
    });
  }
}
