// SMS fallback for trips (migration 0150): the admin's settings and the card
// that edits them (lib/src/core/sms_fallback.dart,
// lib/src/admin/screens/sms_fallback_card.dart).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/sms_fallback_card.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/sms_fallback.dart';
import 'package:get_ride/src/data/messaging_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

class _Repo extends MessagingRepository {
  _Repo(this.stored) : super(_db);
  SmsFallbackSettings stored;
  final saved = <SmsFallbackSettings>[];

  @override
  Future<SmsFallbackSettings> smsFallback() async => stored;
  @override
  Future<void> saveSmsFallback(SmsFallbackSettings s) async => saved.add(s);
  @override
  Future<SmsFallbackSummary> smsFallbackSummary({int hours = 24}) async =>
      const SmsFallbackSummary(alerts: 40, confirmed: 37, smsQueued: 2, smsSkipped: 1);
}

void main() {
  test('a stored row reads back with safe defaults', () {
    final s = SmsFallbackSettings.fromRow({
      'enabled': true,
      'after_seconds': 90,
      'critical_only': false,
      'channel': 'support_message',
      'per_phone_per_hour': 4,
      'updated_at': '2026-10-11T08:00:00Z',
    });
    expect(s.enabled, isTrue);
    expect(s.afterSeconds, 90);
    expect(s.criticalOnly, isFalse);
    expect(s.channel, 'support_message');
    expect(SmsFallbackSettings.fromRow(s.toPatch()).toPatch(), s.toPatch());

    final odd = SmsFallbackSettings.fromRow({'channel': 'marketing'});
    expect(odd.enabled, isFalse, reason: 'off unless switched on');
    expect(odd.criticalOnly, isTrue);
    expect(odd.channel, 'otp', reason: 'an unknown route falls back to OTP');
  });

  test('settings outside the table\'s checks are not saved', () {
    const ok = SmsFallbackSettings();
    expect(smsFallbackProblem(ok), isNull);
    expect(smsFallbackProblem(ok.copyWith(afterSeconds: 10)), contains('wait'));
    expect(smsFallbackProblem(ok.copyWith(perPhonePerHour: 0)), contains('per hour'));
    expect(smsFallbackProblem(ok.copyWith(channel: 'marketing')), contains('route'));
  });

  test('waits read as minutes and seconds, and the summary as a share', () {
    expect(smsFallbackWaitLabel(30), '30 s');
    expect(smsFallbackWaitLabel(120), '2 min');
    expect(smsFallbackWaitLabel(90), '1 min 30 s');
    final s = smsFallbackSummaryFrom([
      {'alerts': 10, 'confirmed': 9, 'sms_queued': 1, 'sms_skipped': 0},
    ]);
    expect(s.confirmedPercent, 90);
    expect(smsFallbackSummaryFrom(null).confirmedPercent, isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('the admin turns the fallback on and saves it (${brightness.name})', (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = _Repo(const SmsFallbackSettings());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [messagingRepositoryProvider.overrideWithValue(repo)],
          child: MaterialApp(
            theme: appTheme(brightness),
            home: const Scaffold(body: SingleChildScrollView(child: SmsFallbackCard(canEdit: true))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('93%'), findsOneWidget, reason: 'confirmed share in the last 24 hours');

      await tester.tap(find.byKey(const ValueKey('sms-fallback-enabled')));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('sms-fallback-cap')), '3');
      await tester.tap(find.byKey(const ValueKey('sms-fallback-save')));
      await tester.pumpAndSettle();
      expect(repo.saved.single.enabled, isTrue);
      expect(repo.saved.single.perPhonePerHour, 3);
      expect(repo.saved.single.afterSeconds, 60);

      await tester.enterText(find.byKey(const ValueKey('sms-fallback-cap')), '99');
      await tester.tap(find.byKey(const ValueKey('sms-fallback-save')));
      await tester.pumpAndSettle();
      expect(repo.saved, hasLength(1), reason: 'out of range is refused before saving');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a read-only admin can\'t change or save it', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [messagingRepositoryProvider.overrideWithValue(_Repo(const SmsFallbackSettings()))],
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: SmsFallbackCard(canEdit: false))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('sms-fallback-enabled'))).onChanged, isNull);
    expect(find.byKey(const ValueKey('sms-fallback-save')), findsNothing);
  });
}
