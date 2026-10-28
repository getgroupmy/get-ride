// City ride safety (migration 0311) on screen, light and dark: the receipt's
// cover card, report and block; Settings › Blocked drivers; the driver's
// request filters; Admin › Ride safety.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/admin_registry.dart';
import 'package:get_ride/src/admin/screens/geo/geo_data.dart' show regionsProvider;
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart' show RegionEntry;
import 'package:get_ride/src/admin/screens/ride_safety/ride_safety_screen.dart';
import 'package:get_ride/src/admin/screens/sub_admins_screen.dart' show grantablePages;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/ride_safety.dart';
import 'package:get_ride/src/data/live_tables.dart';
import 'package:get_ride/src/data/ride_safety_repository.dart';
import 'package:get_ride/src/features/partner/request_filters_sheet.dart';
import 'package:get_ride/src/features/ride/trip_safety_parts.dart';
import 'package:get_ride/src/features/settings/blocked_drivers_screen.dart';
import 'package:get_ride/src/providers.dart' show currentUserIdProvider;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'notice.dart';
import 'quiet_live.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

Map<String, dynamic> _info({bool blocked = false, Map<String, dynamic>? report, bool cover = true}) => {
      'trip': {'ref': 'GR-80412ABC', 'driver_id': 'd1', 'driver_name': 'Hafiz R.', 'completed': true},
      'can_report': report == null,
      'report_window_days': 30,
      'report': report,
      'categories': [
        {'id': 'c1', 'label': 'Safety', 'urgent': true, 'sos_reminder': true},
        {'id': 'c2', 'label': 'Fare'},
      ],
      'blocked': blocked,
      'cover': cover
          ? {'shown': true, 'insurer': 'Contoh Takaful', 'policy_no': 'PA-2026-0001', 'cover_amount': 50000, 'claim_days': 30}
          : null,
      'permits': [
        {'name': 'E-hailing vehicle permit (eVP)', 'issuer': 'APAD', 'valid_until': '2027-06-30'},
      ],
    };

class _Repo extends RideSafetyRepository {
  _Repo() : super(_db);

  Map<String, dynamic> info = _info();
  final reports = <(String, String?, bool)>[];
  final blocks = <String?>[];
  final unblocks = <String>[];
  final filtersSaved = <RequestFilters>[];
  final savedSettings = <RideSafetySettings>[];
  final savedCategories = <TripReportCategory>[];
  final savedRules = <CoverRule>[];
  RideSafetySettings stored = const RideSafetySettings();
  List<BlockedDriver> blocked = [
    BlockedDriver(driverId: 'd1', name: 'Hafiz R.', vehicle: 'Perodua Bezza · WXY 1234', blockedAt: DateTime(2027, 5, 12)),
  ];

  @override
  Future<TripSafetyInfo?> tripInfo({String? requestId, String? c2cBookingId}) async => TripSafetyInfo.fromJson(info);
  @override
  Future<TripReportResult> report({
    String? requestId,
    String? c2cBookingId,
    required String categoryId,
    String? note,
    bool alsoBlock = false,
  }) async {
    reports.add((categoryId, note, alsoBlock));
    info = _info(blocked: alsoBlock, report: {'ticket_id': 't1', 'ticket_number': 10233, 'category': 'Safety'});
    return TripReportResult(ticketId: 't1', number: 10233, category: 'Safety', urgent: true, blocked: alsoBlock);
  }

  @override
  Future<void> block({String? driverId, String? requestId, String? c2cBookingId, String source = 'receipt'}) async {
    blocks.add(requestId);
    info = _info(blocked: true);
  }

  @override
  Future<void> unblock(String driverId) async {
    unblocks.add(driverId);
    blocked = [];
    info = _info();
  }

  @override
  Future<List<BlockedDriver>> blockedDrivers() async => blocked;
  @override
  Future<RideSafetySettings> settings() async => stored;
  @override
  Future<void> saveSettings(RideSafetySettings s) async => savedSettings.add(stored = s);
  @override
  Future<List<TripReportCategory>> categories() async => const [
        TripReportCategory(id: 'c1', label: 'Safety', urgent: true, sosReminder: true),
        TripReportCategory(id: 'c2', label: 'Fare', position: 1),
        TripReportCategory(id: 'c3', label: 'Old one', active: false),
      ];
  @override
  Future<void> saveCategory(TripReportCategory c) async => savedCategories.add(c);
  @override
  Future<List<CoverRule>> coverRules() async => const [
        CoverRule(id: 'r0', enabled: false),
        CoverRule(id: 'r1', country: 'Malaysia', insurer: 'Contoh Takaful', policyNo: 'PA-2026-0001', coverAmount: 50000),
      ];
  @override
  Future<void> saveCoverRule(CoverRule r) async => savedRules.add(r);
  @override
  Future<RequestFilters?> savedFilters(String driverId) async => null;
  @override
  Future<void> saveFilters(String driverId, RequestFilters f) async => filtersSaved.add(f);
  @override
  Future<({PassengerCover? cover, bool showPermit})> myCover() async =>
      (cover: PassengerCover.fromJson(_info()['cover']), showPermit: true);
}

Future<_Repo> _pump(WidgetTester tester, Widget home, {Brightness b = Brightness.light, Size size = const Size(420, 1600)}) async {
  final repo = _Repo();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    retry: (_, _) => null,
    overrides: [
      ...quietLiveOverrides,
      rideSafetyRepositoryProvider.overrideWithValue(repo),
      currentUserIdProvider.overrideWithValue('d9'),
      pageAccessProvider.overrideWith((ref, page) => AccessLevel.edit),
      regionsProvider.overrideWith((ref) async => [
            RegionEntry(id: 'my', values: {'country': 'Malaysia'}),
            RegionEntry(id: 'sb', values: {'country': 'Malaysia', 'state': 'Sabah'}),
          ]),
    ],
    child: MaterialApp(theme: appTheme(b), home: Scaffold(body: home)),
  ));
  await tester.pumpAndSettle();
  return repo;
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f.first);
  await tester.pumpAndSettle();
  await tester.tap(f.first);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Ride safety is an admin page, grantable, followed live', () {
    final e = allAdminEntries.firstWhere((e) => e.path == rideSafetyPath);
    expect([e.section, e.pages], ['Operations', [rideSafetyPage]]);
    expect(grantablePages, contains(rideSafetyPage));
    expect(liveSettingTables, containsAll(['ride_safety_settings', 'trip_report_categories', 'passenger_cover_rules']));
  });

  for (final b in Brightness.values) {
    testWidgets('receipt: covered, report with the SOS reminder and also block (${b.name})', (tester) async {
      final repo = await _pump(tester, const SingleChildScrollView(child: TripSafetySection(requestId: 'r1')), b: b);
      expect(find.text('You were covered on this trip'), findsOneWidget);
      expect(find.textContaining('Contoh Takaful, policy PA-2026-0001'), findsOneWidget);
      expect(find.textContaining('Driver licensed by APAD'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('receipt-cover-claim')));
      expect(find.byKey(const ValueKey('receipt-cover-claim-text')), findsOneWidget);

      await _tap(tester, find.byKey(const ValueKey('receipt-report')));
      expect(find.text('What happened?'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('report-send'))).onPressed, isNull,
          reason: 'pick a category first');
      await _tap(tester, find.byKey(const ValueKey('report-category-Fare')));
      expect(find.byKey(const ValueKey('report-sos-reminder')), findsNothing);
      await _tap(tester, find.byKey(const ValueKey('report-category-Safety')));
      expect(find.text(sosReminderText), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('report-note')), 'He drove too fast.');
      await _tap(tester, find.byKey(const ValueKey('report-also-block')));
      expect(find.text('Also block Hafiz R.'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('report-send')));
      expect(repo.reports.single, ('c1', 'He drove too fast.', true));
      await pumpNotice(tester);
      expect(find.textContaining('Report sent: ticket #10233 (Safety).'), findsOneWidget);
      expect(find.textContaining('Hafiz R. is blocked.'), findsOneWidget);
      await closeNotice(tester);
      expect(find.textContaining('Reported: ticket #10233 (Safety)'), findsOneWidget);
      expect(find.text('Unblock Hafiz R.'), findsOneWidget);
    });

    testWidgets('receipt: block from its sheet, then unblock (${b.name})', (tester) async {
      final repo = await _pump(tester, const SingleChildScrollView(child: TripSafetySection(requestId: 'r1')), b: b);
      await _tap(tester, find.byKey(const ValueKey('receipt-block')));
      expect(find.text('Block Hafiz R.?'), findsOneWidget);
      expect(find.textContaining('Settings › Blocked drivers'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('block-confirm')));
      expect(repo.blocks, ['r1']);
      await closeNotice(tester);
      await _tap(tester, find.text('Unblock Hafiz R.'));
      expect(repo.unblocks, ['d1']);
      await closeAnyNotice(tester);
      expect(find.text('Block this driver'), findsOneWidget);
    });

    testWidgets('Settings › Blocked drivers lists and unblocks (${b.name})', (tester) async {
      final repo = await _pump(tester, const BlockedDriversScreen(), b: b);
      expect(find.text('Hafiz R.'), findsOneWidget);
      expect(find.textContaining('Perodua Bezza · WXY 1234 · blocked'), findsOneWidget);
      expect(find.textContaining('up to 20 drivers'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('unblock-d1')));
      expect(repo.unblocks, ['d1']);
      await closeAnyNotice(tester);
      expect(find.byKey(const ValueKey('blocked-drivers-empty')), findsOneWidget);
    });

    testWidgets('driver request filters within the admin\'s limits (${b.name})', (tester) async {
      final repo = await _pump(tester, const RequestFiltersSheet(), b: b);
      expect(find.text('Admin allows up to RM30'), findsOneWidget);
      expect(find.text('Admin allows 1 km to 10 km'), findsOneWidget);
      for (var i = 0; i < 8; i++) {
        final up = find.ancestor(of: find.byTooltip('Raise'), matching: find.byType(IconButton));
        if (tester.widget<IconButton>(up.first).onPressed == null) break;
        await _tap(tester, up);
      }
      expect(find.text('RM30'), findsOneWidget, reason: 'stops at the cap');
      await _tap(tester, find.byTooltip('Closer'));
      expect(find.text('10 km'), findsOneWidget);
      await _tap(tester, find.byTooltip('Closer'));
      await _tap(tester, find.text('Price'));
      await _tap(tester, find.byKey(const ValueKey('filter-done')));
      expect(repo.filtersSaved.single, const RequestFilters(minFare: 30, maxKm: 9, sort: RequestSort.price));
    });

    testWidgets('the Safety page cover card (${b.name})', (tester) async {
      await _pump(tester, const PassengerCoverCard(), b: b);
      expect(find.text('You are covered on your trips'), findsOneWidget);
      expect(find.textContaining('on each trip\'s receipt'), findsOneWidget);
    });

    testWidgets('Admin › Ride safety: categories, limits, filters, cover (${b.name})', (tester) async {
      final repo = await _pump(tester, const RideSafetyScreen(), b: b, size: const Size(1300, 2200));
      expect(find.text('Trip reports'), findsOneWidget);
      expect(find.byKey(const ValueKey('category-Safety')), findsOneWidget);
      expect(find.byKey(const ValueKey('category-Old one')), findsNothing, reason: 'removed ones are kept, not listed');
      expect(find.text('Shows the SOS reminder'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('category-priority-Fare')));
      expect(repo.savedCategories.single.urgent, isTrue);

      expect(find.text('Default (everywhere else)'), findsOneWidget);
      expect(find.textContaining('Insurer: Contoh Takaful'), findsOneWidget);
      expect(find.byKey(const ValueKey('ride-safety-limits')), findsOneWidget);

      await _tap(tester, find.byTooltip('Raise Riders can report up to'));
      await _tap(tester, find.byKey(const ValueKey('filter-on-sort')));
      await _tap(tester, find.byKey(const ValueKey('ride-safety-permit')));
      await _tap(tester, find.byKey(const ValueKey('ride-safety-save')));
      expect(repo.savedSettings.single.reportWindowDays, 31);
      expect(repo.savedSettings.single.sortOn, isFalse);
      expect(repo.savedSettings.single.showDriverPermit, isFalse);
      await closeAnyNotice(tester);

      await _tap(tester, find.byTooltip('Edit Malaysia'));
      await tester.enterText(find.byKey(const ValueKey('cover-hotline')), '1-300-00-0000');
      await tester.pump();
      await _tap(tester, find.byKey(const ValueKey('cover-save')));
      expect(repo.savedRules.single.hotline, '1-300-00-0000');
      expect(repo.savedRules.single.country, 'Malaysia');
    });
  }
}
