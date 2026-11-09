// My Team — the dedicated ID sheet (migration 0385): opened from "View / edit
// ID details", it shows the birth date and gender read off the MyKad number,
// the read-vs-stored rows with a Fix on each editable mismatch, and
// Verify / Reject for a pending check. Widget tests over the member screen with
// a fake repository, so nothing hits the network.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/approver_inbox_repository.dart';
import 'package:get_ride/src/features/approver/my_team_screen.dart';
import 'package:get_ride/src/providers.dart' show currentUserIdProvider;
import 'package:supabase_flutter/supabase_flutter.dart';

ApproverGrant _grant({bool edit = true, bool approve = true}) => ApproverGrant(
      canApprove: approve, canUpload: false, canDelete: false, deleteHard: false,
      canCredit: false, canEditProfile: edit, canVerifyId: false,
      scope: 'all', docTypes: const [],
    );

// IC 880814-07-5678 → born 14 Aug 1988, last digit even → Female.
const _member = TeamMember(id: 'm1', name: 'Siti Noor', status: 'approved', ic: '880814-07-5678');

const _idDoc = ApproverDoc(
  source: 'identity', id: 'chk1', ownerId: 'm1', ownerName: 'Siti Noor',
  ownerPhone: null, docKey: 'mykad', docLabel: 'MyKad',
  fileUrl: null, fileUrlBack: null, status: 'Pending Review',
);

const _detail = DocDetail(
  status: 'Pending Review',
  read: [
    DocReadRow(field: 'Name', read: 'Siti Noor', stored: 'Siti Noor', match: true),
    DocReadRow(field: 'ID no.', read: '880814-07-9999', stored: '880814-07-5678', match: false),
    DocReadRow(field: 'Expiry', read: '2031-01-02', stored: '2030-05-01', match: false),
  ],
);

class _FakeRepo extends ApproverInboxRepository {
  _FakeRepo()
      : super(SupabaseClient('http://localhost', 'test-anon-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false)));

  Map<String, dynamic>? editedProfile;
  (String, String?)? editedExpiry; // (checkId, expiry)
  (String, String)? reviewed; // (docId, action)

  @override
  Future<void> editProfile(String memberId, Map<String, dynamic> fields) async => editedProfile = fields;

  @override
  Future<void> editIdentityExpiry(String checkId, String? expiry) async => editedExpiry = (checkId, expiry);

  @override
  Future<void> review(ApproverDoc doc, String action, {String? note}) async => reviewed = (doc.id, action);
}

Future<_FakeRepo> _openSheet(WidgetTester tester, {ApproverGrant? grant, DocDetail? detail = _detail}) async {
  tester.view.physicalSize = const Size(1200, 2800);
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
        approverOwnerDocumentsProvider.overrideWith((ref, id) async => const [_idDoc]),
        approverDocumentDetailProvider.overrideWith((ref, key) async => detail),
      ],
      child: MaterialApp(theme: appTheme(Brightness.light), home: const MyTeamMemberScreen(member: _member)),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('profile-view-id')));
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('shows DOB and gender read off the MyKad number', (tester) async {
    await _openSheet(tester);
    expect(find.text('14 Aug 1988'), findsOneWidget);
    expect(find.text('Female'), findsOneWidget);
  });

  testWidgets('Fix on ID no. writes the read value to the profile', (tester) async {
    final repo = await _openSheet(tester);
    await tester.tap(find.byKey(const ValueKey('id-fix-ID no.')));
    await tester.pumpAndSettle();
    expect(repo.editedProfile, {'ic': '880814-07-9999'});
  });

  testWidgets('Fix on Expiry writes the ID check expiry', (tester) async {
    final repo = await _openSheet(tester);
    await tester.tap(find.byKey(const ValueKey('id-fix-Expiry')));
    await tester.pumpAndSettle();
    expect(repo.editedExpiry, ('chk1', '2031-01-02'));
  });

  testWidgets('a matching row (Name) offers no Fix', (tester) async {
    await _openSheet(tester);
    expect(find.byKey(const ValueKey('id-fix-Name')), findsNothing);
  });

  testWidgets('Verify reviews the ID check as approved', (tester) async {
    final repo = await _openSheet(tester);
    await tester.tap(find.byKey(const ValueKey('id-verify')));
    await tester.pumpAndSettle();
    expect(repo.reviewed, ('chk1', 'approve'));
  });

  testWidgets('Reject needs a reason, then reviews as rejected', (tester) async {
    final repo = await _openSheet(tester);
    await tester.tap(find.byKey(const ValueKey('id-reject')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('id-reject-note')), 'Blurry photo');
    await tester.tap(find.byKey(const ValueKey('id-reject-confirm')));
    await tester.pumpAndSettle();
    expect(repo.reviewed, ('chk1', 'reject'));
  });

  testWidgets('without can_approve there are no Verify/Reject buttons', (tester) async {
    await _openSheet(tester, grant: _grant(approve: false));
    expect(find.byKey(const ValueKey('id-verify')), findsNothing);
    expect(find.byKey(const ValueKey('id-reject')), findsNothing);
  });
}
