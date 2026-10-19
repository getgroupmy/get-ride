import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/user_guide.dart';
import 'package:get_ride/src/features/profile/user_guide_screen.dart';

void main() {
  test('search matches section titles, topic titles and text', () {
    expect(searchGuide(''), userGuide);
    final wallet = searchGuide('wallet');
    expect(wallet.map((s) => s.title), contains('Wallet'));
    expect(
      wallet.firstWhere((s) => s.title == 'Wallet').topics,
      userGuide.firstWhere((s) => s.title == 'Wallet').topics,
    );
    final pin = searchGuide('PIN');
    expect(pin.expand((s) => s.topics).map((t) => t.title), contains('Forgot your PIN'));
    expect(searchGuide('zzzz'), isEmpty);
  });

  test('every topic has a title and text', () {
    for (final s in userGuide) {
      expect(s.topics, isNotEmpty, reason: s.title);
      for (final t in s.topics) {
        expect(t.title.trim(), isNotEmpty);
        expect(t.body.trim().length, greaterThan(20), reason: t.title);
      }
    }
  });

  testWidgets('searching opens the matching topics', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 1400);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: UserGuideScreen()));
    expect(find.text('Getting started'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('guide-search')), 'destination mode');
    await tester.pumpAndSettle();
    expect(find.text('Destination mode'), findsOneWidget);
    expect(find.textContaining('at least 2 km closer'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('guide-search')), 'qqqq');
    await tester.pumpAndSettle();
    expect(find.text('Nothing matches "qqqq".'), findsOneWidget);
  });

  for (final b in Brightness.values) {
    testWidgets('an opened topic draws no rule outside its card (${b.name})', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 915);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: ThemeData(brightness: b), home: const UserGuideScreen()));
      await tester.enterText(find.byKey(const ValueKey('guide-search')), 'wallet');
      await tester.pumpAndSettle();
      final tiles = tester.widgetList<ExpansionTile>(find.byType(ExpansionTile)).toList();
      expect(tiles, isNotEmpty);
      for (final tile in tiles) {
        expect(tile.initiallyExpanded, isTrue);
        expect(tile.shape, const Border(), reason: 'no divider above or below an open topic');
        expect(tile.collapsedShape, const Border());
      }
      for (final card in tester.widgetList<Card>(find.byType(Card))) {
        expect(card.clipBehavior, Clip.antiAlias, reason: 'the tiles stay inside the rounded corners');
      }
      expect(tester.takeException(), isNull);
    });
  }
}
