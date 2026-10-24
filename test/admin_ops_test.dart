// Batch 2 admin operations: sub-admin grants (lib/src/admin/sub_admin_grants.dart,
// screens/sub_admins_screen.dart) and document review (screens/documents_screen.dart).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_repository.dart';
import 'package:get_ride/src/admin/god_view_people.dart';
import 'package:get_ride/src/admin/screens/documents_screen.dart';
import 'package:get_ride/src/admin/screens/sub_admins_screen.dart';
import 'package:get_ride/src/admin/profile_search.dart';
import 'package:get_ride/src/admin/sub_admin_grants.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/data/identity_repository.dart';
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
    return found;
  }

  /// What a people search finds.
  List<Map<String, dynamic>> found = const [_aina];

  // God View: who the grant shows (0285).
  GodViewPeople godPeople = GodViewPeople.none;
  bool failPeopleRead = false;
  Set<String> partnerIds = const {};
  final peopleReads = <String>[];
  final peopleSaves = <(String, GodViewPeople)>[];

  @override
  Future<GodViewPeople> godViewPeople(String profileId) async {
    peopleReads.add(profileId);
    if (failPeopleRead) throw Exception('offline');
    return godPeople;
  }

  @override
  Future<void> saveGodViewPeople(String profileId, GodViewPeople people) async => peopleSaves.add((profileId, people));

  @override
  Future<Set<String>> partnerProfileIds(Iterable<String> ids) async => {for (final i in ids) if (partnerIds.contains(i)) i};

  @override
  Future<void> setGrants({
    required String profileId,
    required List<({String page, bool edit})> upserts,
    required List<String> deletes,
    String? notes,
    Map<String, Map<String, dynamic>?> regions = const {},
  }) async {
    setCalls.add((profileId: profileId, upserts: upserts, deletes: deletes, notes: notes));
    regionCalls.add(regions);
  }

  final regionCalls = <Map<String, Map<String, dynamic>?>>[];

  @override
  Future<List<Map<String, dynamic>>> documents(String table) async => docs;

  /// Face matches by document id (0288).
  Map<String, Map<String, dynamic>> faces = const {};

  @override
  Future<Map<String, Map<String, dynamic>>> documentFaceChecks(String kind, Iterable<String> ids) async => faces;

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
  Size size = const Size(1000, 1600),
  double textScale = 1,
  List<Override> extra = const [],
}) async {
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.binding.setSurfaceSize(size);
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
      ...extra,
    ],
    child: MaterialApp.router(
      theme: appTheme(b),
      routerConfig: router,
      builder: (_, child) => RepaintBoundary(key: _screen, child: child),
    ),
  ));
  await tester.pumpAndSettle();
  return router;
}

/// The whole app, for a screenshot.
final _screen = GlobalKey();

/// With `--dart-define=GV_PEOPLE_SHOTS=<dir>`: where [_shoot] saves PNGs.
const _shotsDir = String.fromEnvironment('GV_PEOPLE_SHOTS');

/// Real letters and icons for the screenshots (tests draw boxes otherwise),
/// from the Flutter SDK's own fonts. Only when shots are asked for, so the
/// other tests keep the test font's sizes.
Future<void> _loadShotFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'] ?? '';
  final dir = '$root/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final file = File('$dir/$f');
      if (file.existsSync()) loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await loader.load();
  }
  await load('Roboto', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']);
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
}

/// Saves the screen as `<dir>/<name>.png` when [_shotsDir] is set.
Future<void> _shoot(WidgetTester tester, String name) async {
  if (_shotsDir.isEmpty) return;
  final boundary = _screen.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    File('$_shotsDir/$name.png').writeAsBytesSync(png.buffer.asUint8List());
    image.dispose();
  });
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
    testWidgets('the search hint fits at 1.3x on a 412 phone; what it searches stays under it (${b.name})',
        (tester) async {
      await _pump(tester, _Admin(), const AdminSubAdminsScreen(), b: b, size: const Size(412, 915), textScale: 1.3);
      final field = tester.widget<TextField>(find.byKey(const ValueKey('sub-admin-search')));
      expect(field.decoration?.hintText, 'Search sub-admins');
      expect(field.decoration?.helperText, 'Name, phone, email, page or note');
      // (The test font draws every letter a full em wide, so the fit itself
      // is judged by the length: under 20 letters fits a phone at 1.3x.)
      expect(field.decoration!.hintText!.length, lessThan(20));
      expect(tester.takeException(), isNull);
    });

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

  testWidgets('a God View grant keeps its region, saved with the grant', (tester) async {
    final admin = _Admin(grants: [
      {
        'id': 'g1',
        'profile_id': 'p-aina',
        'page': godViewPage,
        'access_level': 'read',
        'region': {'country': 'Malaysia', 'state': 'Selangor'},
      },
    ]);
    await _pump(tester, admin, const AdminSubAdminsScreen());
    await tester.tap(find.byKey(const ValueKey('sub-admin-edit-p-aina')));
    await tester.pumpAndSettle();
    await tester.enterText(find.ancestor(of: find.text('Filter pages'), matching: find.byType(TextField)), 'god');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('grant-god-view-region')), findsOneWidget);
    expect(find.text('Selangor, Malaysia'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('grant-notes')), 'Selangor ops');
    await tester.tap(find.byKey(const ValueKey('grant-save')));
    await tester.pumpAndSettle();
    expect(admin.regionCalls.single[godViewPage]?['state'], 'Selangor');
    expect(admin.regionCalls.single[godViewPage]?['country'], 'Malaysia');
  });

  for (final b in Brightness.values) {
    testWidgets('God View Everywhere: turned on, saved as everywhere; loaded back on (0284, ${b.name})', (tester) async {
      final admin = _Admin(grants: [
        {'id': 'g1', 'profile_id': 'p-aina', 'page': godViewPage, 'access_level': 'read', 'region': null},
      ]);
      await _pump(tester, admin, const AdminSubAdminsScreen(), b: b);
      await tester.tap(find.byKey(const ValueKey('sub-admin-edit-p-aina')));
      await tester.pumpAndSettle();
      await tester.enterText(find.ancestor(of: find.text('Filter pages'), matching: find.byType(TextField)), 'god');
      await tester.pumpAndSettle();
      expect(find.text('Not set: they see nobody on God View until you pick one'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('grant-god-view-everywhere')));
      await tester.tap(find.byKey(const ValueKey('grant-god-view-everywhere')));
      await tester.pumpAndSettle();
      expect(find.text('Everywhere: they see everyone on God View'), findsOneWidget);
      expect(find.text('Pick'), findsNothing, reason: 'no region to pick while Everywhere is on');
      await tester.tap(find.byKey(const ValueKey('grant-save')));
      await tester.pumpAndSettle();
      expect(admin.regionCalls.single[godViewPage], {'everywhere': true});
      expect(tester.takeException(), isNull);
    });
  }

  group('God View: who they see (0285)', () {
    const siti = {'id': 'p-siti', 'name': 'Siti', 'phone': '+60111234321', 'display_id': 'GR7'};
    const hafiz = {'id': 'p-hafiz', 'name': 'Hafiz', 'phone': '+60135557777', 'display_id': 'GP3'};
    Map<String, dynamic> gv([Map<String, dynamic>? region]) =>
        {'id': 'g1', 'profile_id': 'p-aina', 'page': godViewPage, 'access_level': 'read', 'region': region};

    Future<void> openGodView(WidgetTester tester, _Admin admin, Brightness b, {Size size = const Size(1000, 1600)}) async {
      await _pump(tester, admin, const AdminSubAdminsScreen(), b: b, size: size);
      await tester.tap(find.byKey(const ValueKey('sub-admin-edit-p-aina')));
      await tester.pumpAndSettle();
      await tester.enterText(find.ancestor(of: find.text('Filter pages'), matching: find.byType(TextField)), 'god');
      await tester.pumpAndSettle();
    }

    Future<void> add(WidgetTester tester, String list, String query, String id) async {
      await tester.ensureVisible(find.byKey(ValueKey('grant-god-view-$list-add')));
      await tester.tap(find.byKey(ValueKey('grant-god-view-$list-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('gv-person-search')), query);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('gv-person-result-$id')));
      await tester.pumpAndSettle();
    }

    for (final b in Brightness.values) {
      testWidgets('Nobody: no region to pick, saved after the grant (${b.name})', (tester) async {
        final admin = _Admin(grants: [gv({'country': 'Malaysia'})]);
        await openGodView(tester, admin, b);
        expect(admin.peopleReads, ['p-aina']);
        expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('grant-god-view-mode-region'))).selected, isTrue);
        expect(find.byKey(const ValueKey('grant-god-view-region')), findsOneWidget);
        expect(find.byKey(const ValueKey('grant-god-view-hide-add')), findsOneWidget);
        await tester.ensureVisible(find.byKey(const ValueKey('grant-god-view-mode-nobody')));
        await tester.tap(find.byKey(const ValueKey('grant-god-view-mode-nobody')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('grant-god-view-region')), findsNothing);
        expect(find.byKey(const ValueKey('grant-god-view-everywhere')), findsNothing);
        expect(find.byKey(const ValueKey('grant-god-view-hide-add')), findsNothing);
        expect(find.text('Nobody: they keep the God View page but see no one on it'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('grant-save')));
        await tester.pumpAndSettle();
        expect(admin.peopleSaves.single.$1, 'p-aina');
        expect(admin.peopleSaves.single.$2.mode, GodViewPeopleMode.nobody);
        // The region is kept on the grant, for when they go back to Region.
        expect(admin.regionCalls.single[godViewPage], {'country': 'Malaysia'});
        expect(tester.takeException(), isNull);
      });

      testWidgets('Only these people: add a partner and a user, remove one, save the list (${b.name})', (tester) async {
        final admin = _Admin(grants: [gv()])
          ..found = const [siti, hafiz]
          ..partnerIds = const {'p-hafiz'};
        await openGodView(tester, admin, b);
        await tester.ensureVisible(find.byKey(const ValueKey('grant-god-view-mode-only')));
        await tester.tap(find.byKey(const ValueKey('grant-god-view-mode-only')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('grant-god-view-region')), findsNothing);
        expect(find.text('No one listed: they see no one until you add someone.'), findsOneWidget);
        await add(tester, 'only', 'ha', 'p-hafiz');
        expect(admin.searches.last, 'ha');
        final row = find.byKey(const ValueKey('grant-god-view-only-p-hafiz'));
        expect(row, findsOneWidget);
        expect(find.descendant(of: row, matching: find.text('Partner')), findsOneWidget);
        expect(find.descendant(of: row, matching: find.textContaining('+6013•••7777')), findsOneWidget);
        expect(find.descendant(of: row, matching: find.textContaining('5557')), findsNothing, reason: 'the phone is masked');
        await add(tester, 'only', 'si', 'p-siti');
        expect(find.descendant(of: find.byKey(const ValueKey('grant-god-view-only-p-siti')), matching: find.text('User')),
            findsOneWidget);
        expect(find.text('Only 2 people'), findsOneWidget);
        // Someone already listed can't be added twice.
        await tester.tap(find.byKey(const ValueKey('grant-god-view-only-add')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('gv-person-search')), 'si');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expect(tester.widget<ListTile>(find.byKey(const ValueKey('gv-person-result-p-siti'))).enabled, isFalse);
        expect(find.textContaining('Already listed'), findsWidgets);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('grant-god-view-only-remove-p-siti')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('grant-god-view-only-p-siti')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('grant-save')));
        await tester.pumpAndSettle();
        final saved = admin.peopleSaves.single.$2;
        expect(saved.mode, GodViewPeopleMode.only);
        expect(saved.only.map((p) => p.id), ['p-hafiz']);
        expect(saved.hide, isEmpty);
        expect(tester.takeException(), isNull);
      });

      testWidgets('Hide these people: the saved list opens, one removed, Everywhere kept (${b.name})', (tester) async {
        final admin = _Admin(grants: [gv({'everywhere': true})])
          ..godPeople = const GodViewPeople(hide: [
            GodViewListedPerson(id: 'p-siti', name: 'Siti', phone: '+60111234321'),
            GodViewListedPerson(id: 'p-hafiz', name: 'Hafiz', phone: '+60135557777', partner: true),
          ]);
        await openGodView(tester, admin, b);
        expect(find.byKey(const ValueKey('grant-god-view-hide-p-siti')), findsOneWidget);
        expect(find.byKey(const ValueKey('grant-god-view-hide-p-hafiz')), findsOneWidget);
        expect(find.text('Everyone in their region but 2 people'), findsOneWidget);
        await tester.ensureVisible(find.byKey(const ValueKey('grant-god-view-hide-remove-p-hafiz')));
        await tester.tap(find.byKey(const ValueKey('grant-god-view-hide-remove-p-hafiz')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('grant-save')));
        await tester.pumpAndSettle();
        final saved = admin.peopleSaves.single.$2;
        expect(saved.mode, GodViewPeopleMode.region);
        expect(saved.hide.map((p) => p.id), ['p-siti']);
        expect(admin.regionCalls.single[godViewPage], {'everywhere': true});
        expect(tester.takeException(), isNull);
      });
    }

    // On a phone, light and dark: the lists fit, with the person's kind and
    // remove button beside a long name.
    group('at phone width', () {
      setUpAll(() async {
        if (_shotsDir.isNotEmpty) await _loadShotFonts();
      });
      const phone = Size(390, 844);
      const listed = [
        GodViewListedPerson(id: 'p-siti', name: 'Siti Nurhaliza binti Abdullah', phone: '+60111234321', displayId: 'GR7'),
        GodViewListedPerson(id: 'p-hafiz', name: 'Hafiz', phone: '+60135557777', displayId: 'GP3', partner: true),
        GodViewListedPerson(id: 'p-mei', name: 'Mei Ling', phone: '+60172223333', displayId: 'GR9'),
      ];

      for (final b in Brightness.values) {
        testWidgets('Only these people (${b.name})', (tester) async {
          final admin = _Admin(grants: [gv({'country': 'Malaysia'})])
            ..godPeople = const GodViewPeople(mode: GodViewPeopleMode.only, only: listed);
          await openGodView(tester, admin, b, size: phone);
          await tester.ensureVisible(find.byKey(const ValueKey('grant-god-view-mode-region')));
          await tester.pumpAndSettle();
          await tester.drag(find.byType(Scrollable).first, const Offset(0, -120));
          await tester.pumpAndSettle();
          expect(find.text('Only 3 people'), findsOneWidget);
          for (final p in listed) {
            expect(find.byKey(ValueKey('grant-god-view-only-${p.id}')), findsOneWidget);
          }
          expect(find.byKey(const ValueKey('grant-god-view-region')), findsNothing);
          expect(tester.getRect(find.byKey(const ValueKey('grant-god-view-only-remove-p-siti'))).right,
              lessThanOrEqualTo(phone.width));
          await _shoot(tester, 'gv_people_only_${b.name}');
          expect(tester.takeException(), isNull);
        });

        testWidgets('Region with a hide list (${b.name})', (tester) async {
          final admin = _Admin(grants: [gv({'country': 'Malaysia', 'state': 'Selangor'})])
            ..godPeople = GodViewPeople(hide: listed.take(2).toList());
          await openGodView(tester, admin, b, size: phone);
          await tester.ensureVisible(find.byKey(const ValueKey('grant-god-view-hide-add')));
          await tester.pumpAndSettle();
          expect(find.text('Everyone in their region but 2 people'), findsOneWidget);
          expect(find.byKey(const ValueKey('grant-god-view-hide-p-hafiz')), findsOneWidget);
          await _shoot(tester, 'gv_people_hide_${b.name}');
          expect(tester.takeException(), isNull);
        });

        testWidgets('the add dialog (${b.name})', (tester) async {
          final admin = _Admin(grants: [gv()])
            ..found = const [
              {'id': 'p-siti', 'name': 'Siti', 'phone': '+60111234321', 'display_id': 'GR7'},
              {'id': 'p-hafiz', 'name': 'Hafiz', 'phone': '+60135557777', 'display_id': 'GP3'},
            ]
            ..partnerIds = const {'p-hafiz'}
            ..godPeople = const GodViewPeople(hide: [GodViewListedPerson(id: 'p-siti', name: 'Siti')]);
          await openGodView(tester, admin, b, size: phone);
          await tester.ensureVisible(find.byKey(const ValueKey('grant-god-view-hide-add')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('grant-god-view-hide-add')));
          await tester.pumpAndSettle();
          await tester.enterText(find.byKey(const ValueKey('gv-person-search')), 'hafiz');
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('gv-person-result-p-hafiz')), findsOneWidget);
          await _shoot(tester, 'gv_people_add_${b.name}');
          expect(tester.takeException(), isNull);
        });
      }
    });

    testWidgets('nothing changed: nothing saved', (tester) async {
      final admin = _Admin(grants: [gv({'country': 'Malaysia'})])
        ..godPeople = const GodViewPeople(mode: GodViewPeopleMode.only, only: [GodViewListedPerson(id: 'p-siti')]);
      await openGodView(tester, admin, Brightness.light);
      expect(find.byKey(const ValueKey('grant-god-view-only-p-siti')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('grant-save')));
      await tester.pumpAndSettle();
      expect(admin.peopleSaves, isEmpty);
      expect(admin.setCalls, isEmpty);
    });

    testWidgets("the lists can't be read: the region still edits, the lists are left alone", (tester) async {
      final admin = _Admin(grants: [gv()])..failPeopleRead = true;
      await openGodView(tester, admin, Brightness.dark);
      expect(find.byKey(const ValueKey('grant-god-view-people-error')), findsOneWidget);
      expect(find.byKey(const ValueKey('grant-god-view-region')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('grant-god-view-everywhere')));
      await tester.tap(find.byKey(const ValueKey('grant-god-view-everywhere')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('grant-save')));
      await tester.pumpAndSettle();
      expect(admin.regionCalls.single[godViewPage], {'everywhere': true});
      expect(admin.peopleSaves, isEmpty);
    });

    testWidgets('a new God View grant: the lists saved with it, none read first', (tester) async {
      final admin = _Admin(grants: [
        {'id': 'g2', 'profile_id': 'p-aina', 'page': 'admin-users', 'access_level': 'read'},
      ]);
      await openGodView(tester, admin, Brightness.light);
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('grant-level-$godViewPage')), matching: find.text('View')));
      await tester.pumpAndSettle();
      expect(admin.peopleReads, isEmpty);
      await tester.ensureVisible(find.byKey(const ValueKey('grant-god-view-mode-nobody')));
      await tester.tap(find.byKey(const ValueKey('grant-god-view-mode-nobody')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('grant-save')));
      await tester.pumpAndSettle();
      expect(admin.setCalls.single.upserts, contains((page: godViewPage, edit: false)));
      expect(admin.peopleSaves.single.$2.mode, GodViewPeopleMode.nobody);
    });

    test('changes and the summary', () {
      const a = GodViewListedPerson(id: 'a', name: 'Aina', phone: '+60123456789', displayId: 'GR1');
      const b = GodViewListedPerson(id: 'b');
      expect(const GodViewPeople().differsFrom(GodViewPeople.none), isFalse);
      expect(const GodViewPeople(hide: [a, b]).differsFrom(const GodViewPeople(hide: [b, a])), isFalse);
      expect(const GodViewPeople(hide: [a]).differsFrom(const GodViewPeople(only: [a])), isTrue);
      expect(const GodViewPeople(mode: GodViewPeopleMode.nobody).differsFrom(GodViewPeople.none), isTrue);
      expect(addListedPerson(const [a], a), hasLength(1));
      expect(removeListedPerson(const [a, b], 'a').map((p) => p.id), ['b']);
      expect(listedPersonMatches(a, 'ain'), isTrue);
      expect(listedPersonMatches(a, '456'), isTrue);
      expect(listedPersonMatches(a, 'gr1'), isTrue);
      expect(listedPersonMatches(a, 'zz'), isFalse);
      final read = GodViewPeople.fromJson(const {
        'mode': 'only',
        'people': [
          {'id': 'a', 'name': 'Aina', 'list': 'only', 'partner': false},
          {'id': 'b', 'name': 'Bob', 'list': 'hide', 'partner': true},
        ],
      });
      expect(read.mode, GodViewPeopleMode.only);
      expect(read.only.single.id, 'a');
      expect(read.hide.single.partner, isTrue);
      expect(GodViewPeopleMode.parse('weird'), GodViewPeopleMode.region);
      expect(const GodViewPeople(mode: GodViewPeopleMode.only, only: [a]).summary, 'Only 1 person');
    });
  });

  testWidgets('a God View grant saved as Everywhere opens with the switch on', (tester) async {
    final admin = _Admin(grants: [
      {'id': 'g1', 'profile_id': 'p-aina', 'page': godViewPage, 'access_level': 'read', 'region': {'everywhere': true}},
    ]);
    await _pump(tester, admin, const AdminSubAdminsScreen());
    await tester.tap(find.byKey(const ValueKey('sub-admin-edit-p-aina')));
    await tester.pumpAndSettle();
    await tester.enterText(find.ancestor(of: find.text('Filter pages'), matching: find.byType(TextField)), 'god');
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('grant-god-view-everywhere'))).value, isTrue);
    expect(find.text('Everywhere: they see everyone on God View'), findsOneWidget);
  });

  testWidgets('a Reports grant keeps its region too (0280)', (tester) async {
    final admin = _Admin(grants: [
      {
        'id': 'g1',
        'profile_id': 'p-aina',
        'page': reportsPage,
        'access_level': 'edit',
        'region': {'country': 'Malaysia', 'state': 'Johor'},
      },
    ]);
    await _pump(tester, admin, const AdminSubAdminsScreen());
    await tester.tap(find.byKey(const ValueKey('sub-admin-edit-p-aina')));
    await tester.pumpAndSettle();
    await tester.enterText(find.ancestor(of: find.text('Filter pages'), matching: find.byType(TextField)), 'reports');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('grant-reports-region')), findsOneWidget);
    expect(find.text('Johor, Malaysia'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('grant-notes')), 'Johor reports');
    await tester.tap(find.byKey(const ValueKey('grant-save')));
    await tester.pumpAndSettle();
    expect(admin.regionCalls.single[reportsPage]?['state'], 'Johor');
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
      // A whole date pasted into one of the boxes fills all three.
      await tester.enterText(
          find.descendant(of: find.byKey(const ValueKey('doc-edit-expiry')), matching: find.byKey(const ValueKey('date-box-day'))),
          '2031-02-03');
      await tester.enterText(find.byKey(const ValueKey('doc-edit-number')), 'L999');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('doc-edit-save')));
      await tester.pumpAndSettle();
      expect(admin.docPatches.single['expiry_date'], '2031-02-03');
      expect(admin.docPatches.single['document_number'], 'L999');
    });

    for (final b in Brightness.values) {
      testWidgets('a photo document shows its face match; a low one comes first and is filtered (${b.name})',
          (tester) async {
        final admin = _Admin(docs: [
          doc,
          {...doc, 'id': 'd2', 'doc_name': 'PSV licence'},
          {...doc, 'id': 'd3', 'doc_name': 'Vehicle insurance'},
        ])
          ..faces = {
            'd1': {'state': 'match', 'score': 91.4, 'provider': 'aws', 'selfie_url': 's', '_liveness': 'passed', '_liveness_detail': 'blink'},
            'd2': {'state': 'no_match', 'score': 31, 'provider': 'aws', 'selfie_url': 's', '_liveness': 'passed'},
          };
        final identity = _Faces();
        await _pump(tester, admin, const AdminDocumentsScreen(), b: b, extra: [identityRepositoryProvider.overrideWithValue(identity)]);
        expect(find.textContaining('Face: 91% match'), findsOneWidget);
        expect(find.textContaining('Face: Faces differ: 31% match'), findsOneWidget);
        // The low match first.
        expect(tester.getTopLeft(find.byKey(const ValueKey('doc-row-d2'))).dy,
            lessThan(tester.getTopLeft(find.byKey(const ValueKey('doc-row-d1'))).dy));
        await tester.tap(find.text('Needs a closer look'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('doc-row-d2')), findsOneWidget);
        expect(find.byKey(const ValueKey('doc-row-d1')), findsNothing);
        expect(find.byKey(const ValueKey('doc-row-d3')), findsNothing);
        await tester.tap(find.text('PSV licence'));
        await tester.pumpAndSettle();
        expect(find.text('Needs a closer look: compare the photo with the selfie by eye.'), findsOneWidget);
        expect(find.text('Faces differ: 31% match · AWS'), findsWidgets);
        await tester.tap(find.byKey(const ValueKey('doc-face-again')));
        await tester.pumpAndSettle();
        expect(identity.asked, ['provider_document:d2']);
        expect(find.text('Not checked · No live selfie yet'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

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

class _Faces extends IdentityRepository {
  _Faces() : super(_db);
  final asked = <String>[];

  @override
  Future<Map<String, dynamic>> compareDocumentFace(String kind, String id) async {
    asked.add('$kind:$id');
    return {'state': 'not_checked', 'reason': 'no_live_selfie'};
  }
}
