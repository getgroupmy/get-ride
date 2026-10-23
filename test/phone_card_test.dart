// The admin Phone card (lib/src/admin/widgets/phone_card.dart) with a fake
// repository, in light and dark: a tab per phone, newest first, the groups
// and pills, "No phone details yet", and the link to the account's Session
// History, shown only to an admin who may open it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/phone_details_data.dart';
import 'package:get_ride/src/admin/widgets/phone_card.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/app_version.dart';
import 'package:get_ride/src/data/app_version_repository.dart';
import 'package:go_router/go_router.dart';

import 'quiet_live.dart';

class _FakePhones extends PhoneDetailsRepository {
  _FakePhones(this.sessions, [this.tokens = const []]) : super(null);
  final List<Map<String, dynamic>> sessions;
  final List<Map<String, dynamic>> tokens;
  final asked = <String>[];

  @override
  Future<({List<Map<String, dynamic>> sessions, List<Map<String, dynamic>> tokens})> load(String profileId) async {
    asked.add(profileId);
    return (sessions: sessions, tokens: tokens);
  }
}

final _ago = DateTime.now().toUtc().subtract(const Duration(minutes: 2)).toIso8601String();

final _sessions = [
  {
    'captured_at': _ago,
    'device_id': 'dev-ios',
    'os_name': 'ios',
    'os_version': 'iOS 18.6',
    'device_brand': 'Apple',
    'device_model_name': 'iPhone 15 Pro',
    'device_model_id': 'iPhone16,1',
    'is_physical_device': true,
    'app_version': '1.5.2',
    'app_build_version': '412',
    'network_type': 'cellular',
    'cellular_generation': '5G',
    'network_operator': 'CelcomDigi',
    'ip_city': 'Kajang',
    'ip_region': 'Selangor',
    'ip_country': 'MY',
    'raw': {
      'battery_pct': 62,
      'storage_free_bytes': 38000000000,
      'storage_total_bytes': 128000000000,
      'perm_location': 'always',
      'perm_notifications': true,
      'screen': '1179x2556',
      'pixel_ratio': 3,
      'locale': 'en-MY',
      'utc_offset_min': 480,
    },
  },
  {
    'captured_at': '2026-06-02T00:00:00Z',
    'device_id': 'dev-android',
    'os_name': 'android',
    'os_version': 'Android 15 (SDK 35)',
    'device_brand': 'samsung',
    'device_model_name': 'SM-A546E',
    'device_model_id': 'a54x',
    'is_physical_device': true,
    'app_version': '1.5.0',
    'app_build_version': '398',
    'network_type': 'wifi',
    'mobile_operator_name': 'Maxis',
    'raw': {
      'battery_pct': 14,
      'battery_charging': true,
      'perm_location': 'while_in_use',
      'perm_notifications': false,
    },
  },
];

const _rules = [AppVersionRule(platform: 'All', latest: '1.5.2')];

Future<_FakePhones> _pump(
  WidgetTester tester, {
  Brightness b = Brightness.light,
  List<Map<String, dynamic>> sessions = const [],
  List<AdminGrant> grants = const [AdminGrant(page: '*', edit: true)],
}) async {
  final repo = _FakePhones(sessions, const [
    {'platform': 'android', 'location_always': false, 'updated_at': '2026-06-02T00:00:00Z'},
  ]);
  final router = GoRouter(routes: [
    GoRoute(
      path: '/',
      builder: (_, _) => const Scaffold(body: SingleChildScrollView(child: PhoneCard(profileId: 'user-1'))),
    ),
    GoRoute(
      path: '/admin/m/session-history',
      builder: (_, s) => Scaffold(body: Text('history ${s.uri.queryParameters['q']}')),
    ),
  ]);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...quietLiveOverrides,
        adminAccessProvider.overrideWith((_) async => AdminAccess(grants)),
        appVersionRulesProvider.overrideWith((_) async => _rules),
        phoneDetailsRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp.router(theme: appTheme(b), routerConfig: router),
    ),
  );
  await tester.pump();
  await tester.pump();
  return repo;
}

void main() {
  for (final b in Brightness.values) {
    testWidgets('a tab per phone, newest first, in ${b.name}', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repo = await _pump(tester, b: b, sessions: _sessions);
      expect(repo.asked, ['user-1']);
      expect(find.text('iPhone 15 Pro'), findsOneWidget);
      expect(find.text('SM-A546E'), findsOneWidget);
      expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('phone-tab-0'))).selected, isTrue);
      expect(find.text('Apple iPhone 15 Pro'), findsOneWidget);
      expect(find.text('(iPhone16,1)'), findsOneWidget);
      expect(find.text('38 GB free of 128 GB'), findsOneWidget);
      expect(find.text('393 × 852 · 3×'), findsOneWidget);
      expect(find.text('en-MY · GMT+8'), findsOneWidget);
      expect(find.text('1.5.2 (412)'), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-pill-Latest')), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-pill-OK')), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-pill-Allowed')), findsOneWidget);
      expect(find.text('2 min ago'), findsOneWidget);
      expect(find.text('Mobile data · 5G'), findsOneWidget);
      expect(find.text('Kajang, Selangor, MY'), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-pill-Low')), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('phone-tab-1')));
      await tester.pump();
      expect(find.text('Samsung SM-A546E'), findsOneWidget);
      expect(find.text('1.5.0 (398)'), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-pill-Update available')), findsOneWidget);
      expect(find.text('While using the app'), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-pill-Needs Always')), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-pill-Off')), findsOneWidget, reason: 'its token: no Always on');
      expect(find.byKey(const ValueKey('phone-pill-Blocked')), findsOneWidget);
      expect(find.text('14% · charging'), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-pill-Low')), findsOneWidget);
      expect(find.text('Wi-Fi'), findsOneWidget);
      expect(find.text('Maxis (SIM)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('on a phone, nothing overflows, in ${b.name}', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pump(tester, b: b, sessions: _sessions);
      expect(find.text('Battery & network (at last report)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('nothing recorded: No phone details yet', (tester) async {
    await _pump(tester);
    expect(find.byKey(const ValueKey('phone-none')), findsOneWidget);
    expect(find.text('No phone details yet'), findsOneWidget);
  });

  testWidgets("the link opens the account's Session History", (tester) async {
    await _pump(tester, sessions: _sessions);
    await tester.ensureVisible(find.byKey(const ValueKey('phone-session-history')));
    await tester.tap(find.byKey(const ValueKey('phone-session-history')));
    await tester.pumpAndSettle();
    expect(find.text('history user-1'), findsOneWidget);
  });

  testWidgets('no link for an admin who may not open Session History', (tester) async {
    await _pump(tester, sessions: _sessions, grants: const [AdminGrant(page: 'admin-user-edit', edit: true)]);
    expect(find.byKey(const ValueKey('phone-session-history')), findsNothing);
    expect(find.byKey(const ValueKey('phone-card')), findsOneWidget);
  });
}
