// Test traffic (migration 0241): Admin → Display Settings → Tester accounts,
// and the "Include test traffic" switch on the figures that leave the
// testers out (Fare AI response log, Maps usage).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/maps/maps_data.dart';
import 'package:get_ride/src/admin/screens/meterapp/test_accounts.dart';
import 'package:get_ride/src/admin/screens/security/fare_ai_screens.dart';
import 'package:get_ride/src/admin/screens/security/security_data.dart';
import 'package:get_ride/src/admin/test_traffic.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';

// No token refresh: its timer would outlive the test.
final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

String _id(int i) => '00000000-0000-0000-0000-${i.toString().padLeft(12, '0')}';

class _Store extends TestAccountsRepository {
  _Store(this.rows, {this.found = const []}) : super(_db);

  final List<TestAccount> rows;
  final List<Map<String, dynamic>> found;
  final added = <String>[];
  final removed = <String>[];
  final searched = <String>[];

  @override
  Future<List<TestAccount>> list() async => List.of(rows);

  @override
  Future<void> add(String profileId) async {
    added.add(profileId);
    final p = found.firstWhere((r) => r['id'] == profileId);
    rows.add(TestAccount(id: profileId, profile: p));
  }

  @override
  Future<void> remove(String profileId) async {
    removed.add(profileId);
    rows.removeWhere((a) => a.id == profileId);
  }

  @override
  Future<List<Map<String, dynamic>>> searchPeople(String query) async {
    searched.add(query);
    return found;
  }
}

TestAccount _tester(int i, String name) =>
    TestAccount(id: _id(i), profile: {'id': _id(i), 'name': name, 'phone': '6012000${i.toString().padLeft(4, '0')}'});

Future<void> _pumpCard(WidgetTester tester, _Store store, {required bool dark, bool edit = true}) async {
  await tester.binding.setSurfaceSize(const Size(700, 1800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        supabaseProvider.overrideWithValue(_db),
        ...quietLiveOverrides,
        testAccountsRepositoryProvider.overrideWithValue(store),
      ],
      child: MaterialApp(
        theme: appTheme(dark ? Brightness.dark : Brightness.light),
        home: Scaffold(body: ListView(children: [TestAccountsCard(canEdit: edit)])),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _Security implements SecurityRepository {
  final asked = <bool>[];

  @override
  Future<List<Map<String, dynamic>>> fareAiResponses({int limit = 150, bool includeTest = false}) async {
    asked.add(includeTest);
    return [
      {'id': 'r', 'provider': 'gemini', 'success': true, 'latency_ms': 900, 'distance_km': 12, 'duration_min': 20},
      if (includeTest)
        {'id': 't', 'provider': 'gemini', 'success': false, 'latency_ms': 4000, 'error': 'from a tester'},
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';

    testWidgets('lists the testers and removes one ($mode)', (tester) async {
      final store = _Store([_tester(1, 'Claude Tester'), _tester(2, 'QA Driver')]);
      await _pumpCard(tester, store, dark: dark);

      expect(find.text('Tester accounts (2)'), findsOneWidget);
      expect(find.text('Claude Tester'), findsOneWidget);
      expect(find.text('QA Driver'), findsOneWidget);
      // Few rows: no search box yet.
      expect(find.byKey(const ValueKey('test-accounts-filter')), findsNothing);

      await tester.tap(find.byKey(ValueKey('test-account-remove-${_id(1)}')));
      await tester.pumpAndSettle();
      expect(store.removed, [_id(1)]);
      expect(find.text('Claude Tester'), findsNothing);
      expect(find.text('Tester accounts (1)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a long list can be searched ($mode)', (tester) async {
      final store = _Store([for (var i = 1; i <= 9; i++) _tester(i, 'Tester $i')]);
      await _pumpCard(tester, store, dark: dark);

      final field = find.byKey(const ValueKey('test-accounts-filter'));
      expect(field, findsOneWidget);
      await tester.enterText(field, 'Tester 7');
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('test-account-${_id(7)}')), findsOneWidget);
      expect(find.byKey(ValueKey('test-account-${_id(3)}')), findsNothing);

      // By phone too.
      await tester.enterText(field, '60120000003');
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('test-account-${_id(3)}')), findsOneWidget);
      expect(find.byKey(ValueKey('test-account-${_id(7)}')), findsNothing);
    });

    testWidgets('adds a tester from the people search ($mode)', (tester) async {
      final store = _Store(
        [_tester(1, 'Claude Tester')],
        found: [
          {'id': _id(1), 'name': 'Claude Tester', 'phone': '60120000001'},
          {'id': _id(5), 'name': 'New Tester', 'email': 'new@example.com'},
        ],
      );
      await _pumpCard(tester, store, dark: dark);

      await tester.tap(find.byKey(const ValueKey('test-accounts-add')));
      await tester.pumpAndSettle();
      expect(find.text('Add tester account'), findsOneWidget);

      // Too short to search.
      await tester.enterText(find.byKey(const ValueKey('test-account-search')), 'n');
      await tester.tap(find.byKey(const ValueKey('test-account-find')));
      await tester.pumpAndSettle();
      expect(find.text('Type at least two characters.'), findsOneWidget);
      expect(store.searched, isEmpty);

      await tester.enterText(find.byKey(const ValueKey('test-account-search')), 'tester');
      await tester.tap(find.byKey(const ValueKey('test-account-find')));
      await tester.pumpAndSettle();
      expect(store.searched, ['tester']);
      // Already listed: shown ticked, not tappable.
      final listed = tester.widget<ListTile>(find.byKey(ValueKey('test-account-pick-${_id(1)}')));
      expect(listed.onTap, isNull);

      await tester.tap(find.byKey(ValueKey('test-account-pick-${_id(5)}')));
      await tester.pumpAndSettle();
      expect(store.added, [_id(5)]);
      expect(tester.widget<ListTile>(find.byKey(ValueKey('test-account-pick-${_id(5)}'))).onTap, isNull);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Tester accounts (2)'), findsOneWidget);
      expect(find.text('New Tester'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('read-only admins see the list without add or remove ($mode)', (tester) async {
      await _pumpCard(tester, _Store([_tester(1, 'Claude Tester')]), dark: dark, edit: false);
      expect(find.text('Claude Tester'), findsOneWidget);
      expect(find.byKey(const ValueKey('test-accounts-add')), findsNothing);
      expect(find.byKey(ValueKey('test-account-remove-${_id(1)}')), findsNothing);
    });

    testWidgets('an empty list says every call is real ($mode)', (tester) async {
      await _pumpCard(tester, _Store([]), dark: dark);
      expect(find.byKey(const ValueKey('test-accounts-empty')), findsOneWidget);
      expect(find.text('Tester accounts (0)'), findsOneWidget);
    });

    testWidgets('the Fare AI log shows real users unless test traffic is asked for ($mode)', (tester) async {
      final security = _Security();
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            supabaseProvider.overrideWithValue(_db),
            ...quietLiveOverrides,
            adminAccessProvider.overrideWith((_) async => AdminAccess([AdminGrant(page: '*', edit: true)])),
            securityRepositoryProvider.overrideWithValue(security),
          ],
          child: MaterialApp(
            theme: appTheme(dark ? Brightness.dark : Brightness.light),
            home: const AdminFareAiLogsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(security.asked, [false]);
      expect(find.text('1 records · 1 passed · 0 failed'), findsOneWidget);
      final toggle = find.byKey(const ValueKey('include-test-traffic'));
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      expect(find.textContaining('Real users only'), findsOneWidget);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(security.asked.last, isTrue);
      expect(find.text('2 records · 1 passed · 1 failed'), findsOneWidget);
      expect(find.text('from a tester'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  test('a map usage row reads its test calls; an older database has none', () {
    final row = MapUsageRow.fromRow({
      'provider': 'here',
      'kind': 'search',
      'calls': 10,
      'cached': 2,
      'failures': 1,
      'test_calls': 4,
    });
    expect(row.calls, 10);
    expect(row.testCalls, 4);
    expect(MapUsageRow.fromRow({'provider': 'here', 'kind': 'search', 'calls': 3}).testCalls, 0);
  });

  test('a tester row is labelled by name, else phone, email or id', () {
    final row = TestAccount.fromRow({
      'profile_id': _id(1),
      'note': null,
      'profile': {'id': _id(1), 'name': '', 'phone': '60123', 'email': 'a@b.c', 'display_id': 'GR1'},
    });
    expect(row.label, '60123');
    expect(row.details, 'GR1 · 60123 · a@b.c');
    final bare = TestAccount.fromRow({'profile_id': _id(2), 'profile': null});
    expect(bare.label, _id(2));
    expect(bare.details, _id(2));
  });
}
