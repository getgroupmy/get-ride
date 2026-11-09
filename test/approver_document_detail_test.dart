// Approver document detail sheet (migration 0365): the rich sections —
// read-vs-stored, AI verification, face check and status/history — render from
// approverDocumentDetailProvider when present, and nothing extra shows when the
// detail is null (a plain document, or a legacy database).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/approver_inbox_repository.dart';
import 'package:get_ride/src/features/approver/approver_inbox_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Records the edit the "Fix" button sends, so the test can check which fields
/// it wrote without touching the network.
class _FakeRepo extends ApproverInboxRepository {
  _FakeRepo()
      : super(SupabaseClient('http://localhost', 'test-anon-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false)));
  Map<String, String?>? lastEdit;
  @override
  Future<void> editFields(ApproverDoc doc, {String? documentNumber, String? startDate, String? expiryDate}) async {
    lastEdit = {'number': documentNumber, 'start': startDate, 'expiry': expiryDate};
  }
}

ApproverGrant _grant() => const ApproverGrant(
      canApprove: true, canUpload: true, canDelete: false, deleteHard: false,
      canCredit: false, canEditProfile: false, canVerifyId: false, scope: 'all', docTypes: [],
    );

const _doc = ApproverDoc(
  source: 'partner',
  id: 'd1',
  ownerId: 'm1',
  ownerName: 'Mohd Faizul',
  ownerPhone: '+60123456789',
  docKey: 'driver_licence',
  docLabel: "Driver's Licence",
  fileUrl: 'https://example.invalid/front.jpg',
  fileUrlBack: null,
  status: 'Approved',
);

const _detail = DocDetail(
  status: 'Approved',
  reviewerNotes: null,
  changedBy: 'Insyirah Inani',
  uploadedAt: '2026-10-12T08:00:00Z',
  reviewedAt: '2026-10-12T09:00:00Z',
  ai: DocAi(genuine: true, matches: true, detectedTitle: "Driver's Licence", confidence: '0.96', country: 'MY'),
  read: [
    DocReadRow(field: 'ID no.', read: '830314025001', stored: '830314025001', match: true),
    DocReadRow(field: 'Class', read: 'D, B2, D-E', stored: 'D', match: false),
  ],
  face: DocFace(ok: true, score: 0.91, label: 'match', reason: null),
);

Future<void> _pump(WidgetTester tester, {DocDetail? detail}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        approverSelfProvider.overrideWith((ref) async => _grant()),
        approverDocumentDetailProvider.overrideWith((ref, key) async => detail),
      ],
      child: MaterialApp(
        theme: appTheme(Brightness.light),
        home: const Scaffold(body: ApproverDocumentViewer(doc: _doc)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the rich sections when detail is present', (tester) async {
    await _pump(tester, detail: _detail);

    expect(find.text('READ FROM DOCUMENT VS STORED'), findsOneWidget);
    expect(find.text('AI VERIFICATION'), findsOneWidget);
    expect(find.text('FACE CHECK'), findsOneWidget);
    expect(find.text('STATUS & HISTORY'), findsOneWidget);

    expect(find.text('Genuine'), findsOneWidget);
    expect(find.text('Confidence 0.96'), findsOneWidget);
    expect(find.textContaining('Portrait matches selfie'), findsOneWidget);
    expect(find.text('Insyirah Inani'), findsOneWidget);
    // A matching read row shows "match"; the differing one shows "differs".
    expect(find.text('match'), findsWidgets);
    expect(find.text('differs'), findsOneWidget);
  });

  testWidgets('no detail: no rich sections', (tester) async {
    await _pump(tester, detail: null);
    expect(find.text('AI VERIFICATION'), findsNothing);
    expect(find.text('STATUS & HISTORY'), findsNothing);
  });

  testWidgets('a differing editable row shows the stored value and a Fix that applies the read value', (tester) async {
    final repo = _FakeRepo();
    const editDoc = ApproverDoc(
      source: 'partner', id: 'd2', ownerId: 'm1', ownerName: 'X', ownerPhone: '+60',
      docKey: 'driver_licence', docLabel: "Driver's Licence",
      fileUrl: 'https://example.invalid/f.jpg', fileUrlBack: null, status: 'Pending Review',
      requiresNumber: true, requiresExpiry: true,
    );
    const editDetail = DocDetail(
      status: 'Pending Review', documentNumber: 'A999', expiryDate: '2026-12-31',
      read: [
        DocReadRow(field: 'Document no.', read: 'A123', stored: 'A999', match: false),
        DocReadRow(field: 'Expiry', read: '2027-06-01', stored: '2026-12-31', match: false),
        // Not an editable field — no Fix, just "differs".
        DocReadRow(field: 'Country', read: 'MY', stored: 'SG', match: false),
      ],
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        approverSelfProvider.overrideWith((ref) async => _grant()),
        approverInboxRepositoryProvider.overrideWithValue(repo),
        approverDocumentDetailProvider.overrideWith((ref, key) async => editDetail),
      ],
      child: MaterialApp(theme: appTheme(Brightness.light), home: const Scaffold(body: ApproverDocumentViewer(doc: editDoc))),
    ));
    await tester.pumpAndSettle();

    // Stored value is shown on a differing row; editable rows get a Fix button.
    expect(find.text('stored: A999'), findsOneWidget);
    expect(find.byKey(const ValueKey('doc-fix-number')), findsOneWidget);
    expect(find.byKey(const ValueKey('doc-fix-expiry')), findsOneWidget);
    // The non-editable Country row differs but has no Fix.
    expect(find.text('differs'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('doc-fix-number')));
    await tester.pumpAndSettle();
    // Only the document number changed; the other required field is resent as-is.
    expect(repo.lastEdit?['number'], 'A123');
    expect(repo.lastEdit?['expiry'], '2026-12-31');
  });
}
