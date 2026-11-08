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
}
