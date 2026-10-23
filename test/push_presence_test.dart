// The phone's presence for Admin -> God View (migration 0272): the open
// app's check-in every 2 minutes, moved or not, with the area work only
// after ~200 m or 30 minutes; the closed app's report about every 15
// minutes or after ~200 m, only with location already set to always; and
// the bridge to the native reporter.
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/push_logic.dart';
import 'package:get_ride/src/data/background_location.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final t0 = DateTime(2026, 10, 21, 9);

  group('the open app\'s check-in', () {
    test('every 2 minutes while signed in and on screen, moved or not', () {
      expect(pushCheckinEvery, const Duration(minutes: 2));
      expect(pushCheckinDue(signedIn: true, foreground: true, now: t0), isTrue, reason: 'nothing sent yet');
      expect(pushCheckinDue(signedIn: true, foreground: true, now: t0.add(const Duration(seconds: 90)), lastAt: t0), isFalse);
      expect(pushCheckinDue(signedIn: true, foreground: true, now: t0.add(const Duration(minutes: 2)), lastAt: t0), isTrue);
      expect(
        pushCheckinDue(signedIn: true, foreground: true, now: t0.add(const Duration(seconds: 117)), lastAt: t0),
        isTrue,
        reason: 'a timer firing a moment early still counts',
      );
    });

    test('never signed out or in the background (the native reporter does that)', () {
      expect(pushCheckinDue(signedIn: false, foreground: true, now: t0), isFalse);
      expect(pushCheckinDue(signedIn: true, foreground: false, now: t0), isFalse);
      expect(pushCheckinDue(signedIn: true, foreground: false, now: t0.add(const Duration(hours: 1)), lastAt: t0), isFalse);
    });

    test('the area is worked out again only after ~200 m or 30 minutes', () {
      const klcc = LatLng(3.1579, 101.7116);
      // About 330 m north.
      const nearby = LatLng(3.1609, 101.7116);
      // About 110 m north.
      const nextDoor = LatLng(3.1589, 101.7116);
      final soon = t0.add(const Duration(minutes: 2));
      expect(pushLocationMoveMeters, 200);
      expect(shouldReportPushLocation(point: nextDoor, now: soon, lastPoint: klcc, lastAt: t0), isFalse);
      expect(shouldReportPushLocation(point: nearby, now: soon, lastPoint: klcc, lastAt: t0), isTrue);
      expect(
        shouldReportPushLocation(point: klcc, now: t0.add(const Duration(minutes: 30)), lastPoint: klcc, lastAt: t0),
        isTrue,
      );
    });
  });

  group('the closed app\'s report', () {
    test('about every 15 minutes, or after ~200 m (0276)', () {
      expect(backgroundReportDue(), isTrue, reason: 'nothing sent yet');
      expect(backgroundReportDue(sinceLast: const Duration(minutes: 5), movedMetres: 120), isFalse);
      expect(backgroundReportDue(sinceLast: const Duration(minutes: 5)), isFalse, reason: 'no fix to compare');
      expect(backgroundReportDue(sinceLast: const Duration(minutes: 15), movedMetres: 0), isTrue);
      expect(backgroundReportDue(sinceLast: const Duration(minutes: 3), movedMetres: 200), isTrue);
      expect(backgroundReportDue(sinceLast: const Duration(minutes: 3), movedMetres: 199), isFalse);
      expect((backgroundReportEvery, backgroundReportMoveMeters), (const Duration(minutes: 15), 200.0));
    });

    test('only signed in, with tokens, and location already set to always', () {
      expect(backgroundReportingWanted(signedIn: true, locationAlways: true, hasTokens: true), isTrue);
      expect(backgroundReportingWanted(signedIn: true, locationAlways: false, hasTokens: true), isFalse);
      expect(backgroundReportingWanted(signedIn: false, locationAlways: true, hasTokens: true), isFalse);
      expect(backgroundReportingWanted(signedIn: true, locationAlways: true, hasTokens: false), isFalse);
    });
  });

  group('the native bridge', () {
    late List<MethodCall> calls;
    setUp(() {
      calls = [];
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        backgroundLocationChannel,
        (call) async {
          calls.add(call);
          return call.method == 'arm' ? true : null;
        },
      );
    });
    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backgroundLocationChannel, null));

    test('a key is 64 hex characters, kept per install until sign-out', () async {
      expect(newBackgroundKey(Random(1)), matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(newBackgroundKey(), isNot(newBackgroundKey()));
      final bg = BackgroundLocation(supportedOverride: true);
      final k = await bg.key();
      expect(await bg.key(), k);
      await bg.disarm(forgetKey: true);
      expect(await bg.key(), isNot(k));
    });

    test('arm hands the project and the key to the phone; disarm stops it', () async {
      final bg = BackgroundLocation(supportedOverride: true);
      final key = newBackgroundKey();
      expect(await bg.arm(url: 'https://x.supabase.co', anonKey: 'anon', key: key), isTrue);
      expect(calls.single.method, 'arm');
      expect(calls.single.arguments, {'url': 'https://x.supabase.co', 'anonKey': 'anon', 'key': key});
      await bg.disarm();
      expect(calls.last.method, 'disarm');
    });

    test('nothing on the web or desktop, or without the project', () async {
      final none = BackgroundLocation(supportedOverride: false);
      expect(await none.arm(url: 'https://x.supabase.co', anonKey: 'anon', key: newBackgroundKey()), isFalse);
      await none.disarm();
      expect(await BackgroundLocation(supportedOverride: true).arm(url: '', anonKey: 'anon', key: 'k' * 64), isFalse);
      expect(calls, isEmpty);
    });

    test('a build without the native half answers false', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(backgroundLocationChannel, null);
      final bg = BackgroundLocation(supportedOverride: true);
      expect(await bg.arm(url: 'https://x.supabase.co', anonKey: 'anon', key: newBackgroundKey()), isFalse);
    });
  });
}
