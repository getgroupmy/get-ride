// Slice 9: the side-menu Approvals row carries a "NEW" tag and a count of
// documents waiting to review (approverPendingCountProvider). Widget test over
// ApprovalsPendingBadge with the count overridden, so nothing touches the
// network.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/approver_inbox_repository.dart';
import 'package:get_ride/src/widgets/side_menu_tiles.dart';

Future<void> _pump(WidgetTester tester, int count) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [approverPendingCountProvider.overrideWithValue(count)],
      child: MaterialApp(
        theme: appTheme(Brightness.light),
        home: const Scaffold(body: ApprovalsPendingBadge()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('no badge when nothing is waiting', (tester) async {
    await _pump(tester, 0);
    expect(find.byKey(const ValueKey('menu-approvals-badge')), findsNothing);
    expect(find.text('NEW'), findsNothing);
  });

  testWidgets('shows NEW tag and the pending count', (tester) async {
    await _pump(tester, 3);
    expect(find.byKey(const ValueKey('menu-approvals-badge')), findsOneWidget);
    expect(find.text('NEW'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('caps a large count the way the inbox badge does', (tester) async {
    await _pump(tester, 150);
    // inboxBadgeText caps at 99+.
    expect(find.text('99+'), findsOneWidget);
    expect(find.text('NEW'), findsOneWidget);
  });
}
