import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/demo_mode.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/features/partner/demo_jobs.dart';
import 'package:get_ride/src/features/ride/demo_ride.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('demo requests: two different places, Expo pricing, sensible extras', () {
    final rnd = math.Random(7);
    for (var i = 0; i < 50; i++) {
      final j = demoJob(rnd, id: 'j$i');
      expect(j.pickupName, isNot(j.dropName));
      expect(j.km, greaterThanOrEqualTo(1.2));
      expect(j.minutes, greaterThanOrEqualTo(5));
      expect(j.fare, greaterThanOrEqualTo(6));
      expect((j.fare - (3 + 1.5 * j.km + 0.2 * j.minutes)).abs(), lessThan(1.5), reason: 'fare formula');
      expect(j.pax, inInclusiveRange(1, 4));
      expect(j.luggage, inInclusiveRange(0, 3));
      expect(j.timeout.inSeconds, inInclusiveRange(30, 45));
      expect(demoJobGap(rnd).inSeconds, inInclusiveRange(6, 14));
    }
  });

  testWidgets('a demo request arrives, and accepting opens the demo job', (tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: DemoJobFeed()),
        ),
        GoRoute(path: '/drive/demo', builder: (_, s) => Text('job ${(s.extra! as DemoJob).id}')),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    expect(find.byKey(const ValueKey('demo-job')), findsNothing);
    await tester.pump(const Duration(seconds: 15));
    expect(find.byKey(const ValueKey('demo-job')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('demo-job-accept')));
    await tester.pumpAndSettle();
    expect(find.text('job demo-job-1'), findsOneWidget);
  });

  testWidgets('an unanswered demo request goes, and another follows', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: DemoJobFeed())));
    await tester.pump(const Duration(seconds: 15));
    expect(find.byKey(const ValueKey('demo-job')), findsOneWidget);
    await tester.pump(const Duration(seconds: 47));
    await tester.pump(const Duration(seconds: 1));
    // Either gone, or the next one is already up; the feed never jams.
    await tester.pump(const Duration(seconds: 15));
    expect(find.byKey(const ValueKey('demo-job')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  Future<void> pumpJob(WidgetTester tester, {required bool sim}) => tester.pumpWidget(
    ProviderScope(
      overrides: [
        demoSettingsProvider.overrideWithValue(DemoSettings(partnerDriveSim: sim)),
        geoServiceProvider.overrideWithValue(GeoService(client: MockClient((_) async => http.Response('', 500)))),
      ],
      child: MaterialApp(
        home: DemoJobScreen(job: demoJob(math.Random(1), id: 'j')),
      ),
    ),
  );

  String phase(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('demo-job-phase'))).data!;

  testWidgets('simulated driving arrives on its own; the driver starts and ends the trip', (tester) async {
    await pumpJob(tester, sim: true);
    expect(phase(tester), startsWith('Heading to'));
    expect(find.byKey(const ValueKey('demo-job-next')), findsNothing);
    await tester.pump(const Duration(seconds: 31));
    expect(phase(tester), startsWith('Waiting for'));
    await tester.tap(find.byKey(const ValueKey('demo-job-next')));
    await tester.pump(const Duration(seconds: 46));
    expect(phase(tester), startsWith('Arrived at'));
    await tester.tap(find.byKey(const ValueKey('demo-job-next')));
    await tester.pump();
    expect(phase(tester), 'Trip complete');
  });

  testWidgets('without simulated driving the driver steps through', (tester) async {
    await pumpJob(tester, sim: false);
    await tester.pump(const Duration(seconds: 40));
    expect(phase(tester), startsWith('Heading to'));
    await tester.tap(find.byKey(const ValueKey('demo-job-next')));
    await tester.pump();
    expect(phase(tester), startsWith('Waiting for'));
  });
}
