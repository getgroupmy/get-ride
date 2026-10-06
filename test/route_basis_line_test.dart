import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/route_estimate.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/features/ride/home_screen.dart';

void main() {
  const route = RouteInfo(distanceKm: 8.6, durationMin: 16, points: []);

  Future<void> pump(WidgetTester tester, RouteEstimate? ai) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: RouteBasisLine(route: route, ai: ai),
      ),
    ),
  );

  testWidgets('the AI mark shows when the AI Fare Service priced the route', (tester) async {
    await pump(tester, const RouteEstimate(distanceKm: 9.1, durationMin: 21));
    expect(find.byKey(const ValueKey('route-ai')), findsOneWidget);
    expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
    expect(find.textContaining('with traffic'), findsOneWidget);
  });

  testWidgets('and not on the plain road route', (tester) async {
    await pump(tester, null);
    expect(find.byKey(const ValueKey('route-ai')), findsNothing);
    expect(find.textContaining('with traffic'), findsNothing);
  });
}
