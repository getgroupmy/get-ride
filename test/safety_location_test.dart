// Safety location case (migration 0337): the one-time modal, the standing
// banner, and the Settings row — and the invariant that the app never acks
// (which is what unlocks server-side background reports) without first showing
// the indicator. Light and dark.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/features/safety/safety_location.dart';
import 'package:get_ride/src/providers.dart';

import 'notice.dart';

/// A fake repository: it hands back a fixed case and records every ack.
class _FakeRepo extends SafetyLocationRepository {
  _FakeRepo(this.value) : super(null);
  SafetyLocationCase? value;
  int ackCalls = 0;

  @override
  Future<SafetyLocationCase?> current() async => value;

  @override
  Future<SafetyLocationCase?> ack() async {
    ackCalls++;
    final v = value;
    if (v != null) value = SafetyLocationCase(style: v.style, reason: v.reason, since: v.since, notified: true);
    return value;
  }
}

ProviderContainer _container(_FakeRepo repo) => ProviderContainer(overrides: [
      currentUserIdProvider.overrideWith((ref) => 'u1'),
      safetyLocationRepositoryProvider.overrideWith((ref) => repo),
    ]);

Future<ProviderContainer> _pump(WidgetTester tester, _FakeRepo repo, Widget child, Brightness b) async {
  final container = _container(repo);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: appTheme(b),
        home: Scaffold(body: SafetyLocationNotice(onInfo: (_) async {}, child: child)),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return container;
}

void main() {
  for (final b in Brightness.values) {
    group('safety location (${b.name})', () {
      testWidgets('modal style: shows once, acks only after it is shown, then not again', (tester) async {
        final repo = _FakeRepo(const SafetyLocationCase(style: 'modal', reason: 'a safety review', notified: false));
        final container = await _pump(tester, repo, const Center(child: Text('page')), b);

        await pumpNotice(tester);
        expect(find.byKey(const ValueKey('safety-location-modal')), findsOneWidget);
        expect(find.text('Background location is on'), findsOneWidget);
        expect(repo.ackCalls, 0, reason: 'must not ack before the user has seen the modal');

        await tester.tap(find.byKey(const ValueKey('notice-ok')));
        await tester.pumpAndSettle();
        expect(repo.ackCalls, 1, reason: 'ack only after the modal has been shown');

        await tester.pump(const Duration(milliseconds: 100));
        await pumpNotice(tester);
        expect(find.byKey(const ValueKey('safety-location-modal')), findsNothing);
        expect(repo.ackCalls, 1);
        container.dispose();
      });

      testWidgets('banner style: renders the green strip and acks on first render', (tester) async {
        final repo = _FakeRepo(const SafetyLocationCase(style: 'banner', reason: 'a safety review', notified: false));
        final container = await _pump(tester, repo, const Center(child: Text('page')), b);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byKey(const ValueKey('safety-location-banner')), findsOneWidget);
        expect(find.text('Live Location Active'), findsOneWidget);
        expect(repo.ackCalls, 1, reason: 'the banner acks on first render (it has been shown)');
        container.dispose();
      });

      testWidgets('no case: no banner, no modal, no ack', (tester) async {
        final repo = _FakeRepo(null);
        final container = await _pump(tester, repo, const Center(child: Text('page')), b);
        await pumpNotice(tester);
        expect(find.byKey(const ValueKey('safety-location-banner')), findsNothing);
        expect(find.byKey(const ValueKey('safety-location-modal')), findsNothing);
        expect(repo.ackCalls, 0, reason: 'the app never acks when nothing has been shown');
        container.dispose();
      });

      testWidgets('Settings row appears while active and is gone when closed', (tester) async {
        final repo = _FakeRepo(SafetyLocationCase(
          style: 'modal',
          reason: 'a safety review',
          since: DateTime(2026, 11, 3),
          notified: true,
        ));
        final container = _container(repo);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: appTheme(b),
              home: const Scaffold(body: SafetyLocationSettingsCard()),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byKey(const ValueKey('safety-location-card')), findsOneWidget);
        expect(find.textContaining('Background location: On'), findsOneWidget);
        expect(find.textContaining('03/11/2026'), findsOneWidget);

        repo.value = null;
        await container.read(safetyLocationProvider.notifier).refresh();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byKey(const ValueKey('safety-location-card')), findsNothing);
        container.dispose();
      });
    });
  }
}
