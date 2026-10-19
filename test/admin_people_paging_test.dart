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

void main() {
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
      expect(find.text('200 of the first 200'), findsOneWidget);

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
