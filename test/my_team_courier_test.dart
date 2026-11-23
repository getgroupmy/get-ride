// My Team — the "Enable Courier" quick toggle on the Profile tab (loose end 3):
// an approver with can_edit_profile adds/removes the Courier service type in the
// member's partner_types through the profile edit. An approved member's services
// are changed by an approver who is also an admin, not by other approvers (0432):
// for them the controls are left out and the reason shown. Widget tests over the
// member screen with a fake repository.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart' show adminAccessProvider;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/approver_inbox_repository.dart';
import 'package:get_ride/src/features/approver/my_team_screen.dart';
import 'package:get_ride/src/providers.dart' show currentUserIdProvider;
import 'package:supabase_flutter/supabase_flutter.dart';

ApproverGrant _grant({bool edit = true}) => ApproverGrant(
      canApprove: true, canUpload: false, canDelete: false, deleteHard: false,
      canCredit: false, canEditProfile: edit, canVerifyId: false,
      scope: 'all', docTypes: const [],
    );

const _member = TeamMember(id: 'm1', name: 'Test Member', status: 'approved');

class _FakeRepo extends ApproverInboxRepository {
  _FakeRepo()
      : super(SupabaseClient('http://localhost', 'test-anon-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false)));

  Map<String, dynamic>? editedProfile;

  /// The server refuses a change of an approved member's services.
  bool typesLocked = false;

  @override
  Future<void> editProfile(String memberId, Map<String, dynamic> fields) async {
    if (typesLocked && fields.containsKey('partner_types')) {
      throw const PostgrestException(message: 'PARTNER_TYPES_LOCKED', code: '42501');
    }
    editedProfile = fields;
  }
}

const _adminOnlyText = 'This member is approved, so an admin changes their services.';

/// An approver who is also an admin: they may read the Users pages.
const _readsUsers = AdminAccess([AdminGrant(page: 'admin-users', edit: false)]);

Future<_FakeRepo> _pump(WidgetTester tester,
    {required List<String> partnerTypes,
    ApproverGrant? grant,
    String? partnerStatus,
    AdminAccess admin = AdminAccess.none,
    bool typesLocked = false}) async {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repo = _FakeRepo()..typesLocked = typesLocked;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        approverInboxRepositoryProvider.overrideWithValue(repo),
        currentUserIdProvider.overrideWith((ref) => 'me'),
        approverSelfProvider.overrideWith((ref) async => grant ?? _grant()),
        adminAccessProvider.overrideWith((ref) async => admin),
        approverMemberWalletProvider.overrideWith((ref, id) async => null),
        approverMemberDetailProvider.overrideWith((ref, id) async => {
              'name': 'Test Member',
              'is_partner': true,
              'partner_types': partnerTypes,
              'partner_status': ?partnerStatus,
            }),
      ],
      child: MaterialApp(theme: appTheme(Brightness.light), home: const MyTeamMemberScreen(member: _member)),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('Enable Courier adds Courier to partner_types', (tester) async {
    final repo = await _pump(tester, partnerTypes: ['Ride']);
    expect(find.byKey(const ValueKey('courier-enable')), findsOneWidget);
    expect(find.byKey(const ValueKey('courier-remove')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('courier-enable')));
    await tester.pumpAndSettle();
    expect(repo.editedProfile, {'partner_types': ['Ride', 'Courier']});
  });

  testWidgets('when Courier is on, remove takes it out', (tester) async {
    final repo = await _pump(tester, partnerTypes: ['Ride', 'Courier']);
    expect(find.byKey(const ValueKey('courier-remove')), findsOneWidget);
    expect(find.byKey(const ValueKey('courier-enable')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('courier-remove')));
    await tester.pumpAndSettle();
    expect(repo.editedProfile, {'partner_types': ['Ride']});
  });

  testWidgets('without can_edit_profile there is no Courier control', (tester) async {
    await _pump(tester, partnerTypes: ['Ride'], grant: _grant(edit: false));
    expect(find.byKey(const ValueKey('courier-enable')), findsNothing);
    expect(find.byKey(const ValueKey('courier-remove')), findsNothing);
  });

  group('an approved member', () {
    testWidgets('an approver who is not an admin gets no Courier control, and is told why', (tester) async {
      await _pump(tester, partnerTypes: ['Ride'], partnerStatus: 'approved');
      expect(find.byKey(const ValueKey('courier-enable')), findsNothing);
      expect(find.byKey(const ValueKey('courier-remove')), findsNothing);
      expect(find.byKey(const ValueKey('services-admin-only')), findsOneWidget);
      expect(find.text(_adminOnlyText), findsOneWidget);
    });

    testWidgets('nor with a permit', (tester) async {
      await _pump(tester, partnerTypes: ['Ride', 'Courier'], partnerStatus: 'permit-verified');
      expect(find.byKey(const ValueKey('courier-remove')), findsNothing);
      expect(find.byKey(const ValueKey('services-admin-only')), findsOneWidget);
    });

    testWidgets('in the edit sheet their services are shown, not changed, and Save leaves them', (tester) async {
      final repo = await _pump(tester, partnerTypes: ['Ride', 'Courier'], partnerStatus: 'approved');
      await tester.tap(find.byKey(const ValueKey('profile-edit-name')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('edit-services')), findsNothing);
      expect(find.byKey(const ValueKey('edit-services-read-only')), findsOneWidget);
      expect(find.text('Ride, Courier'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('edit-name')), 'New Name');
      await tester.tap(find.byKey(const ValueKey('edit-save')));
      await tester.pumpAndSettle();
      expect(repo.editedProfile, {'name': 'New Name'});
    });

    testWidgets('an approver who is also an admin keeps the Courier control', (tester) async {
      final repo = await _pump(tester, partnerTypes: ['Ride'], partnerStatus: 'approved', admin: _readsUsers);
      expect(find.byKey(const ValueKey('services-admin-only')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('courier-enable')));
      await tester.pumpAndSettle();
      expect(repo.editedProfile, {'partner_types': ['Ride', 'Courier']});
    });

    testWidgets('a refusal from the server says why', (tester) async {
      final repo = await _pump(tester,
          partnerTypes: ['Ride'], partnerStatus: 'approved', admin: _readsUsers, typesLocked: true);
      await tester.tap(find.byKey(const ValueKey('courier-enable')));
      await tester.pumpAndSettle();
      expect(repo.editedProfile, isNull);
      expect(find.text(_adminOnlyText), findsOneWidget);
    });
  });

  testWidgets('a member still applying: the Courier control as before', (tester) async {
    await _pump(tester, partnerTypes: ['Ride'], partnerStatus: 'unapproved');
    expect(find.byKey(const ValueKey('courier-enable')), findsOneWidget);
    expect(find.byKey(const ValueKey('services-admin-only')), findsNothing);
  });
}
