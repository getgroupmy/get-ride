// Earnings → My ratings (0297): the driver's totals per tag, totals only.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/ride_rating.dart';
import 'package:get_ride/src/data/ride_rating_repository.dart';
import 'package:get_ride/src/features/partner/driver_ratings_screen.dart';

Future<void> _pump(WidgetTester tester, Brightness b, DriverTagTotals totals) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [myDriverTagTotalsProvider.overrideWith((ref, days) async => totals)],
      child: MaterialApp(theme: appTheme(b), home: const DriverRatingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final b in Brightness.values) {
    testWidgets('the rating, what riders liked and what to work on (${b.name})', (tester) async {
      await _pump(
        tester,
        b,
        DriverTagTotals.fromJson({
          'days': 30,
          'rating': 4.8,
          'rated': 212,
          'tags': [
            {'tag': 'Friendly', 'low': false, 'n': 71},
            {'tag': 'Safe driving', 'low': false, 'n': 96},
            {'tag': 'Late to pickup', 'low': true, 'n': 4},
          ],
        }),
      );
      expect(find.text('My ratings'), findsOneWidget);
      expect(find.text('4.8'), findsOneWidget);
      expect(find.text('From 212 rated trips · last 30 days'), findsOneWidget);
      final liked = find.byKey(const ValueKey('driver-ratings-liked'));
      expect(find.descendant(of: liked, matching: find.text('Safe driving')), findsOneWidget);
      expect(find.descendant(of: liked, matching: find.text('Late to pickup')), findsNothing);
      // Most picked first.
      expect(
        tester.getTopLeft(find.text('Safe driving')).dy < tester.getTopLeft(find.text('Friendly')).dy,
        isTrue,
      );
      final work = find.byKey(const ValueKey('driver-ratings-work-on'));
      expect(find.descendant(of: work, matching: find.text('Late to pickup')), findsOneWidget);
      expect(find.textContaining('Totals only'), findsOneWidget);
      expect(find.textContaining('flag', findRichText: true), findsNothing, reason: 'the admin flag is not shown');
      expect(
        find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Safe driving: 96'),
        findsOneWidget,
        reason: 'a screen reader hears the tag and its count',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('no ratings yet (${b.name})', (tester) async {
      await _pump(tester, b, const DriverTagTotals());
      expect(find.text('–'), findsOneWidget);
      expect(find.text('From 0 rated trips · last 30 days'), findsOneWidget);
      expect(find.text('No tags yet.'), findsOneWidget);
      expect(find.text('Nothing here. Keep it up.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
