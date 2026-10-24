import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_repository.dart';
import 'package:get_ride/src/admin/screens/commission_screen.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/commission_settings.dart';
import 'package:get_ride/src/features/partner/driver_wallet_pills.dart' show creditBlocked;
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/common.dart' show errorText;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';
import 'notice.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

class _Admin extends AdminRepository {
  _Admin() : super(_db);

  CommissionConfig config = const CommissionConfig(baseSurcharges: ['Old name']);
  final savedConfigs = <CommissionConfig>[];
  List<CommissionTier> tiers = [
    const CommissionTier(id: 't1', name: 'Busy week', threshold: 50, adjust: 'minus', value: 0.02),
  ];
  final savedTiers = <CommissionTier>[];
  final deleted = <String>[];

  @override
  Future<CommissionConfig> commissionConfig() async => config;

  @override
  Future<CommissionConfig> saveCommissionConfig(CommissionConfig c) async {
    savedConfigs.add(c);
    return config = c;
  }

  @override
  Future<List<({String name, int trips})>> surchargeNamesSeen() async => const [(name: 'Airport', trips: 12)];

  @override
  Future<List<CommissionTier>> commissionTiers() async => tiers;

  @override
  Future<void> saveCommissionTier(CommissionTier t) async => savedTiers.add(t);

  @override
  Future<void> deleteCommissionTier(String id) async => deleted.add(id);

  @override
  Future<List<Map<String, dynamic>>> commissionRates() async => const [];

  @override
  Future<List<Map<String, dynamic>>> unchargedCommissions() async => const [];
}

Future<_Admin> _pump(WidgetTester tester, {Brightness brightness = Brightness.light, bool edit = true}) async {
  final admin = _Admin();
  await tester.binding.setSurfaceSize(const Size(900, 1800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        supabaseProvider.overrideWithValue(_db),
        ...quietLiveOverrides,
        adminAccessProvider.overrideWith((_) async => AdminAccess([AdminGrant(page: '*', edit: edit)])),
        adminRepositoryProvider.overrideWithValue(admin),
      ],
      child: MaterialApp(theme: appTheme(brightness), home: const AdminCommissionScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return admin;
}

void main() {
  group('settings and tiers (logic)', () {
    test('the GET.credit floor: none, a limit, or zero', () {
      expect(const CommissionConfig().creditFloor, isNull, reason: 'as before: no limit');
      expect(const CommissionConfig(negativeLimit: 50).creditFloor, -50);
      expect(const CommissionConfig(allowNegativeCredit: false, negativeLimit: 50).creditFloor, 0);
      expect(creditBlocked(-60, -50), isTrue);
      expect(creditBlocked(-40, -50), isFalse);
      expect(creditBlocked(-0.01, 0), isTrue);
      expect(creditBlocked(-999, null), isFalse);
    });

    test('settings read back the same', () {
      final c = CommissionConfig.fromJson({
        'allowNegativeCredit': false,
        'negativeLimit': '25',
        'baseSurcharges': ['Airport', ' ', 'Luggage'],
        'baseTolls': true,
        'meterCommission': true,
      });
      expect(c.baseSurcharges, ['Airport', 'Luggage']);
      expect(c.negativeLimit, 25);
      expect(CommissionConfig.fromJson(c.toJson()), c);
      expect(CommissionConfig.fromJson(null), const CommissionConfig());
    });

    test('tiers: a set rate or points off; the lowest wins; a personal rate stays', () {
      const capped = CommissionTier(name: 'Top rated', metric: TierMetric.rating, threshold: 4.8, value: 0.12);
      const off = CommissionTier(name: 'Busy', threshold: 50, adjust: 'minus', value: 0.05);
      const offline = CommissionTier(name: 'Off', threshold: 0, value: 0.01, active: false);
      expect(capped.apply(0.20), 0.12);
      expect(capped.apply(0.10), 0.10, reason: 'never raises the rate');
      expect(off.apply(0.20), closeTo(0.15, 1e-9));
      expect(off.apply(0.03), 0);
      final best = applyCommissionTiers(0.20, 'city', [capped, off, offline]);
      expect(best.rate, 0.12);
      expect(best.tier, capped);
      expect(applyCommissionTiers(0.30, 'user', [capped]).rate, 0.30);
      expect(capped.condition, 'Rating 4.8+');
      expect(off.condition, '50+ completed trips in 7 days');
      expect(capped.effect, 'At most 12%');
      expect(off.effect, '5% off the rate');
      final row = CommissionTier.fromRow({
        'id': 'x', 'name': 'Hours', 'metric': 'online_hours', 'window_days': 30, 'threshold': '40',
        'adjust': 'rate', 'value': '0.1000', 'active': true,
      });
      expect(row.metric, TierMetric.onlineHours);
      expect(row.toRow()['metric'], 'online_hours');
      expect(row.condition, '40+ hours online in 30 days');
    });

    test('a database refusal named by code shows its hint', () {
      expect(
        errorText(const PostgrestException(message: 'GET_CREDIT_TOO_LOW', hint: 'Top up to take trips again.')),
        'Top up to take trips again.',
      );
      expect(errorText(const PostgrestException(message: 'Something else', hint: 'x')), 'Something else');
    });
  });

  for (final b in Brightness.values) {
    group('Admin → Commission (${b.name})', () {
      testWidgets('settings: below-zero limit, the base, the meter switch; saved', (tester) async {
        final admin = await _pump(tester, brightness: b);
        await tester.tap(find.byKey(const ValueKey('commission-tab-settings')));
        await tester.pumpAndSettle();
        expect(find.text('No limit (as before)'), findsOneWidget);

        await tester.enterText(find.byKey(const ValueKey('commission-negative-limit')), '50');
        await tester.pump();
        expect(find.text('Down to RM -50.00'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('commission-base-Airport')));
        await tester.tap(find.byKey(const ValueKey('commission-base-Old name')));
        await tester.tap(find.byKey(const ValueKey('commission-base-tolls')));
        await tester.pump();
        await tester.ensureVisible(find.byKey(const ValueKey('commission-meter')));
        await tester.tap(find.byKey(const ValueKey('commission-meter')));
        await tester.pump();
        await tester.ensureVisible(find.byKey(const ValueKey('commission-settings-save')));
        await tester.tap(find.byKey(const ValueKey('commission-settings-save')));
        await tester.pumpAndSettle();
        final c = admin.savedConfigs.single;
        expect(c.negativeLimit, 50);
        expect(c.baseSurcharges, ['Airport']);
        expect(c.baseTolls, isTrue);
        expect(c.baseOtherCharges, isFalse);
        expect(c.meterCommission, isTrue);

        await closeNotice(tester);
        // Not allowed below zero: the limit field goes.
        await tester.ensureVisible(find.byKey(const ValueKey('commission-allow-negative')));
        await tester.tap(find.byKey(const ValueKey('commission-allow-negative')));
        await tester.pump();
        expect(find.byKey(const ValueKey('commission-negative-limit')), findsNothing);
        expect(find.text('Drivers must keep RM 0 or more to take work'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('tiers: listed, added, turned off, deleted', (tester) async {
        final admin = await _pump(tester, brightness: b);
        await tester.tap(find.byKey(const ValueKey('commission-tab-tiers')));
        await tester.pumpAndSettle();
        expect(find.text('Busy week'), findsOneWidget);
        expect(find.textContaining('50+ completed trips in 7 days · 2% off the rate'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('commission-tier-add')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('tier-name')), 'Gold');
        await tester.tap(find.byKey(const ValueKey('tier-metric')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Rating (stars)').last);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('tier-window')), findsNothing, reason: 'a rating has no window');
        await tester.enterText(find.byKey(const ValueKey('tier-threshold')), '6');
        await tester.enterText(find.byKey(const ValueKey('tier-value')), '10');
        await tester.tap(find.byKey(const ValueKey('tier-save')));
        await tester.pumpAndSettle();
        expect(find.text('Ratings go up to 5'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('tier-threshold')), '4.8');
        await tester.tap(find.byKey(const ValueKey('tier-save')));
        await tester.pumpAndSettle();
        final t = admin.savedTiers.single;
        expect(t.name, 'Gold');
        expect(t.metric, TierMetric.rating);
        expect(t.threshold, 4.8);
        expect(t.value, 0.10);
        expect(t.position, 1);

        await closeNotice(tester);
        await tester.tap(find.byKey(const ValueKey('commission-tier-active-t1')));
        await tester.pumpAndSettle();
        expect(admin.savedTiers.last.active, isFalse);

        await tester.tap(find.byKey(const ValueKey('commission-tier-delete-t1')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        expect(admin.deleted, ['t1']);
        expect(tester.takeException(), isNull);
      });

      testWidgets('read-only admins change nothing', (tester) async {
        await _pump(tester, brightness: b, edit: false);
        await tester.tap(find.byKey(const ValueKey('commission-tab-settings')));
        await tester.pumpAndSettle();
        expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('commission-allow-negative'))).onChanged, isNull);
        await tester.tap(find.byKey(const ValueKey('commission-tab-tiers')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('commission-tier-add')), findsNothing);
        expect(find.byKey(const ValueKey('commission-tier-delete-t1')), findsNothing);
      });
    });
  }
}
