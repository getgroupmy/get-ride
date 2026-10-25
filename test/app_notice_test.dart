// Popups are modals, never a bar at the bottom: messages go through
// showAppNotice (lib/src/widgets/app_notice.dart), listed in App Page
// Settings by area.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/page_inventory.g.dart';
import 'package:get_ride/src/widgets/app_notice.dart';
import 'package:get_ride/src/widgets/common.dart';

Map<String, List<String>> _libLines() => {
  for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
    if (f.path.endsWith('.dart') && !f.path.endsWith('.g.dart')) f.path.replaceAll(r'\', '/'): f.readAsLinesSync(),
};

void main() {
  test('no snack bars: every message is a modal (showAppNotice)', () {
    final bar = RegExp(r'\b(SnackBar(Action)?\s*\(|showSnackBar\b)');
    final offenders = <String>[];
    _libLines().forEach((path, lines) {
      if (path.endsWith('widgets/app_notice.dart')) return;
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('//')) continue;
        if (bar.hasMatch(lines[i])) offenders.add('$path:${i + 1}');
      }
    });
    expect(offenders, isEmpty, reason: 'use showAppNotice / showInfo / showError (lib/src/widgets/app_notice.dart)');
  });

  test('no banners at the top of the app: they are popups too', () {
    // The admin's "Read-only" line is a label on the page, not a message.
    const allowed = {'lib/src/admin/widgets/admin_widgets.dart'};
    final banner = RegExp(r'\b(MaterialBanner\s*\(|showMaterialBanner\b)');
    final offenders = <String>[];
    _libLines().forEach((path, lines) {
      if (allowed.contains(path)) return;
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('//')) continue;
        if (banner.hasMatch(lines[i])) offenders.add('$path:${i + 1}');
      }
    });
    expect(offenders, isEmpty, reason: 'use showAppNotice (lib/src/widgets/app_notice.dart)');
  });

  test("notice ids are 'notice.<area>' and listed in App Page Settings", () {
    final call = RegExp(r"\bshowAppNotice\s*\(\s*id:\s*'([^']+)'");
    final ids = <String>{};
    _libLines().forEach((path, lines) {
      final src = lines.where((l) => !l.trimLeft().startsWith('//')).join('\n');
      for (final m in call.allMatches(src)) {
        ids.add(m.group(1)!);
      }
    });
    expect(ids, isNotEmpty);
    expect(ids.where((id) => !id.startsWith('notice.')), isEmpty);
    final listed = {for (final s in pageInventory) s.id};
    expect(ids.where((id) => !listed.contains('modal:$id')), isEmpty);
  });

  for (final b in Brightness.values) {
    group('notice (${b.name})', () {
      Future<BuildContext> pump(WidgetTester tester) async {
        late BuildContext ctx;
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(b),
            home: Scaffold(
              body: Builder(
                builder: (c) {
                  ctx = c;
                  return const SizedBox();
                },
              ),
            ),
          ),
        );
        return ctx;
      }

      testWidgets('a modal with the message, an icon by kind and OK', (tester) async {
        final ctx = await pump(tester);
        showError(ctx, StateError('That code has expired.'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text('That code has expired.'), findsOneWidget);
        expect(find.byIcon(Icons.error_outline), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('notice-ok')));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
      });

      testWidgets("a snack bar's action is a second button, run once the modal closes", (tester) async {
        final ctx = await pump(tester);
        var undone = 0;
        showAppNotice(
          id: 'notice.test',
          context: ctx,
          message: 'Deleted',
          kind: NoticeKind.success,
          actionLabel: 'Undo',
          onAction: () => undone++,
        );
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
        expect(find.text('Close'), findsOneWidget);
        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();
        expect(undone, 1);
        expect(find.byType(AlertDialog), findsNothing);
      });

      testWidgets('the (x) closes it', (tester) async {
        final ctx = await pump(tester);
        showInfo(ctx, 'Saved');
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('notice-time-left')), findsNothing, reason: 'stays open by default');
        await tester.tap(find.byKey(const ValueKey('notice-close')));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
      });

      testWidgets('closes by itself after the seconds the admin set', (tester) async {
        final ctx = await pump(tester);
        noticeAutoClose.value = const Duration(seconds: 5);
        addTearDown(() => noticeAutoClose.value = Duration.zero);
        showInfo(ctx, 'Saved');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Saved'), findsOneWidget);
        expect(find.byKey(const ValueKey('notice-time-left')), findsOneWidget);
        await tester.pump(const Duration(seconds: 4));
        expect(find.text('Saved'), findsOneWidget);
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
      });

      testWidgets('the next notice replaces the one showing: they never stack', (tester) async {
        final ctx = await pump(tester);
        showInfo(ctx, 'First');
        await tester.pumpAndSettle();
        showInfo(ctx, 'Second');
        showInfo(ctx, 'Third');
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text('Third'), findsOneWidget);
      });
    });
  }

  testWidgets('a page closed right after its message closes, and the message stays', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (home) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                home,
                MaterialPageRoute<void>(
                  builder: (page) => Scaffold(
                    body: TextButton(
                      onPressed: () {
                        showInfo(page, 'Saved');
                        Navigator.pop(page);
                      },
                      child: const Text('Save'),
                    ),
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Save'), findsNothing);
    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
  });
}
