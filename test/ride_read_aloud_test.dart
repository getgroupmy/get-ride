// The passenger's messages read aloud on the driver's trip screen
// (lib/src/core/ride_read_aloud.dart, lib/src/data/read_aloud.dart).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/ride_chat.dart';
import 'package:get_ride/src/core/ride_read_aloud.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/read_aloud.dart';
import 'package:get_ride/src/data/ride_chat_repository.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/partner/partner_trip_screen.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart' show rideStreamProvider;
import 'package:get_ride/src/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

RideMessage msg(String id, String from, {String? body, RideMessageType type = RideMessageType.text}) => RideMessage(
  id: id,
  requestId: 'r1',
  senderId: from,
  senderRole: from == 'driver' ? RideChatRole.partner : RideChatRole.rider,
  type: type,
  body: body,
);

class _Speaker implements Speaker {
  final said = <String>[];
  int stops = 0;
  @override
  Future<void> speak(String text) async => said.add(text);
  @override
  Future<void> stop() async => stops++;
}

class _Rides implements RideRepository {
  @override
  Future<void> publishPartnerLocation(String id, double lat, double lng, double? heading) async {}
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

RideRequest _ride(String status) => RideRequest({
  'id': 'r1',
  'rider_id': 'rider',
  'partner_id': 'driver',
  'rider_name': 'Aina',
  'status': status,
  'pickup_name': 'KLCC',
  'drop_name': 'KL Sentral',
  'pickup_lat': 3.1579,
  'pickup_lng': 101.7116,
  'drop_lat': 3.134,
  'drop_lng': 101.686,
});

void main() {
  test('what is said names the passenger and says what they sent', () {
    expect(rideMessageSpeech(msg('m', 'rider', body: '  At the\n gate '), 'Aina'), 'Aina says: At the gate');
    expect(
      rideMessageSpeech(msg('m', 'rider', type: RideMessageType.quick, body: 'Coming'), ''),
      'Your passenger says: Coming',
    );
    expect(rideMessageSpeech(msg('m', 'rider', type: RideMessageType.location), 'Aina'), 'Aina shared a location.');
    expect(rideMessageSpeech(msg('m', 'rider', type: RideMessageType.image), 'Aina'), 'Aina sent a photo.');
    expect(rideMessageSpeech(msg('m', 'rider', type: RideMessageType.audio), 'Aina'), 'Aina sent a voice note.');
    expect(rideMessageSpeech(msg('m', 'rider', body: ' '), 'Aina'), 'Aina sent a message.');
  });

  test('a long message is cut at a word', () {
    final said = rideMessageSpeech(msg('m', 'rider', body: List.filled(80, 'word').join(' ')), 'Aina');
    expect(said.length, lessThan(rideReadAloudMaxChars + 20));
    expect(said, endsWith('word…'));
  });

  test('only the other side\'s messages not yet heard are read', () {
    final thread = [msg('m1', 'rider'), msg('m2', 'driver'), msg('m3', 'rider')];
    expect(rideMessagesToReadAloud(thread, me: 'driver', heard: {'m1'}).map((m) => m.id), ['m3']);
  });

  for (final brightness in Brightness.values) {
    testWidgets('the driver hears new passenger messages, not the history, and can turn it off (${brightness.name})', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final thread = StreamController<List<RideMessage>>.broadcast();
      addTearDown(thread.close);
      final speaker = _Speaker();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            rideRepositoryProvider.overrideWithValue(_Rides()),
            rideMessagesProvider.overrideWith((ref, id) => thread.stream),
            rideStreamProvider.overrideWith((ref, id) => Stream.value(_ride('accepted'))),
            tripFixProvider.overrideWithValue(() async => null),
            currentUserIdProvider.overrideWithValue('driver'),
            speakerProvider.overrideWithValue(speaker),
          ],
          child: MaterialApp(
            theme: appTheme(brightness),
            home: const PartnerTripScreen(requestId: 'r1'),
          ),
        ),
      );
      await tester.pump();
      final history = [msg('m1', 'rider', body: 'Booked it')];
      thread.add(history);
      await tester.pump();
      expect(speaker.said, isEmpty, reason: 'what was there before is not news');

      thread.add([...history, msg('m2', 'rider', body: 'At the gate'), msg('m3', 'driver', body: 'OK')]);
      await tester.pump();
      expect(speaker.said, ['Aina says: At the gate']);

      await tester.tap(find.byKey(const ValueKey('read-aloud-toggle')));
      await tester.pump();
      expect(find.text("Messages won't be read aloud."), findsOneWidget);
      expect(speaker.stops, 1);
      thread.add([...history, msg('m2', 'rider', body: 'At the gate'), msg('m4', 'rider', body: 'Blue shirt')]);
      await tester.pump();
      expect(speaker.said, hasLength(1), reason: 'switched off');
      expect((await SharedPreferences.getInstance()).getBool('ride_read_aloud_v1'), isFalse);
      expect(tester.takeException(), isNull);
    });
  }
}
