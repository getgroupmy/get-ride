// The admin people lists' call button and one-tap status actions (Expo
// AdminUserList / AdminPartnerList / AdminVehicleList), and assigning a
// support ticket from the pool list.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_filters.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_repository.dart';
import 'package:get_ride/src/admin/screens/people/people_data.dart';
import 'package:get_ride/src/admin/screens/people_screens.dart';
import 'package:get_ride/src/admin/screens/support_agents.dart';
import 'package:get_ride/src/admin/widgets/admin_widgets.dart' show StatusChip;
import 'package:get_ride/src/admin/screens/support_screens.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_rating_repository.dart' show adminRatingFlagsProvider;
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';
import 'notice.dart';

// No token refresh: its timer would outlive the test.
final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

class _Admin extends AdminRepository {
  _Admin() : super(_db);
  final statuses = <(String, String)>[];
  final partnerPatches = <Map<String, dynamic>>[];
  final vehiclePatches = <Map<String, dynamic>>[];
  final assigned = <(String, String, String)>[];
  final takenBy = <(String, String)>[];

  @override
  Future<RowsPage> users({int limit = adminPeoplePageSize, String query = ''}) async => (
    rows: [
      {'id': 'u1', 'name': 'Una', 'phone': '+60 12-345 6789', 'profile_status': 'approved'},
      {'id': 'u2', 'name': 'Wan', 'phone': '+60123', 'profile_status': 'unapproved'},
      {'id': 'u3', 'name': 'Nophone', 'profile_status': 'deleted'},
    ],
    more: false,
  );

  @override
  Future<void> setUserStatus(String id, String status) async => statuses.add((id, status));

  @override
  Future<List<Map<String, dynamic>>> partners() async => [
    {'id': 'p1', 'auth_user_id': 'a1', 'name': 'Pak Ali', 'phone': '+60111', 'status': 'unapproved', 'permit': 'pending'},
  ];

  @override
  Future<void> updatePartner(String id, Map<String, dynamic> patch) async => partnerPatches.add(patch);

  @override
  Future<List<Map<String, dynamic>>> vehicles() async => [
    {
      'id': 'v1',
      'plate': 'WXY 1',
      'make': 'Proton',
      'model': 'Saga',
      'status': 'unapproved',
      'owner_phone': '+60199',
      'documents_ok': true,
    },
    {'id': 'v2', 'plate': 'ABC 2', 'status': 'approved'},
  ];

  @override
  Future<void> updateVehicle(String id, Map<String, dynamic> patch) async => vehiclePatches.add(patch);

  @override
  Future<List<Map<String, dynamic>>> tickets() async => [
    {'id': 't1', 'ticket_number': 7, 'subject': 'Lost phone', 'status': 'open'},
    {
      'id': 't2',
      'ticket_number': 8,
      'subject': 'Refund',
      'status': 'in_progress',
      'assigned_admin_id': 'x',
      'assigned_admin_name': 'Xin',
    },
    {'id': 't3', 'ticket_number': 9, 'subject': 'Done', 'status': 'closed'},
  ];

  @override
  Future<List<SupportAgent>> supportAgents() async => const [
    (id: 'me', name: 'Me', avatarUrl: null, priority: 1),
    (id: 'x', name: 'Xin', avatarUrl: null, priority: 2),
    (id: 'y', name: 'Yan', avatarUrl: null, priority: null),
  ];

  @override
  Future<void> assignTicket(String id, String agentId, String agentName) async =>
      assigned.add((id, agentId, agentName));

  @override
  Future<void> assignTicketToMe(String id, String myName) async => takenBy.add((id, myName));
}

class _People extends PeopleRepository {
  _People(this.docs) : super(_db);
  final List<Map<String, dynamic>> docs;

  @override
  Future<List<Map<String, dynamic>>> vehicleDocuments(String vehicleId) async => docs;
}

void main() {
  group('pure', () {
    test('each status offers what Expo offered', () {
      expect(quickStatusActions('unapproved').map((a) => a.next), ['approved', 'rejected']);
      expect(quickStatusActions('unapproved-docs').map((a) => a.label), ['Approve', 'Reject']);
      expect(quickStatusActions('approved'), [const QuickStatusAction('Block', 'blocked', destructive: true)]);
      expect(quickStatusActions('blocked'), [const QuickStatusAction('Unblock', 'approved')]);
      expect(quickStatusActions('rejected'), [const QuickStatusAction('Re-open', 'unapproved')]);
      expect(quickStatusActions('deleted'), isEmpty);
      expect(quickStatusActions(null), isEmpty);
      expect(quickStatusActions('unapproved').where((a) => a.destructive).map((a) => a.label), ['Reject']);
    });

    test('a call link keeps only + and digits', () {
      expect(phoneCallUri('+60 12-345 6789'), Uri(scheme: 'tel', path: '+60123456789'));
      expect(phoneCallUri(null), isNull);
      expect(phoneCallUri(''), isNull);
      expect(phoneCallUri('+1'), isNull);
    });
  });

  for (final b in Brightness.values) {
    group('people lists (${b.name})', () {
      Future<(_Admin, List<Uri>)> pump(
        WidgetTester tester,
        Widget screen, {
        bool edit = true,
        List<Map<String, dynamic>> docs = const [],
        Size size = const Size(1000, 1600),
        double textScale = 1,
      }) async {
        final admin = _Admin();
        final dialled = <Uri>[];
        tester.platformDispatcher.textScaleFactorTestValue = textScale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              supabaseProvider.overrideWithValue(_db),
              ...quietLiveOverrides,
              adminAccessProvider.overrideWith((_) async => AdminAccess([AdminGrant(page: '*', edit: edit)])),
              adminRepositoryProvider.overrideWithValue(admin),
              adminRatingFlagsProvider.overrideWith((ref) async => const {'a1': ['Unsafe driving']}),
              peopleRepositoryProvider.overrideWithValue(_People(docs)),
              adminDialerProvider.overrideWithValue((u) async {
                dialled.add(u);
                return true;
              }),
            ],
            child: MaterialApp(theme: appTheme(b), home: screen),
          ),
        );
        await tester.pumpAndSettle();
        return (admin, dialled);
      }

      testWidgets('users: call, approve at once, block after confirming', (tester) async {
        final (admin, dialled) = await pump(tester, const AdminUsersScreen());
        expect(find.byKey(const ValueKey('call-u3')), findsNothing, reason: 'no phone, no call button');
        await tester.tap(find.byKey(const ValueKey('call-u1')));
        await tester.pumpAndSettle();
        expect(dialled.single, Uri(scheme: 'tel', path: '+60123456789'));

        expect(find.byKey(const ValueKey('quick-approved-u2')), findsOneWidget);
        expect(find.byKey(const ValueKey('quick-rejected-u2')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('quick-approved-u2')));
        await tester.pumpAndSettle();
        expect(admin.statuses, [('u2', 'approved')]);

        // Block asks first; Cancel leaves it.
        await closeNotice(tester);
        await tester.tap(find.byKey(const ValueKey('quick-blocked-u1')));
        await tester.pumpAndSettle();
        expect(find.text('Block this user?'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(admin.statuses, hasLength(1));
        await tester.tap(find.byKey(const ValueKey('quick-blocked-u1')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Block'));
        await tester.pumpAndSettle();
        expect(admin.statuses.last, ('u1', 'blocked'));
        expect(tester.takeException(), isNull);
      });

      testWidgets('users at 1.3x on a 412 phone: the name and phone take the width, status and call go below',
          (tester) async {
        final (_, dialled) = await pump(tester, const AdminUsersScreen(), size: const Size(412, 915), textScale: 1.3);
        final meta = find.byKey(const ValueKey('record-meta-u1'));
        expect(meta, findsOneWidget);
        final call = find.byKey(const ValueKey('call-u1'));
        expect(find.descendant(of: meta, matching: call), findsOneWidget, reason: 'call on the row below');
        expect(find.descendant(of: meta, matching: find.byType(StatusChip)), findsOneWidget);
        // The name's column reaches the card's right edge (no chip beside it).
        final tile = find.ancestor(of: find.byKey(const ValueKey('record-meta-u1')), matching: find.byType(Column)).first;
        final title = find.descendant(of: tile, matching: find.byType(ListTile)).first;
        final tileRect = tester.getRect(title);
        final sub = tester.getRect(find.descendant(of: title, matching: find.byType(RichText)).at(1));
        expect(sub.width, greaterThan(tileRect.width - 72 - 16 - 40), reason: 'the phone line takes the remaining width');
        await tester.tap(call);
        await tester.pumpAndSettle();
        expect(dialled, hasLength(1));
        expect(tester.takeException(), isNull);
      });

      testWidgets('users at 1x keep the status and call beside the name', (tester) async {
        await pump(tester, const AdminUsersScreen(), size: const Size(412, 915));
        expect(find.byKey(const ValueKey('record-meta-u1')), findsNothing);
        expect(find.byKey(const ValueKey('call-u1')), findsOneWidget);
      });

      testWidgets('view-only access: the call button, no status actions', (tester) async {
        await pump(tester, const AdminUsersScreen(), edit: false);
        expect(find.byKey(const ValueKey('call-u1')), findsOneWidget);
        expect(find.byKey(const ValueKey('quick-approved-u2')), findsNothing);
        expect(find.byKey(const ValueKey('quick-blocked-u1')), findsNothing);
      });

      testWidgets('partners: Reject asks the reason it already asks for', (tester) async {
        final (admin, dialled) = await pump(tester, const AdminPartnersScreen());
        expect(find.textContaining('Flagged: Unsafe driving'), findsOneWidget, reason: 'riders\' low-rating tags (0297)');
        await tester.tap(find.byKey(const ValueKey('call-p1')));
        await tester.pumpAndSettle();
        expect(dialled.single, Uri(scheme: 'tel', path: '+60111'));

        await tester.tap(find.byKey(const ValueKey('quick-rejected-p1')));
        await tester.pumpAndSettle();
        expect(find.text('Reject this application?'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('status-reason')), 'Blurry permit');
        await tester.tap(find.byKey(const ValueKey('status-reason-save')));
        await tester.pumpAndSettle();
        expect(admin.partnerPatches.single, {'status': 'rejected', 'status_note': 'Blurry permit'});
      });

      testWidgets('vehicles: Approve keeps the document check; Block is confirmed', (tester) async {
        final (admin, dialled) = await pump(
          tester,
          const AdminPartnersScreen(vehicles: true),
          docs: [
            {'status': 'Pending Review'},
          ],
        );
        await tester.tap(find.byKey(const ValueKey('call-v1')));
        await tester.pumpAndSettle();
        expect(
          dialled.single,
          Uri(scheme: 'tel', path: '+60199'),
          reason: 'the owner\'s phone',
        );
        expect(find.byKey(const ValueKey('call-v2')), findsNothing);

        await tester.tap(find.byKey(const ValueKey('quick-approved-v1')));
        await tester.pumpAndSettle();
        expect(find.text('Documents not fully approved'), findsOneWidget);
        expect(admin.vehiclePatches, isEmpty);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('quick-blocked-v2')));
        await tester.pumpAndSettle();
        expect(find.text('Block this vehicle?'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'Block'));
        await tester.pumpAndSettle();
        expect(admin.vehiclePatches.single, {'status': 'blocked'});
        expect(tester.takeException(), isNull);
      });
    });

    group('support pool (${b.name})', () {
      Future<_Admin> pump(WidgetTester tester, {bool edit = true}) async {
        final admin = _Admin();
        await tester.binding.setSurfaceSize(const Size(1000, 1400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              supabaseProvider.overrideWithValue(_db),
              ...quietLiveOverrides,
              adminAccessProvider.overrideWith((_) async => AdminAccess([AdminGrant(page: '*', edit: edit)])),
              adminRepositoryProvider.overrideWithValue(admin),
              currentUserIdProvider.overrideWithValue('me'),
              profileProvider.overrideWith((ref) async => Profile({'id': 'me', 'name': 'Mia'})),
            ],
            child: MaterialApp(theme: appTheme(b), home: const AdminSupportScreen()),
          ),
        );
        await tester.pumpAndSettle();
        return admin;
      }

      testWidgets('assign an open ticket to an agent from the list', (tester) async {
        final admin = await pump(tester);
        expect(find.byKey(const ValueKey('list-assign-t1')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('list-assign-t1')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('support-agent-picker')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('assign-y')));
        await tester.pumpAndSettle();
        expect(admin.assigned.single, ('t1', 'y', 'Yan'));
        expect(tester.takeException(), isNull);
      });

      testWidgets('take a ticket from another agent', (tester) async {
        final admin = await pump(tester);
        await tester.tap(find.byKey(const ValueKey('list-assign-t2')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('assign-me')));
        await tester.pumpAndSettle();
        expect(admin.takenBy.single, ('t2', 'Mia'));
        expect(admin.assigned, isEmpty);
      });

      testWidgets('no assign key on a resolved ticket', (tester) async {
        await pump(tester);
        // Resolved tickets are under their own filter.
        await tester.tap(find.text('All'));
        await tester.pumpAndSettle();
        expect(find.text('#9 · Done'), findsOneWidget);
        expect(find.byKey(const ValueKey('list-assign-t3')), findsNothing);
      });

      testWidgets('no assign key without edit access', (tester) async {
        await pump(tester, edit: false);
        expect(find.byKey(const ValueKey('list-assign-t1')), findsNothing);
      });
    });
  }
}
