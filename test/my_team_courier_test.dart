// My Team — the "Enable Courier" quick toggle on the Profile tab (loose end 3):
// an approver with can_edit_profile adds/removes the Courier service type in the
// member's partner_types through the profile edit. Widget tests over the member
// screen with a fake repository.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

  @override
  Future<void> editProfile(String memberId, Map<String, dynamic> fields) async => editedProfile = fields;
}

Future<_FakeRepo> _pump(WidgetTester tester, {required List<String> partnerTypes, ApproverGrant? grant}) async {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repo = _FakeRepo();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        approverInboxRepositoryProvider.overrideWithValue(repo),
        currentUserIdProvider.overrideWith((ref) => 'me'),
        approverSelfProvider.overrideWith((ref) async => grant ?? _grant()),
        approverMemberWalletProvider.overrideWith((ref, id) async => null),
        approverMemberDetailProvider.overrideWith((ref, id) async =>
            {'is_partner': true, 'partner_types': partnerTypes}),
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
}
