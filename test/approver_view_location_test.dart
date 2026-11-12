// Slice 4 (migration 0407): the admin's Approver dialog can grant Team
// Location (can_view_location). Toggling "View team location" puts the flag
// in the saved config, and re-opening a grant that has it pre-fills the
// switch on.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/people/approvers_screen.dart';

void main() {
  Future<Map<String, dynamic>?> run(
    WidgetTester tester, {
    Map<String, dynamic>? current,
    bool toggle = false,
  }) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    ApproverDialogResult? result;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                result = await showApproverDialog(context, name: 'Pat', current: current),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    if (toggle) {
      await tester.ensureVisible(find.byKey(const ValueKey('approver-view-location')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('approver-view-location')));
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(find.byKey(const ValueKey('approver-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('approver-save')));
    await tester.pumpAndSettle();
    return result?.config;
  }

  testWidgets('a fresh grant does not set the flag unless it is turned on', (tester) async {
    expect((await run(tester))?['can_view_location'], false);
  });

  testWidgets('turning "View team location" on carries the flag into the config', (tester) async {
    expect((await run(tester, toggle: true))?['can_view_location'], true);
  });

  testWidgets('the switch pre-fills on from a grant that already has it', (tester) async {
    // Opening with the flag set and saving without touching it keeps it true.
    final cfg = await run(tester, current: const {'can_view_location': true});
    expect(cfg?['can_view_location'], true);
  });

  testWidgets('a grant without the flag keeps it off', (tester) async {
    final cfg = await run(tester, current: const {'can_view_location': false, 'can_approve': true});
    expect(cfg?['can_view_location'], false);
  });
}
