// My Team → Documents tab: documents group into Driver / Vehicle sections and
// each card carries inline actions gated by the approver's grant — Approve /
// Reject show only for a pending document an approver may review, and call
// approver_review. Widget tests over MyTeamMemberScreen with a fake repository.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/approver_inbox_repository.dart';
import 'package:get_ride/src/features/approver/my_team_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

ApproverGrant _grant({bool approve = true, bool upload = true, bool delete = true}) => ApproverGrant(
      canApprove: approve, canUpload: upload, canDelete: delete, deleteHard: false,
      canCredit: false, canEditProfile: false, canVerifyId: false,
      scope: 'all', docTypes: const [],
    );

const _member = TeamMember(id: 'm1', name: 'Mohd Faizul', status: 'approved');

ApproverDoc _doc({required String id, required String source, required String label, String status = 'Pending Review'}) =>
    ApproverDoc(
      source: source, id: id, ownerId: 'm1', ownerName: 'Mohd Faizul', ownerPhone: null,
      docKey: id, docLabel: label, fileUrl: null, fileUrlBack: null, status: status,
      expiryDate: '2027-03-14', requiresExpiry: true,
    );

final _docs = <ApproverDoc>[
  _doc(id: 'd1', source: 'partner', label: "Driver's Licence"),
  _doc(id: 'd2', source: 'vehicle', label: 'Vehicle Insurance', status: 'Approved'),
];

class _FakeRepo extends ApproverInboxRepository {
  _FakeRepo()
      : super(SupabaseClient('http://localhost', 'test-anon-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false)));

  (String, String)? reviewed; // (docId, action)

  @override
  Future<void> review(ApproverDoc doc, String action, {String? note}) async {
    reviewed = (doc.id, action);
  }

  @override
  Future<Map<String, dynamic>> ownerDocumentMeta(String ownerId) async => {
        'd1': {'changed_by': 'Insyirah Inani'},
        'd2': {'provider': 'Etiqa General Insurance Berhad'},
      };
}

Future<_FakeRepo> _open(WidgetTester tester, {required ApproverGrant grant}) async {
  final repo = _FakeRepo();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        approverInboxRepositoryProvider.overrideWithValue(repo),
        approverSelfProvider.overrideWith((ref) async => grant),
        approverMemberWalletProvider.overrideWith((ref, id) async => null),
        approverOwnerDocumentsProvider.overrideWith((ref, id) async => _docs),
        approverOwnerDocMetaProvider.overrideWith((ref, id) async => <String, dynamic>{
              'd1': {'changed_by': 'Insyirah Inani'},
              'd2': {'provider': 'Etiqa General Insurance Berhad'},
            }),
      ],
      child: MaterialApp(theme: appTheme(Brightness.light), home: const MyTeamMemberScreen(member: _member)),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('member-tab-documents')));
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('documents group into Driver and Vehicle sections', (tester) async {
    await _open(tester, grant: _grant());
    expect(find.text('DRIVER DOCUMENTS'), findsOneWidget);
    expect(find.text('VEHICLE DOCUMENTS'), findsOneWidget);
    expect(find.text("Driver's Licence"), findsOneWidget);
    expect(find.text('Vehicle Insurance'), findsOneWidget);
    // Per-doc meta (migration 0370): changed-by on the driver doc, insurance on the vehicle doc.
    expect(find.text('Changed by: Insyirah Inani'), findsOneWidget);
    expect(find.text('Insurance: Etiqa General Insurance Berhad'), findsOneWidget);
  });

  testWidgets('a pending doc shows Approve/Reject and approving calls review', (tester) async {
    final repo = await _open(tester, grant: _grant());

    // The pending driver doc has Approve/Reject; the approved vehicle doc does not.
    expect(find.byKey(const ValueKey('doc-approve-d1')), findsOneWidget);
    expect(find.byKey(const ValueKey('doc-approve-d2')), findsNothing);

    await tester.ensureVisible(find.byKey(const ValueKey('doc-approve-d1')));
    await tester.tap(find.byKey(const ValueKey('doc-approve-d1')));
    await tester.pumpAndSettle();
    expect(repo.reviewed, ('d1', 'approve'));
  });

  testWidgets('without the approve grant, no review buttons show', (tester) async {
    await _open(tester, grant: _grant(approve: false));
    expect(find.byKey(const ValueKey('doc-approve-d1')), findsNothing);
    expect(find.byKey(const ValueKey('doc-reject-d1')), findsNothing);
    // Details is always available.
    expect(find.byKey(const ValueKey('doc-details-d1')), findsOneWidget);
  });
}
