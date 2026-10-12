// Admin → SMS / WhatsApp → Reliability (lib/src/core/reliability_settings.dart,
// lib/src/admin/screens/reliability_card.dart).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/reliability_card.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/reliability_settings.dart';
import 'package:get_ride/src/data/reliability_repository.dart';

class _Repo implements ReliabilityRepository {
  _Repo(this.stored);
  ReliabilitySettings stored;
  final saved = <ReliabilitySettings>[];
  bool refuse = false;

  @override
  Future<ReliabilitySettings> fetch() async => stored;

  @override
  Future<void> save(ReliabilitySettings s) async {
    if (refuse) throw Exception('permission denied');
    saved.add(s);
    stored = s;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  test('every switch is on unless the admin turned it off', () {
    const all = ReliabilitySettings();
    expect(ReliabilitySettings.fromValues(null), all);
    expect(ReliabilitySettings.fromValues({'chat_outbox': 'nonsense', 'ride_cache': null}), all);
    final off = ReliabilitySettings.fromValues({
      'chat_outbox': false,
      'ride_cache': 'false',
      'background_ack': 0,
      'read_aloud': 'off',
    });
    expect(ReliabilitySettings.keys.map((k) => off[k]), everyElement(isFalse));
  });

  test('a switch is set by its key, and survives being stored and read back', () {
    final s = const ReliabilitySettings().withSwitch('ride_cache', false);
    expect(s.rideCache, isFalse);
    expect(s['ride_cache'], isFalse);
    expect(s.chatOutbox, isTrue);
    expect(ReliabilitySettings.fromValues(s.toValues()), s);
    expect(s.withSwitch('unknown', false), s, reason: 'an unknown key changes nothing');
  });

  for (final brightness in Brightness.values) {
    testWidgets('the admin flips a switch and it is saved at once (${brightness.name})', (tester) async {
      final repo = _Repo(const ReliabilitySettings());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [reliabilityRepositoryProvider.overrideWithValue(repo)],
          child: MaterialApp(
            theme: appTheme(brightness),
            home: const Scaffold(body: SingleChildScrollView(child: ReliabilityCard(canEdit: true))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Trips open with no connection'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('reliability-ride_cache')));
      await tester.pumpAndSettle();
      expect(repo.saved.single.rideCache, isFalse);
      expect(repo.saved.single.chatOutbox, isTrue);
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('reliability-ride_cache'))).value, isFalse);

      repo.refuse = true;
      await tester.tap(find.byKey(const ValueKey('reliability-chat_outbox')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byKey(const ValueKey('reliability-chat_outbox'))).value,
        isTrue,
        reason: 'a refused save puts the switch back',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a read-only admin sees the switches but can\'t move them', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [reliabilityRepositoryProvider.overrideWithValue(_Repo(const ReliabilitySettings()))],
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: ReliabilityCard(canEdit: false))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('reliability-chat_outbox'))).onChanged, isNull);
  });
}
