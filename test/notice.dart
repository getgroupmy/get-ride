// Messages are modals (showAppNotice, lib/src/widgets/app_notice.dart): one
// opens after the next frame and stays until OK is tapped.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lets a notice that was asked for open (it waits for the next frame).
Future<void> pumpNotice(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Opens the notice that was asked for, if it is not up yet, and closes it
/// with OK, as the user would before going on.
Future<void> closeNotice(WidgetTester tester) async {
  await pumpNotice(tester);
  final ok = find.byKey(const ValueKey('notice-ok'));
  expect(ok, findsWidgets, reason: 'a notice is showing');
  await tester.tap(ok.last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Closes a notice if one is up (or about to open), for steps that go on
/// after a save whose message is not what the test is about.
Future<void> closeAnyNotice(WidgetTester tester) async {
  await pumpNotice(tester);
  final ok = find.byKey(const ValueKey('notice-ok'));
  if (ok.evaluate().isEmpty) return;
  await tester.tap(ok.last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}
