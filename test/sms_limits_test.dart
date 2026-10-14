// Sign-in SMS limits (lib/src/core/sms_limits.dart).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/sms_limits_card.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/sms_limits.dart';

import 'quiet_live.dart';

void main() {
  _cardTests();
  test('reads the settings row, with the defaults for anything missing', () {
    final s = SmsLimits.fromRow({
      'enabled': false,
      'per_phone_per_hour': 5,
      'allowed_prefixes': ['+60', '+65'],
      'updated_at': '2026-10-11T07:00:00Z',
    });
    expect(s.enabled, isFalse);
    expect(s.perPhonePerHour, 5);
    expect(s.perPhonePerDay, 10);
    expect(s.codeValidMinutes, 5, reason: 'a row without the 0188 column reads as 5 minutes');
    expect(s.allowedPrefixes, ['+60', '+65']);
    expect(s.blockedNumbers, isEmpty);
    expect(s.messageTemplate, defaultSmsTemplate);
    expect(s.updatedAt, DateTime.utc(2026, 10, 11, 7));
    expect(s.toPatch()['per_phone_per_hour'], 5);
    expect(s.toPatch().containsKey('updated_at'), isFalse, reason: 'the database stamps it');
  });

  test('the defaults are valid', () => expect(smsLimitsProblem(const SmsLimits()), isNull));

  test('refuses what the database would refuse', () {
    const s = SmsLimits();
    expect(smsLimitsProblem(s.copyWith(perPhonePerHour: 0)), contains('per hour'));
    expect(smsLimitsProblem(s.copyWith(perPhonePerHour: 21)), contains('per hour'));
    expect(smsLimitsProblem(s.copyWith(perPhonePerDay: 51)), contains('per day'));
    expect(smsLimitsProblem(s.copyWith(perPhonePerHour: 5, perPhonePerDay: 4)), contains('daily limit'));
    expect(smsLimitsProblem(s.copyWith(minResendSeconds: 10)), contains('Time between'));
    expect(smsLimitsProblem(s.copyWith(globalPerHour: 0)), contains('hourly total'));
    expect(smsLimitsProblem(s.copyWith(codeValidMinutes: 0)), contains('valid for'));
    expect(smsLimitsProblem(s.copyWith(codeValidMinutes: 61)), contains('valid for'));
    expect(SmsLimits.fromRow({'code_valid_minutes': 3}).toPatch()['code_valid_minutes'], 3);
    expect(smsLimitsProblem(s.copyWith(allowedPrefixes: ['60'])), contains('country prefix'));
    expect(smsLimitsProblem(s.copyWith(blockedNumbers: ['0123456789'])), contains('blocked number'));
    expect(smsLimitsProblem(s.copyWith(messageTemplate: 'No code')), contains('{code}'));
    expect(smsLimitsProblem(s.copyWith(messageTemplate: '{code}${'x' * 300}')), contains('300'));
  });

  test('an empty prefix list allows every country', () {
    expect(smsLimitsProblem(const SmsLimits().copyWith(allowedPrefixes: [])), isNull);
  });

  test('phone lists are tidied to +<digits>, without repeats', () {
    expect(parsePhoneList('+60, +65\n+60;  +62'), ['+60', '+65', '+62']);
    expect(parsePhoneList('+60 12-345 6789, 60123456789'), ['+60123456789']);
    expect(parsePhoneList(''), isEmpty);
    expect(parsePhoneList(' , ;'), isEmpty);
  });

  test('numbers are masked in the activity panel', () {
    expect(maskPhone('+60123456789'), '+6012•••6789');
    expect(maskPhone('+123'), '+123');
  });

  test('every refusal has words', () {
    for (final r in [
      'disabled',
      'gateway_offline',
      'blocked_number',
      'prefix',
      'resend_too_soon',
      'per_phone_hour',
      'per_phone_day',
      'global_hour',
    ]) {
      expect(smsReasonLabel(r), isNot(r), reason: r);
    }
    expect(smsReasonLabel(null), '');
  });

  test('the hourly summary reads a row or a one-row list', () {
    expect(
      smsActivityFrom([
        {'queued': 4, 'blocked': 2, 'failed': 1},
      ]),
      (queued: 4, blocked: 2, failed: 1),
    );
    expect(smsActivityFrom({'queued': 1}), (queued: 1, blocked: 0, failed: 0));
    expect(smsActivityFrom(null), (queued: 0, blocked: 0, failed: 0));
  });
}

// The card itself: on a phone-width screen the "Last changed" line used to
// sit beside a full-width Save button and was squeezed one letter wide.
Future<void> _pumpCard(WidgetTester tester, Brightness b) async {
  tester.view.physicalSize = const Size(400, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      ...quietLiveOverrides,
      smsLimitsProvider.overrideWith((_) async => SmsLimits.fromRow({'updated_at': '2026-10-11T07:53:00Z'})),
      smsActivityProvider.overrideWith((_) async => smsActivityFrom(null)),
      smsLogProvider.overrideWith((_, _) async => const <SmsLogEntry>[]),
    ],
    child: MaterialApp(
      theme: appTheme(b),
      home: const Scaffold(body: SingleChildScrollView(child: SmsLimitsCard(canEdit: true))),
    ),
  ));
  await tester.pumpAndSettle();
}

void _cardTests() {
  for (final b in Brightness.values) {
    testWidgets('the last-changed line reads across the card, with Save below it (${b.name})', (tester) async {
      await _pumpCard(tester, b);
      final changed = find.byKey(const ValueKey('sms-limits-changed'));
      expect(changed, findsOneWidget);
      expect(tester.getSize(changed).width, greaterThan(250), reason: 'across the card, not one letter per line');
      expect(tester.getTopLeft(find.byKey(const ValueKey('sms-limits-save'))).dy,
          greaterThan(tester.getBottomLeft(changed).dy));
      expect(tester.takeException(), isNull);
    });
  }
}
