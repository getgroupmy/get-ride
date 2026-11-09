// My Team member screen (migration 0383): an approver with can_edit_profile can
// set a covered member's availability from the header presence chip (confirmed,
// since it changes the driver's own state), and a member whose approved
// documents are within 30 days of expiry shows an amber "N expiring" badge.
// Widget tests over MyTeamMemberScreen with a fake repository, so nothing hits
// the network.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/approver_inbox_repository.dart';
import 'package:get_ride/src/features/approver/my_team_screen.dart';
import 'package:get_ride/src/providers.dart' show currentUserIdProvider;
import 'package:supabase_flutter/supabase_flutter.dart';

ApproverGrant _grant({bool edit = false}) => ApproverGrant(
      canApprove: true, canUpload: false, canDelete: false, deleteHard: false,
      canCredit: false, canEditProfile: edit, canVerifyId: false,
      scope: 'all', docTypes: const [],
    );

class _FakeRepo extends ApproverInboxRepository {
  _FakeRepo()
      : super(SupabaseClient('http://localhost', 'test-anon-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false)));

  (String, bool)? presenceSet; // (memberId, online)
  bool presenceApplied = true;

  @override
  Future<bool> setMemberPresence(String memberId, bool online) async {
    presenceSet = (memberId, online);
    return presenceApplied ? online : false;
  }

  @override
  Future<Map<String, dynamic>?> memberDetail(String memberId) async => null;

  @override
  Future<List<ApproverDoc>> ownerDocuments(String ownerId) async => const <ApproverDoc>[];
}

Future<_FakeRepo> _pump(WidgetTester tester, {required ApproverGrant grant, required TeamMember member}) async {
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
        approverSelfProvider.overrideWith((ref) async => grant),
        approverOwnerDocumentsProvider.overrideWith((ref, id) async => const <ApproverDoc>[]),
        approverMemberWalletProvider.overrideWith((ref, id) async => null),
      ],
      child: MaterialApp(
        theme: appTheme(Brightness.light),
        home: MyTeamMemberScreen(member: member),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

const _presenceChip = ValueKey('member-presence-chip');
const _presenceConfirm = ValueKey('member-presence-confirm');

// The header chip's label, scoped so the profile tab's own "Current status"
// Online/Offline text is not counted.
Finder _chipText(String s) => find.descendant(of: find.byKey(_presenceChip), matching: find.text(s));

void main() {
  testWidgets('can_edit_profile: tapping the presence chip confirms and sets the member online', (tester) async {
    final repo = await _pump(tester,
        grant: _grant(edit: true),
        member: const TeamMember(id: 'm1', name: 'Test Member', status: 'approved', online: false));

    // Offline to start.
    expect(_chipText('Offline'), findsOneWidget);

    await tester.tap(find.byKey(_presenceChip));
    await tester.pumpAndSettle();

    // Confirm dialog, then apply.
    expect(find.text('Set Test online?'), findsOneWidget);
    await tester.tap(find.byKey(_presenceConfirm));
    await tester.pumpAndSettle();

    expect(repo.presenceSet, ('m1', true));
    // Header chip reflects the applied state optimistically.
    expect(_chipText('Online'), findsOneWidget);
  });

  testWidgets('can_edit_profile: an online member is set offline', (tester) async {
    final repo = await _pump(tester,
        grant: _grant(edit: true),
        member: const TeamMember(id: 'm1', name: 'Test Member', status: 'approved', online: true));

    expect(_chipText('Online'), findsOneWidget);
    await tester.tap(find.byKey(_presenceChip));
    await tester.pumpAndSettle();
    expect(find.text('Set Test offline?'), findsOneWidget);
    await tester.tap(find.byKey(_presenceConfirm));
    await tester.pumpAndSettle();

    expect(repo.presenceSet, ('m1', false));
    expect(_chipText('Offline'), findsOneWidget);
  });

  testWidgets('no can_edit_profile: the presence chip shows but is not tappable', (tester) async {
    await _pump(tester,
        grant: _grant(),
        member: const TeamMember(id: 'm1', name: 'Test Member', status: 'approved', online: true));

    // Chip is not wrapped in the tappable key when the approver can't edit.
    expect(find.byKey(_presenceChip), findsNothing);
  });

  testWidgets('docs_expiring badge shows the count, and is hidden when zero', (tester) async {
    await _pump(tester,
        grant: _grant(edit: true),
        member: const TeamMember(id: 'm1', name: 'Test Member', status: 'approved', docsExpiring: 2));
    expect(find.text('2 expiring'), findsOneWidget);

    await _pump(tester,
        grant: _grant(edit: true),
        member: const TeamMember(id: 'm1', name: 'Test Member', status: 'approved', docsExpiring: 0));
    expect(find.textContaining('expiring'), findsNothing);
  });
}
