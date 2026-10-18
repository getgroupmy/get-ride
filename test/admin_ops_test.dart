// Batch 2 admin operations: sub-admin grants (lib/src/admin/sub_admin_grants.dart,
// screens/sub_admins_screen.dart) and document review (screens/documents_screen.dart).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_repository.dart';
import 'package:get_ride/src/admin/screens/documents_screen.dart';
import 'package:get_ride/src/admin/screens/sub_admins_screen.dart';
import 'package:get_ride/src/admin/profile_search.dart';
import 'package:get_ride/src/admin/sub_admin_grants.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

const _aina = {'id': 'p-aina', 'name': 'Aina', 'phone': '+60123456789', 'email': 'aina@x.my', 'display_id': 'GR1'};

class _Admin extends AdminRepository {
  _Admin({this.grants = const [], this.docs = const []}) : super(_db);
  final List<Map<String, dynamic>> grants;
  final List<Map<String, dynamic>> docs;
  final setCalls = <({String profileId, List<({String page, bool edit})> upserts, List<String> deletes, String? notes})>[];
  final searches = <String>[];
  final docPatches = <Map<String, dynamic>>[];
  final deleted = <String>[];

  @override
  Future<List<Map<String, dynamic>>> allGrants() async => grants;

  @override
  Future<Map<String, Map<String, dynamic>>> profilesByIds(Iterable<String> ids) async => {'p-aina': _aina};

  @override
  Future<List<Map<String, dynamic>>> searchPeople(String query, {int limit = 20}) async {
    searches.add(query);
    return [_aina];
  }

  @override
  Future<void> setGrants({
    required String profileId,
    required List<({String page, bool edit})> upserts,
    required List<String> deletes,
    String? notes,
  }) async =>
      setCalls.add((profileId: profileId, upserts: upserts, deletes: deletes, notes: notes));

  @override
  Future<List<Map<String, dynamic>>> documents(String table) async => docs;

  @override
  Future<({Map<String, Map<String, dynamic>> partners, Map<String, Map<String, dynamic>> vehicles})> documentOwners(
    Iterable<String> partnerIds,
    Iterable<String> vehicleIds,
  ) async =>
      (
        partners: {
          'pt1': {'id': 'pt1', 'name': 'Siti Driver'},
        },
        vehicles: {
          'v1': {'id': 'v1', 'plate': 'WXY 1'},
        },
      );

  @override
  Future<void> updateDocument(String table, String id, Map<String, dynamic> patch) async => docPatches.add(patch);

  @override
  Future<void> deleteDocument(String table, String id) async => deleted.add(id);
}

AdminGrant _g(String page, {bool edit = false, String? id, String? notes}) =>
    AdminGrant(page: page, edit: edit, id: id ?? 'g-$page', profileId: 'p-aina', notes: notes);

Future<GoRouter> _pump(
  WidgetTester tester,
  _Admin admin,
  Widget home, {
  Brightness b = Brightness.light,
  String initial = '/admin/sub-admins',
}) async {
  await tester.binding.setSurfaceSize(const Size(1000, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  // Grant access and Edit access are pages of their own under the list.
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(
        path: '/admin/sub-admins',
        builder: (_, _) => home,
        routes: [
          GoRoute(path: 'grant', builder: (_, _) => const GrantEditorPage()),
          GoRoute(path: ':id/edit', builder: (_, s) => GrantEditorPage(profileId: s.pathParameters['id'])),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      supabaseProvider.overrideWithValue(_db),
      ...quietLiveOverrides,
      adminAccessProvider.overrideWith((_) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
      adminRepositoryProvider.overrideWithValue(admin),
    ],
    child: MaterialApp.router(theme: appTheme(b), routerConfig: router),
  ));
  await tester.pumpAndSettle();
  return router;
}

void main() {
  group('grant changes', () {
    test('a level changes in place, a page taken away is deleted, an unchanged one is left', () {
      final plan = planGrantChanges(
        [_g('admin-users'), _g('admin-partners', edit: true), _g('admin-rides')],
        {
          'admin-users': GrantLevel.edit,
          'admin-partners': GrantLevel.none,
          'admin-rides': GrantLevel.read,
          'admin-vehicles': GrantLevel.read,
        },
      );
      expect(plan.upserts, [(page: 'admin-users', edit: true), (page: 'admin-vehicles', edit: false)]);
      expect(plan.deletes, ['g-admin-partners']);
    });

    test('a new note rewrites every page held', () {
      final plan = planGrantChanges([_g('admin-users')], {'admin-users': GrantLevel.read}, notes: ' Night shift ');
      expect(plan.upserts, [(page: 'admin-users', edit: false)]);
      expect(planGrantChanges([_g('admin-users', notes: 'Night shift')], {'admin-users': GrantLevel.read},
              notes: 'Night shift')
          .upserts, isEmpty);
    });

    test('set all leaves full admin alone', () {
      final all = setAllGrantLevels({'*': GrantLevel.none, 'a': GrantLevel.none, 'b': GrantLevel.edit}, GrantLevel.read);
      expect(all, {'*': GrantLevel.none, 'a': GrantLevel.read, 'b': GrantLevel.read});
    });

    test('the list matches by person, page label, note and level', () {
      bool m({String q = '', GrantFilter f = GrantFilter.all, String? page, List<AdminGrant>? grants}) =>
          grantPersonMatches(
            person: _aina,
            profileId: 'p-aina',
            grants: grants ?? [_g('admin-users', notes: 'Support team')],
            pageLabels: const {'admin-users': 'Users · admin-users'},
            query: q,
            filter: f,
            page: page,
          );
      expect(m(q: 'aina@'), isTrue);
      expect(m(q: '6012345'), isTrue);
      expect(m(q: 'users'), isTrue);
      expect(m(q: 'support'), isTrue);
      expect(m(q: 'nobody'), isFalse);
      expect(m(f: GrantFilter.edit), isFalse);
      expect(m(f: GrantFilter.read), isTrue);
      expect(m(page: 'admin-rides'), isFalse);
      expect(m(page: 'admin-rides', grants: [_g('*', edit: true)]), isTrue, reason: 'full admin covers every page');
    });

    test('a search term is safe inside a PostgREST or-filter', () {
      expect(peopleSearchTerm('a'), isNull);
      expect(peopleSearchTerm('ai,na).or(id'), 'ai na .or id');
      expect(peopleSearchTerm('  Siti  Aminah '), 'Siti Aminah');
      expect(isProfileUuid('0d7c6c4e-1a2b-4c3d-8e9f-0123456789ab'), isTrue);
      expect(isProfileUuid('aina'), isFalse);
    });
  });

  group('documents', () {
    test('rows know whose they are, and search by it', () {
      final d = withDocumentOwner(
        {'doc_name': 'Road tax', 'partner_id': 'pt1', 'vehicle_id': 'v1'},
        {
          'pt1': {'name': ' ', 'phone': '+6011'},
        },
        {
          'v1': {'plate': 'WXY 1'},
        },
      );
      expect(d['_owner'], '+6011');
      expect(d['_plate'], 'WXY 1');
      expect(documentMatches(d, 'wxy'), isTrue);
      expect(documentMatches(d, 'licence'), isFalse);
    });

    test('an edit clears blank fields and checks dates', () {
      final p = documentEditPatch(
          name: 'Road tax', number: ' ', insurer: '', country: 'MY', start: '', expiry: '2027-01-31', pwd: false);
      expect(p['document_number'], isNull);
      expect(p['expiry_date'], '2027-01-31');
      expect(documentDateError('31/01/2027'), 'Use YYYY-MM-DD');
      expect(documentDateError(''), isNull);
    });
  });

  for (final b in Brightness.values) {
    testWidgets('grant several pages at once, found by name (${b.name})', (tester) async {
      final admin = _Admin();
      await _pump(tester, admin, const AdminSubAdminsScreen(), b: b);
      await tester.tap(find.byKey(const ValueKey('grant-access')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('grant-person-search')), 'Aina');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(admin.searches, ['Aina']);
      await tester.tap(find.byKey(const ValueKey('grant-person-p-aina')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('grant-all-read')));
      await tester.enterText(find.byKey(const ValueKey('grant-notes')), 'Support team');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('grant-save')));
      await tester.pumpAndSettle();
      final call = admin.setCalls.single;
      expect(call.profileId, 'p-aina');
      expect(call.upserts.length, greaterThan(1), reason: 'every page, in one save');
      expect(call.upserts.every((u) => !u.edit), isTrue);
      expect(call.upserts.any((u) => u.page == '*'), isFalse);
      expect(call.notes, 'Support team');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('an existing grant is edited in place', (tester) async {
    final admin = _Admin(grants: [
      {'id': 'g1', 'profile_id': 'p-aina', 'page': '*', 'access_level': 'read'},
    ]);
    await _pump(tester, admin, const AdminSubAdminsScreen());
    expect(find.text('Aina'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sub-admin-edit-p-aina')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('grant-level-*')), matching: find.text('Edit')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('grant-save')));
    await tester.pumpAndSettle();
    expect(admin.setCalls.single.upserts, [(page: '*', edit: true)]);
    expect(admin.setCalls.single.deletes, isEmpty);
  });

  testWidgets('Edit access has an address of its own: a reload opens the same person', (tester) async {
    final admin = _Admin(grants: [
      {'id': 'g1', 'profile_id': 'p-aina', 'page': '*', 'access_level': 'read'},
    ]);
    await _pump(tester, admin, const AdminSubAdminsScreen());
    await tester.tap(find.byKey(const ValueKey('sub-admin-edit-p-aina')));
    await tester.pumpAndSettle();
    final at = GoRouterState.of(tester.element(find.byKey(const ValueKey('grant-save')))).uri.toString();
    expect(at, '/admin/sub-admins/p-aina/edit');
    expect(subAdminEditorPath(null), '/admin/sub-admins/grant');

    // Opened straight from that address (a reload): the same person.
    final router = await _pump(tester, admin, const AdminSubAdminsScreen(), initial: at);
    expect(find.text('Edit access'), findsOneWidget);
    expect(find.textContaining('Aina'), findsWidgets);
    // Saved there, it goes back to the list.
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('grant-level-*')), matching: find.text('Edit')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('grant-save')));
    await tester.pumpAndSettle();
    expect(admin.setCalls.last.upserts, [(page: '*', edit: true)]);
    expect(find.byKey(const ValueKey('grant-access')), findsOneWidget, reason: 'back on the list');
    expect(router.routerDelegate.currentConfiguration.uri.path, '/admin/sub-admins');
  });

  testWidgets('each None / View / Edit says whether it is the one chosen', (tester) async {
    final admin = _Admin(grants: [
      {'id': 'g1', 'profile_id': 'p-aina', 'page': '*', 'access_level': 'read'},
    ]);
    final semantics = tester.ensureSemantics();
    await _pump(tester, admin, const AdminSubAdminsScreen(), initial: '/admin/sub-admins/p-aina/edit');
    final all = grantablePages['*']!;
    expect(
      tester.getSemantics(find.bySemanticsLabel('$all: View')),
      isSemantics(isSelected: true, isInMutuallyExclusiveGroup: true, isButton: true),
    );
    expect(tester.getSemantics(find.bySemanticsLabel('$all: Edit')), isSemantics(isSelected: false));
    expect(tester.getSemantics(find.bySemanticsLabel('$all: None')), isSemantics(isSelected: false));
    semantics.dispose();
  });

  group('the document sheet', () {
    final doc = {
      'id': 'd1',
      'doc_name': 'Driving licence',
      'document_number': 'L123',
      'partner_id': 'pt1',
      'status': 'Pending Review',
      'expiry_date': '2030-01-01',
    };

    testWidgets('rows say whose document it is', (tester) async {
      await _pump(tester, _Admin(docs: [doc]), const AdminDocumentsScreen());
      expect(find.textContaining('Siti Driver'), findsOneWidget);
    });

    testWidgets('details are corrected in place', (tester) async {
      final admin = _Admin(docs: [doc]);
      await _pump(tester, admin, const AdminDocumentsScreen());
      await tester.tap(find.text('Driving licence'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('doc-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('doc-edit-expiry')), '2031-02-03');
      await tester.enterText(find.byKey(const ValueKey('doc-edit-number')), 'L999');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('doc-edit-save')));
      await tester.pumpAndSettle();
      expect(admin.docPatches.single['expiry_date'], '2031-02-03');
      expect(admin.docPatches.single['document_number'], 'L999');
    });

    testWidgets('a document is deleted after confirming', (tester) async {
      final admin = _Admin(docs: [doc]);
      await _pump(tester, admin, const AdminDocumentsScreen());
      await tester.tap(find.text('Driving licence'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('doc-delete')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Siti Driver'), findsWidgets);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(admin.deleted, ['d1']);
    });
  });
}
