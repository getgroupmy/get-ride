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

  testWidgets('a Waze estimate says Waze and live traffic', (tester) async {
    await pump(tester, const RouteEstimate(distanceKm: 4.6, durationMin: 14, provider: 'waze'));
    expect(find.byKey(const ValueKey('route-source-waze')), findsOneWidget);
    expect(find.text('Waze'), findsOneWidget);
    expect(find.textContaining('with traffic'), findsOneWidget);
    expect(find.byIcon(Icons.auto_awesome), findsNothing);
  });

  testWidgets('an AI provider estimate keeps the AI mark', (tester) async {
    await pump(tester, const RouteEstimate(distanceKm: 4.4, durationMin: 13, provider: 'gemini'));
    expect(find.byKey(const ValueKey('route-source-ai')), findsOneWidget);
    expect(find.text('AI'), findsOneWidget);
  });

  testWidgets('an OSRM estimate says Road and never claims live traffic', (tester) async {
    await pump(tester, const RouteEstimate(distanceKm: 4.5, durationMin: 9, provider: 'osrm'));
    expect(find.byKey(const ValueKey('route-source-road')), findsOneWidget);
    expect(find.text('Road'), findsOneWidget);
    expect(find.textContaining('with traffic'), findsNothing);
    expect(find.textContaining('without live traffic'), findsOneWidget);
  });

  test('the source follows the provider; an older proxy estimate is the AI', () {
    expect(EstimateSource.of(const RouteEstimate(distanceKm: 1, durationMin: 1, provider: 'waze')), EstimateSource.waze);
    expect(EstimateSource.of(const RouteEstimate(distanceKm: 1, durationMin: 1, provider: 'osrm')), EstimateSource.road);
    expect(EstimateSource.of(const RouteEstimate(distanceKm: 1, durationMin: 1, provider: 'claude')), EstimateSource.ai);
    expect(EstimateSource.of(const RouteEstimate(distanceKm: 1, durationMin: 1)), EstimateSource.ai);
  });
}
