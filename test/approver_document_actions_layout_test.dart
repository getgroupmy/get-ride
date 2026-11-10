// Regression: the approver document viewer's reject / send-back / edit action
// rows must render their confirm button when the sheet is shown as a real
// dialog on a phone. They used a Row + Spacer, which crashed with "BoxConstraints
// forces an infinite width" under the unbounded width a dialog hands its child,
// so the confirm button silently failed to lay out and an approver could not
// complete a rejection or send-back (the image-failed case in particular). Now
// OverflowBar, which needs no bounded width.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/approver_inbox_repository.dart';
import 'package:get_ride/src/features/approver/approver_inbox_screen.dart';

ApproverGrant _grant() => const ApproverGrant(
      canApprove: true, canUpload: true, canDelete: true, deleteHard: false,
      canCredit: false, canEditProfile: false, canVerifyId: false, scope: 'all', docTypes: [],
    );

const _doc = ApproverDoc(
  source: 'partner', id: 'd1', ownerId: 'm1', ownerName: 'Nazaruddin Bin Yusoff',
  ownerPhone: '+60123456789',
  docKey: 'vehicle_ownership', docLabel: 'Vehicle Ownership Certificate',
  fileUrl: 'https://example.invalid/front.jpg', fileUrlBack: null, status: 'Pending Review',
);

Future<void> _openDialog(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1170, 2532); // a phone, like the screenshot
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      approverSelfProvider.overrideWith((ref) async => _grant()),
      approverDocumentDetailProvider.overrideWith((ref, key) async => null),
    ],
    child: MaterialApp(
      theme: appTheme(Brightness.light),
      home: Scaffold(
        body: Builder(builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () => showDialog<void>(
              context: context, builder: (_) => const ApproverDocumentViewer(doc: _doc)),
            child: const Text('open'),
          ),
        )),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('reject: confirm renders and enables once a reason is typed', (tester) async {
    await _openDialog(tester);
    await tester.tap(find.byKey(const ValueKey('approver-reject')));
    await tester.pumpAndSettle();

    final confirm = find.byKey(const ValueKey('approver-reject-confirm'));
    expect(confirm, findsOneWidget);
    // Empty reason → disabled; typed reason → enabled.
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('approver-reject-reason')), 're upload');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
  });

  testWidgets('send back: confirm renders and is enabled', (tester) async {
    await _openDialog(tester);
    await tester.tap(find.byKey(const ValueKey('approver-delete')));
    await tester.pumpAndSettle();

    final confirm = find.byKey(const ValueKey('approver-delete-confirm'));
    expect(confirm, findsOneWidget);
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    expect(find.text('Send back'), findsWidgets);
  });

  testWidgets('approve is blocked when the image did not load', (tester) async {
    await _openDialog(tester);
    // The invalid URL fails to load in tests, so the errorBuilder fires.
    await tester.pumpAndSettle();
    final approve = find.byKey(const ValueKey('approver-approve'));
    expect(approve, findsOneWidget);
    expect(tester.widget<FilledButton>(approve).onPressed, isNull,
        reason: 'Approve must be disabled when the image is unviewable');
    expect(find.textContaining("can't be approved"), findsOneWidget);
    // Reject and Send back are still offered.
    expect(find.byKey(const ValueKey('approver-reject')), findsOneWidget);
    expect(find.byKey(const ValueKey('approver-delete')), findsOneWidget);
  });
}
