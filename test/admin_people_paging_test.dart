// PERF-55: the admin users list and the Add Partner user picker read
// `profiles` a page at a time, search the server for rows not loaded yet,
// and offer "Load more" (lib/src/admin/people_paging.dart).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_filters.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_repository.dart';
import 'package:get_ride/src/admin/screens/people/partner_screens.dart';
import 'package:get_ride/src/admin/screens/people/people_data.dart';
import 'package:get_ride/src/admin/screens/people_screens.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

Map<String, dynamic> _user(int i) => {'id': 'u$i', 'name': 'User $i', 'phone': '+6010$i', 'profile_status': 'approved'};

/// [n] users on the server; answers each request the way the repository asks.
class _Admin extends AdminRepository {
  _Admin(this.n) : super(_db);
  final int n;
  final asked = <({int limit, String query})>[];

  @override
  Future<RowsPage> users({int limit = adminPeoplePageSize, String query = ''}) async {
    asked.add((limit: limit, query: query));
    final all = [for (var i = 0; i < n; i++) _user(i)]
        .where((u) => query.isEmpty || rowSearch(u, query, userSearchColumns))
        .toList();
    return rowsPage(all.take(limit + 1).toList(), limit);
  }
}

/// [n] app users for the Add Partner picker, none of them a partner yet.
class _People extends PeopleRepository {
  _People(this.n) : super(_db);
  final int n;
  final asked = <({int limit, String query})>[];

  @override
  Future<RowsPage> profiles({int limit = adminPeoplePageSize, String query = ''}) async {
    asked.add((limit: limit, query: query));
    final all = [for (var i = 0; i < n; i++) _user(i)];
    return rowsPage(all.take(limit + 1).toList(), limit);
  }

  @override
  Future<List<Map<String, dynamic>>> partners() async => const [];
}

Future<_Admin> _users(WidgetTester tester, Size size, Brightness b, {int n = 450}) async {
  final admin = _Admin(n);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      supabaseProvider.overrideWithValue(_db),
      ...quietLiveOverrides,
      adminAccessProvider.overrideWith((_) async => AdminAccess([AdminGrant(page: '*', edit: true)])),
      adminRepositoryProvider.overrideWithValue(admin),
    ],
    child: MaterialApp(theme: appTheme(b), home: const AdminUsersScreen()),
  ));
  await tester.pumpAndSettle();
  return admin;
}

void main() {
  test('page size by width, and the count wording', () {
    expect(adminPeoplePageSizeFor(360), adminPeopleNarrowPageSize);
    expect(adminPeoplePageSizeFor(599), 50);
    expect(adminPeoplePageSizeFor(600), adminPeoplePageSize);
    expect(pagedCountLabel(shown: 200, loaded: 200, more: true, filtered: false), 'Showing the newest 200');
    expect(pagedCountLabel(shown: 12, loaded: 200, more: true, filtered: true), '12 matches among the first 200 loaded');
    expect(pagedCountLabel(shown: 1, loaded: 50, more: true, filtered: true), '1 match among the first 50 loaded');
    expect(pagedCountLabel(shown: 7, loaded: 9, more: false, filtered: true), '7 of 9');
  });

  // Desktop tester 137: wording, and Load more in reach on a phone.
  for (final b in Brightness.values) {
    testWidgets('360 wide: 50 a page, the count and Load more pinned in view (${b.name})', (tester) async {
      final admin = await _users(tester, const Size(360, 740), b);
      expect(admin.asked.single, (limit: 50, query: ''));
      expect(find.text('Showing the newest 50'), findsOneWidget);
      final more = find.byKey(const ValueKey('load-more'));
      expect(more.hitTestable(), findsOneWidget, reason: 'no scrolling to reach it');
      final bar = tester.getRect(find.byKey(const ValueKey('paged-bar')));
      expect(bar.bottom, lessThanOrEqualTo(740));
      // Scrolled into the list, the bar stays put.
      await tester.drag(find.byType(ListView).first, const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(const ValueKey('paged-bar'))), bar);
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(admin.asked.last, (limit: 100, query: ''));
      expect(find.text('Showing the newest 100'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('desktop: 200 a page; a filter says matches among the loaded (${b.name})', (tester) async {
      final admin = await _users(tester, const Size(1366, 768), b);
      expect(admin.asked.single, (limit: 200, query: ''));
      expect(find.text('Showing the newest 200'), findsOneWidget);
      expect(find.byKey(const ValueKey('load-more')).hitTestable(), findsOneWidget);
      // The loaded rows are filtered at once, before the server search.
      await tester.enterText(find.byType(TextField).first, 'User 19');
      await tester.pump(const Duration(milliseconds: 50));
      // User 19 and User 190 to 199.
      expect(find.text('11 matches among the first 200 loaded'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(admin.asked.last, (limit: 200, query: 'User 19'));
      expect(find.text('11 of 11'), findsOneWidget, reason: 'the server search found them all');
      expect(find.byKey(const ValueKey('paged-bar')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    for (final size in const [Size(360, 740), Size(1366, 768)]) {
      testWidgets('Add Partner picker pages the same way at ${size.width.toInt()} (${b.name})', (tester) async {
        final people = _People(300);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(ProviderScope(
          overrides: [
            supabaseProvider.overrideWithValue(_db),
            ...quietLiveOverrides,
            adminAccessProvider.overrideWith((_) async => AdminAccess([AdminGrant(page: '*', edit: true)])),
            peopleRepositoryProvider.overrideWithValue(people),
          ],
          child: MaterialApp(theme: appTheme(b), home: const PartnerAddScreen()),
        ));
        await tester.pumpAndSettle();
        final page = size.width < 600 ? 50 : 200;
        expect(people.asked.single, (limit: page, query: ''));
        expect(find.text('$page eligible users among the newest loaded'), findsOneWidget);
        final more = find.byKey(const ValueKey('load-more'));
        expect(more.hitTestable(), findsOneWidget);
        await tester.tap(more);
        await tester.pumpAndSettle();
        expect(people.asked.last.limit, 2 * page);
        expect(tester.takeException(), isNull);
      });
    }
  }

  group('the query', () {
    late List<http.Request> seen;
    late SupabaseClient db;
    setUp(() {
      seen = [];
      db = SupabaseClient(
        'http://localhost',
        'anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((r) async {
          seen.add(r);
          final limit = int.parse(r.url.queryParameters['limit']!);
          // A full table: one row more than asked for each time.
          final rows = [for (var i = 0; i < limit; i++) _user(i)];
          return http.Response(jsonEncode(rows), 200, request: r, headers: {'content-type': 'application/json'});
        }),
      );
    });
    tearDown(() => db.dispose());

    test('users: a page and one row more, never the whole table', () async {
      final page = await AdminRepository(db).users();
      final q = seen.single.url.queryParameters;
      expect(q['offset'], '0');
      expect(q['limit'], '${adminPeoplePageSize + 1}');
      expect(q['order'], 'joined_at.desc.nullslast,id.desc.nullslast');
      expect(q.containsKey('or'), isFalse);
      expect(page.rows, hasLength(adminPeoplePageSize));
      expect(page.more, isTrue);
    });

    test('users: a search goes to the server, made safe', () async {
      await AdminRepository(db).users(limit: 400, query: ' ab,c ');
      final q = seen.single.url.queryParameters;
      expect(q['limit'], '401');
      expect(q['or'], '(${userSearchColumns.map((c) => '$c.ilike.*ab c*').join(',')})');
    });

    test('Add Partner profiles: paged and searched the same way', () async {
      final page = await PeopleRepository(db).profiles(query: 'mia');
      final q = seen.single.url.queryParameters;
      expect(q['limit'], '${adminPeoplePageSize + 1}');
      expect(q['or'], '(name.ilike.*mia*,phone.ilike.*mia*,email.ilike.*mia*,ic.ilike.*mia*)');
      expect(page.more, isTrue);
    });
  });

  group('pages', () {
    test('the extra row only says there are more', () {
      final rows = [for (var i = 0; i < 4; i++) _user(i)];
      expect(rowsPage(rows, 3).rows, hasLength(3));
      expect(rowsPage(rows, 3).more, isTrue);
      expect(rowsPage(rows, 4).more, isFalse);
      expect(rowsPage(const [], 3), (rows: const <Map<String, dynamic>>[], more: false));
    });

    test('nothing to search on: no filter', () {
      expect(searchOrFilter('', userSearchColumns), isNull);
      expect(searchOrFilter(' a ', userSearchColumns), isNull, reason: 'one letter matches everyone');
      expect(searchOrFilter('*()', userSearchColumns), isNull);
      expect(searchOrFilter('Ali', ['name']), 'name.ilike.*Ali*');
    });
  });

  for (final b in Brightness.values) {
    testWidgets('users list: Load more, and a search reaches unloaded rows (${b.name})', (tester) async {
      final admin = _Admin(450);
      await tester.binding.setSurfaceSize(const Size(1000, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(ProviderScope(
        overrides: [
          supabaseProvider.overrideWithValue(_db),
          ...quietLiveOverrides,
          adminAccessProvider.overrideWith((_) async => AdminAccess([AdminGrant(page: '*', edit: false)])),
          adminRepositoryProvider.overrideWithValue(admin),
        ],
        child: MaterialApp(theme: appTheme(b), home: const AdminUsersScreen()),
      ));
      await tester.pumpAndSettle();
      expect(admin.asked.single, (limit: adminPeoplePageSize, query: ''));
      // Unfiltered: how many of the newest are loaded, not a search result.
      expect(find.text('Showing the newest 200'), findsOneWidget);
      expect(find.text('200 of the first 200'), findsNothing);

      final more = find.byKey(const ValueKey('load-more'));
      final list = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).last;
      await tester.scrollUntilVisible(more, 600, scrollable: list);
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(admin.asked.last, (limit: 2 * adminPeoplePageSize, query: ''));

      await tester.scrollUntilVisible(more, 600, scrollable: list);
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(admin.asked.last.limit, 3 * adminPeoplePageSize);
      expect(more, findsNothing, reason: 'all 450 loaded');
      await tester.scrollUntilVisible(find.text('450 of 450'), -3000, scrollable: list);
      expect(find.text('450 of 450'), findsOneWidget);

      // Back to page one for a search, sent once typing stops.
      final calls = admin.asked.length;
      await tester.enterText(find.byType(TextField).first, 'User 44');
      await tester.pump(const Duration(milliseconds: 100));
      expect(admin.asked, hasLength(calls), reason: 'not on every key');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(admin.asked.last, (limit: adminPeoplePageSize, query: 'User 44'));
      // User 44 and User 440 to 449.
      expect(find.text('11 of 11'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
