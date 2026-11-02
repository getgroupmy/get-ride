// The passenger is told while the driver's VoiceProtection records their trip
// (the owner's decision, migration 0335). The server's half is in
// supabase/tests/recording_notice_0335.sql.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/demo/demo_script.dart';
import 'package:get_ride/src/core/family.dart';
import 'package:get_ride/src/core/fare_coins.dart' show FareCoinRedemption;
import 'package:get_ride/src/core/help_kb.dart';
import 'package:get_ride/src/core/store_review.dart';
import 'package:get_ride/src/core/user_guide.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/partner/partner_trip_screen.dart' show voiceRecordingDriverLine;
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/features/safety/driver_recording_notice.dart';
import 'package:get_ride/src/providers.dart';

RideRequest _ride(String status, {bool audio = false}) => RideRequest({
  'id': 'r1',
  'rider_id': 'me',
  'partner_id': 'driver',
  'partner_name': 'Ali',
  'status': status,
  'fare': 20,
  'currency': 'MYR',
  'pickup_name': 'KLCC',
  'drop_name': 'KL Sentral',
  'driver_audio': audio,
});

class _FakeRides implements RideRepository {
  @override
  Future<double> claimRideReward(RideRequest r) async => 0;

  @override
  Future<FareCoinRedemption?> redeemFareCoins(RideRequest r) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _app(Widget child, Brightness b) => MaterialApp(
  theme: ThemeData(brightness: b, useMaterial3: true),
  home: Scaffold(body: child),
);

final _notice = find.byKey(const ValueKey('driver-recording-notice'));

void main() {
  group('the ride row', () {
    test('recording only while the trip is under way', () {
      expect(_ride('on_trip', audio: true).driverRecordingNow, isTrue);
      expect(_ride('on_trip').driverRecordingNow, isFalse);
      for (final s in ['accepted', 'arrived', 'completed', 'cancelled']) {
        expect(_ride(s, audio: true).driverRecordingNow, isFalse, reason: s);
      }
    });

    test('Family: the host\'s live list carries it', () {
      final item = FamilyLiveItem.fromJson({'memberId': 'm1', 'name': 'Aisha', 'trip': 't1', 'driverAudio': true});
      expect(item.driverAudio, isTrue);
      expect(FamilyLiveItem.fromJson({'memberId': 'm1', 'name': 'Aisha'}).driverAudio, isFalse);
      expect(FamilyLiveItem.fromJson(demoFamilyLiveJson(DateTime(2026, 11, 2))).driverAudio, isTrue,
          reason: 'the store review demo shows it (simulated)');
    });
  });

  for (final b in Brightness.values) {
    group('the notice (${b.name})', () {
      testWidgets('shows only while recording, with Learn more', (tester) async {
        await tester.pumpWidget(_app(const DriverRecordingNotice(recording: false), b));
        expect(_notice, findsNothing);

        await tester.pumpWidget(_app(const DriverRecordingNotice(recording: true), b));
        expect(_notice, findsOneWidget);
        expect(find.text(driverRecordingNoticeText), findsOneWidget);
        expect(find.byKey(const ValueKey('driver-recording-learn-more')), findsOneWidget);
        expect(tester.getSize(find.byKey(const ValueKey('driver-recording-learn-more'))).height,
            greaterThanOrEqualTo(44));
        expect(driverRecordingLearnMoreUrl, endsWith('/privacy#audio'));
        expect(find.bySemanticsLabel(driverRecordingNoticeText), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('on the passenger\'s trip screen: comes and goes with the ride row', (tester) async {
        tester.view.physicalSize = const Size(1200, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final rows = StreamController<RideRequest>();
        addTearDown(rows.close);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              rideRepositoryProvider.overrideWithValue(_FakeRides()),
              rideStreamProvider.overrideWith((ref, id) => rows.stream),
            ],
            child: MaterialApp(
              theme: ThemeData(brightness: b, useMaterial3: true),
              home: const RideTrackingScreen(requestId: 'r1'),
            ),
          ),
        );
        rows.add(_ride('on_trip'));
        await tester.pump();
        await tester.pump();
        expect(_notice, findsNothing, reason: 'the driver is not recording');

        rows.add(_ride('on_trip', audio: true));
        await tester.pump();
        await tester.pump();
        expect(_notice, findsOneWidget);
        expect(find.text(driverRecordingNoticeText), findsOneWidget);

        rows.add(_ride('on_trip'));
        await tester.pump();
        await tester.pump();
        expect(_notice, findsNothing, reason: 'recording stopped');

        rows.add(_ride('completed', audio: true));
        await tester.pump();
        await tester.pump();
        expect(_notice, findsNothing, reason: 'the trip ended');
        await tester.pumpWidget(const SizedBox());
      });
    });
  }

  group('wording', () {
    test('the driver is told the passenger sees it', () {
      expect(voiceRecordingDriverLine, contains('passenger sees'));
    });

    test('nothing says the passenger is not told', () {
      final mic = permissionNoticeItems.firstWhere((i) => i.id == 'microphone').why;
      expect(mic, contains('Your driver is recording audio for safety'));
      expect(mic, isNot(contains('not told')));
      final voice = helpKnowledgeBase.firstWhere((a) => a.keywords.contains('voiceprotection')).answer;
      expect(voice, contains('passenger sees'));
      final guide = userGuide.expand((s) => s.topics).firstWhere((t) => t.title == 'VoiceProtection').body;
      expect(guide, contains('passenger sees a notice'));
      final privacy = File('web/privacy.html').readAsStringSync();
      expect(privacy, contains('The passenger sees a notice'));
      expect(privacy, isNot(contains('The passenger is not told')));
      final notes = File('docs/store_review_notes.md').readAsStringSync();
      expect(notes, isNot(contains('passenger is not')));
    });
  });
}
