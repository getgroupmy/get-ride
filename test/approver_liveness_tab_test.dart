// Approvals → Liveness tab (migration 0401): live-selfie verifications get their
// own tab, split out of "To review". Widget test over ApproverInboxScreen with
// the pending list overridden.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/approver_inbox_repository.dart';
import 'package:get_ride/src/features/approver/approver_inbox_screen.dart';

ApproverDoc _doc({required String id, required String source, required String docKey, required String label}) =>
    ApproverDoc(
      source: source, id: id, ownerId: 'o-$id', ownerName: 'Owner $id', ownerPhone: null,
      docKey: docKey, docLabel: label, fileUrl: null, fileUrlBack: null);

final _docs = [
  _doc(id: 'sf1', source: 'identity', docKey: 'selfie', label: 'Selfie'),
  _doc(id: 'id1', source: 'identity', docKey: 'mykad', label: 'MyKad'),
  _doc(id: 'pd1', source: 'partner', docKey: 'dl', label: 'Driving License'),
];

Future<void> _pump(WidgetTester tester, List<ApproverDoc> docs) async {
  tester.view.physicalSize = const Size(1100, 2200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        approverPendingProvider.overrideWith((ref) async => docs),
        approverPendingUploadsProvider.overrideWith((ref) async => const <PendingUpload>[]),
      ],
      child: MaterialApp(theme: appTheme(Brightness.light), home: const ApproverInboxScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('To review hides selfies; the Liveness tab shows only them', (tester) async {
    await _pump(tester, _docs);

    // To review (default): the ID and partner docs, not the selfie.
    expect(find.byKey(const ValueKey('approver-doc-id1')), findsOneWidget);
    expect(find.byKey(const ValueKey('approver-doc-pd1')), findsOneWidget);
    expect(find.byKey(const ValueKey('approver-doc-sf1')), findsNothing);

    // The Liveness tab: only the selfie.
    await tester.tap(find.byKey(const ValueKey('approvals-tab-liveness')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('approver-doc-sf1')), findsOneWidget);
    expect(find.byKey(const ValueKey('approver-doc-id1')), findsNothing);
    expect(find.byKey(const ValueKey('approver-doc-pd1')), findsNothing);
  });

  testWidgets('empty Liveness tab shows its own empty state', (tester) async {
    await _pump(tester, [
      _doc(id: 'id1', source: 'identity', docKey: 'mykad', label: 'MyKad'),
    ]);
    await tester.tap(find.byKey(const ValueKey('approvals-tab-liveness')));
    await tester.pumpAndSettle();
    expect(find.text('No live selfies to verify'), findsOneWidget);
  });
}
