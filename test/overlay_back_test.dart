// Browser Back on the web (tester findings #48, #106): the first Back
// closes the open sheet, modal, menu, picker or side menu and stays on the
// page; closing one any other way leaves no entry behind, so the next Back
// still leaves the page; nested ones (a dropdown over a dialog) unwind one
// per Back; off the web nothing changes.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/overlay_back.dart';
import 'package:get_ride/src/widgets/page_style_host.dart';
import 'package:get_ride/src/widgets/side_menu_host.dart';
import 'package:get_ride/src/widgets/web_overlay_back.dart';

/// A browser's history list, and a router that goes where Back lands
/// unless the stack takes it.
class _Browser implements OverlayHistory {
  _Browser() {
    stack = OverlayBackStack(this, session: 't');
  }

  late final OverlayBackStack stack;

  /// (address, marker) per entry.
  final entries = <(String, String?)>[('/prev', null), ('/a', null)];
  int at = 1;

  /// The page the app shows.
  String router = '/a';
  int settles = 0;

  @override
  String get page => entries[at].$1;

  @override
  Future<void> push(String marker) async {
    entries.removeRange(at + 1, entries.length);
    entries.add((page, marker));
    at++;
  }

  @override
  void go(int delta) => scheduleMicrotask(() {
    at += delta;
    final (address, marker) = entries[at];
    if (!stack.onPop(marker, address)) router = address;
  });

  /// The browser's Back button.
  void back() => go(-1);

  /// The router pushing a page.
  void navigate(String address) {
    entries.removeRange(at + 1, entries.length);
    entries.add((address, null));
    at++;
    router = address;
  }

  @override
  Future<void> settled() async => settles++;

  String? get marker => entries[at].$2;
}

void main() {
  group('the history bookkeeping', () {
    test('off the web it does nothing', () {
      final b = _Browser();
      final off = OverlayBackStack(b, enabled: false);
      var closed = false;
      expect(off.open(() => closed = true), isNull);
      expect(off.onPop(null, '/a'), isFalse);
      expect(b.entries, hasLength(2));
      expect(closed, isFalse);
    });

    test('opening adds an entry for the same address; Back closes it and stays; Back again navigates', () async {
      final b = _Browser();
      var closes = 0;
      final e = b.stack.open(() => closes++);
      await pumpEventQueue();
      expect(b.entries, hasLength(3));
      expect(b.page, '/a');
      expect(b.marker, e!.marker);

      b.back();
      await pumpEventQueue();
      expect(closes, 1);
      expect(b.router, '/a');
      expect(b.at, 1);
      expect(b.stack.markers, isEmpty);
      // The route's future completes after the Back closed it: nothing more.
      b.stack.closed(e);
      await pumpEventQueue();
      expect(b.at, 1);

      b.back();
      await pumpEventQueue();
      expect(b.router, '/prev');
    });

    test('closed another way, its entry goes and the next Back navigates', () async {
      final b = _Browser();
      var closes = 0;
      final e = b.stack.open(() => closes++);
      await pumpEventQueue();
      b.stack.closed(e);
      await pumpEventQueue();
      expect(b.at, 1);
      expect(b.marker, isNull);
      // The move back was its own: nobody heard of it.
      expect(b.router, '/a');
      expect(b.settles, 1);
      expect(closes, 0);

      b.back();
      await pumpEventQueue();
      expect(b.router, '/prev');
    });

    test('nested overlays unwind one per Back', () async {
      final b = _Browser();
      final closed = <String>[];
      b.stack.open(() => closed.add('sheet'));
      b.stack.open(() => closed.add('dialog'));
      await pumpEventQueue();
      expect(b.entries, hasLength(4));

      b.back();
      await pumpEventQueue();
      expect(closed, ['dialog']);
      b.back();
      await pumpEventQueue();
      expect(closed, ['dialog', 'sheet']);
      expect(b.router, '/a');
      b.back();
      await pumpEventQueue();
      expect(b.router, '/prev');
    });

    test('a dialog closed by its button leaves the sheet under it for the next Back', () async {
      final b = _Browser();
      final closed = <String>[];
      b.stack.open(() => closed.add('sheet'));
      final dialog = b.stack.open(() => closed.add('dialog'));
      await pumpEventQueue();
      b.stack.closed(dialog);
      await pumpEventQueue();
      expect(b.at, 2);

      b.back();
      await pumpEventQueue();
      expect(closed, ['sheet']);
      expect(b.router, '/a');
    });

    test('two closed at once go back together', () async {
      final b = _Browser();
      final sheet = b.stack.open(() {});
      final dialog = b.stack.open(() {});
      await pumpEventQueue();
      b.stack.closed(dialog);
      b.stack.closed(sheet);
      await pumpEventQueue();
      expect(b.at, 1);
      b.back();
      await pumpEventQueue();
      expect(b.router, '/prev');
    });

    test('a sheet closing straight into a modal: the modal gets the entry', () async {
      final b = _Browser();
      final sheet = b.stack.open(() {});
      await pumpEventQueue();
      b.stack.closed(sheet);
      // After the sheet's result came back.
      await Future<void>.microtask(() {});
      var closes = 0;
      b.stack.open(() => closes++);
      await pumpEventQueue();
      expect(b.marker, isNotNull);

      b.back();
      await pumpEventQueue();
      expect(closes, 1);
      expect(b.router, '/a');
      b.back();
      await pumpEventQueue();
      expect(b.router, '/prev');
    });

    test('opened and closed before its turn, it never gets an entry', () async {
      final b = _Browser();
      final sheet = b.stack.open(() {});
      await pumpEventQueue();
      b.stack.closed(sheet);
      final quick = b.stack.open(() {});
      b.stack.closed(quick);
      await pumpEventQueue();
      expect(b.at, 1);
      expect(b.marker, isNull);
    });

    test('a jump further back (the history list) closes the overlay and lets the router go', () async {
      final b = _Browser();
      var closes = 0;
      b.stack.open(() => closes++);
      await pumpEventQueue();
      b.go(-2);
      await pumpEventQueue();
      expect(closes, 1);
      expect(b.router, '/prev');
    });

    test("another visit's entry is the router's", () {
      final b = _Browser();
      b.stack.open(() {});
      expect(b.stack.onPop('old-3', '/a'), isFalse);
    });

    test('a side menu slot keeps one entry while open', () async {
      final b = _Browser();
      final slot = OverlayBackSlot(() => b.stack);
      var closes = 0;
      void close() {
        closes++;
        slot.set(false, close);
      }

      slot.set(true, close);
      slot.set(true, close);
      await pumpEventQueue();
      expect(b.entries, hasLength(3));
      b.back();
      await pumpEventQueue();
      expect(closes, 1);
      expect(b.router, '/a');

      // Opened again, then closed by a tap on the page.
      slot.set(true, close);
      await pumpEventQueue();
      slot.set(false, close);
      await pumpEventQueue();
      expect(b.at, 1);
      b.back();
      await pumpEventQueue();
      expect(b.router, '/prev');
    });

    test('the marker is read from an entry state', () {
      expect(overlayMarkerIn({'location': '/a', overlayBackMarkerKey: 'x-1'}), 'x-1');
      expect(overlayMarkerIn({'location': '/a'}), isNull);
      expect(overlayMarkerIn(null), isNull);
    });
  });

  group('the app helpers', () {
    // Made inside each test, so its futures run on the test's clock.
    _Browser install() {
      final before = webOverlayBack;
      addTearDown(() => webOverlayBack = before);
      final b = _Browser();
      webOverlayBack = b.stack;
      return b;
    }

    // The app's navigators carry the observer on the web (app.dart).
    Widget app(Widget Function(BuildContext) home) =>
        MaterialApp(navigatorObservers: [WebOverlayBackObserver()], home: Builder(builder: home));

    testWidgets('off the web the sheet adds no entry', (tester) async {
      final b = install();
      webOverlayBack = OverlayBackStack(b, enabled: false);
      await tester.pumpWidget(
        app(
          (c) => TextButton(
            onPressed: () => showAppSheet(id: 'test.sheet', context: c, builder: (_) => const Text('sheet')),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('sheet'), findsOneWidget);
      expect(b.entries, hasLength(2));
    });

    testWidgets('Back closes a sheet; a tap outside takes its entry off', (tester) async {
      final b = install();
      await tester.pumpWidget(
        app(
          (c) => Scaffold(
            body: TextButton(
              onPressed: () => showAppSheet(id: 'test.sheet', context: c, builder: (_) => const Text('sheet')),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(b.marker, isNotNull);

      b.back();
      await tester.pumpAndSettle();
      expect(find.text('sheet'), findsNothing);
      expect(b.at, 1);
      expect(b.router, '/a');

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(b.marker, isNotNull);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('sheet'), findsNothing);
      expect(b.at, 1);
      expect(b.marker, isNull);
      b.back();
      await tester.pumpAndSettle();
      expect(b.router, '/prev');
    });

    testWidgets('a dialog opened from a sheet: Back closes the dialog, then the sheet', (tester) async {
      final b = install();
      await tester.pumpWidget(
        app(
          (c) => Scaffold(
            body: TextButton(
              onPressed: () => showAppSheet(
                id: 'test.sheet',
                context: c,
                builder: (s) => TextButton(
                  onPressed: () => showAppDialog(
                    id: 'test.dialog',
                    context: s,
                    builder: (_) => const AlertDialog(content: Text('dialog')),
                  ),
                  child: const Text('ask'),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ask'));
      await tester.pumpAndSettle();
      expect(b.entries, hasLength(4));

      b.back();
      await tester.pumpAndSettle();
      expect(find.text('dialog'), findsNothing);
      expect(find.text('ask'), findsOneWidget);
      b.back();
      await tester.pumpAndSettle();
      expect(find.text('ask'), findsNothing);
      expect(b.router, '/a');
    });

    testWidgets('a sheet that will not close now stays open with its entry back', (tester) async {
      final b = install();
      var asked = 0;
      await tester.pumpWidget(
        app(
          (c) => Scaffold(
            body: TextButton(
              onPressed: () => showAppSheet(
                id: 'test.sheet',
                context: c,
                builder: (_) => PopScope(
                  canPop: false,
                  onPopInvokedWithResult: (didPop, _) => asked++,
                  child: const Text('unsaved'),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      b.back();
      await tester.pumpAndSettle();
      expect(find.text('unsaved'), findsOneWidget);
      expect(asked, 1);
      expect(b.marker, isNotNull);
      expect(b.stack.markers, hasLength(1));
    });

    testWidgets('a sheet opened through showAppSheet gets exactly one entry', (tester) async {
      final b = install();
      await tester.pumpWidget(
        app(
          (c) => TextButton(
            onPressed: () => showAppSheet(id: 'test.sheet', context: c, builder: (_) => const Text('sheet')),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(b.entries, hasLength(3));
      expect(b.stack.markers, hasLength(1));
    });

    testWidgets('a dropdown menu over a dialog: Back closes the menu, then the dialog', (tester) async {
      final b = install();
      await tester.pumpWidget(
        app(
          (c) => TextButton(
            onPressed: () => showAppDialog(
              id: 'test.dialog',
              context: c,
              builder: (_) => AlertDialog(
                content: DropdownButton<int>(
                  value: 1,
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('Level 1')),
                    DropdownMenuItem(value: 2, child: Text('Level 2')),
                  ],
                  onChanged: (_) {},
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Level 1'));
      await tester.pumpAndSettle();
      expect(find.text('Level 2'), findsOneWidget);
      expect(b.entries, hasLength(4));

      b.back();
      await tester.pumpAndSettle();
      expect(find.text('Level 2'), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget);
      b.back();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(b.router, '/a');
      b.back();
      await tester.pumpAndSettle();
      expect(b.router, '/prev');
    });

    testWidgets('a pick in the dropdown menu takes its entry off; the dialog keeps its own', (tester) async {
      final b = install();
      await tester.pumpWidget(
        app(
          (c) => TextButton(
            onPressed: () => showAppDialog(
              id: 'test.dialog',
              context: c,
              builder: (_) => AlertDialog(
                content: DropdownButton<int>(
                  value: 1,
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('Level 1')),
                    DropdownMenuItem(value: 2, child: Text('Level 2')),
                  ],
                  onChanged: (_) {},
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Level 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Level 2').last);
      await tester.pumpAndSettle();
      expect(b.at, 2);
      b.back();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(b.router, '/a');
    });

    testWidgets('a popup menu: Back closes it and stays', (tester) async {
      final b = install();
      await tester.pumpWidget(
        app(
          (c) => Scaffold(
            body: PopupMenuButton<int>(
              itemBuilder: (_) => const [PopupMenuItem(value: 1, child: Text('Edit'))],
              child: const Text('more'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('more'));
      await tester.pumpAndSettle();
      expect(find.text('Edit'), findsOneWidget);
      expect(b.marker, isNotNull);
      b.back();
      await tester.pumpAndSettle();
      expect(find.text('Edit'), findsNothing);
      expect(b.router, '/a');
      b.back();
      await tester.pumpAndSettle();
      expect(b.router, '/prev');
    });

    testWidgets('a date picker: Back closes it; Cancel takes its entry off', (tester) async {
      final b = install();
      await tester.pumpWidget(
        app(
          (c) => TextButton(
            onPressed: () => showDatePicker(context: c, firstDate: DateTime(2026), lastDate: DateTime(2027), initialDate: DateTime(2026, 10, 18)),
            child: const Text('date'),
          ),
        ),
      );
      await tester.tap(find.text('date'));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
      b.back();
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsNothing);
      expect(b.at, 1);

      await tester.tap(find.text('date'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(b.at, 1);
      expect(b.marker, isNull);
      b.back();
      await tester.pumpAndSettle();
      expect(b.router, '/prev');
    });

    testWidgets('a full page pushed over the app gets no entry', (tester) async {
      final b = install();
      await tester.pumpWidget(
        app(
          (c) => TextButton(
            onPressed: () => Navigator.of(c).push(AppPageRoute<void>(id: 'test.page', builder: (_) => const Text('page'))),
            child: const Text('push'),
          ),
        ),
      );
      await tester.tap(find.text('push'));
      await tester.pumpAndSettle();
      expect(find.text('page'), findsOneWidget);
      expect(b.entries, hasLength(2));
    });

    testWidgets('Back closes the side menu', (tester) async {
      final b = install();
      await tester.pumpWidget(
        MaterialApp(
          home: SideMenuHost(
            menu: const ColoredBox(color: Colors.white, child: Text('menu')),
            child: Scaffold(
              body: Builder(
                builder: (c) => TextButton(onPressed: SideMenuHost.of(c)!.open, child: const Text('open')),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('menu'), findsOneWidget);
      expect(b.marker, isNotNull);

      b.back();
      await tester.pumpAndSettle();
      expect(find.text('menu'), findsNothing);
      expect(b.router, '/a');

      // Closed by a tap on the page: no entry left behind.
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('side-menu-scrim')));
      await tester.pumpAndSettle();
      expect(b.at, 1);
      b.back();
      await tester.pumpAndSettle();
      expect(b.router, '/prev');
    });
  });
}
