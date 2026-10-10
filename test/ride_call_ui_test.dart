// The rider ↔ driver call screens and the Call buttons that start them, in
// both themes, over a fake call repository and fake audio.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme, routerProvider;
import 'package:get_ride/src/core/ride_call.dart';
import 'package:get_ride/src/core/support_call.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_call_repository.dart';
import 'package:get_ride/src/features/ride/ride_call_screen.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart' show rideStreamProvider;
import 'package:get_ride/src/features/support/call/call_media.dart';
import 'package:get_ride/src/features/support/call/call_session.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';

const rider = 'rider-1', driver = 'driver-1';

Map<String, dynamic> callRow({String status = 'ringing', bool fromRider = true}) => {
  'id': 'k1',
  'request_id': 'r1',
  'caller_id': fromRider ? rider : driver,
  'callee_id': fromRider ? driver : rider,
  'caller_role': fromRider ? 'rider' : 'partner',
  'caller_name': fromRider ? 'Aina' : 'Ravi',
  'callee_name': fromRider ? 'Ravi' : 'Aina',
  'status': status,
  'created_at': DateTime.now().toUtc().toIso8601String(),
};

RideRequest rideRow(String status) => RideRequest({
  'id': 'r1',
  'rider_id': rider,
  'partner_id': driver,
  'rider_name': 'Aina',
  'partner_name': 'Ravi',
  'partner_plate': 'WXY 1234',
  'status': status,
  'drop_name': 'KL Sentral',
});

class _Repo implements RideCallRepository {
  final rows = StreamController<RideCall>.broadcast();
  final incoming = StreamController<RideCall>.broadcast();
  final log = <String>[];
  Map<String, dynamic> current = callRow();
  Object? ringError;
  bool answerWins = true;

  @override
  Future<RideCall> ring(String requestId) async {
    log.add('ring:$requestId');
    if (ringError != null) throw ringError!;
    return RideCall(current);
  }

  @override
  Future<RideCall?> live(String requestId) async => null;

  @override
  Future<RideCall?> fetch(String callId) async => RideCall(current);

  @override
  Future<bool> answer(RideCall call) async {
    log.add('answer:${call.id}');
    return answerWins;
  }

  @override
  Future<void> finish(String callId, CallStatus status) async => log.add('finish:${status.name}');

  @override
  Stream<RideCall> watch(String callId) => rows.stream;

  @override
  Stream<RideCall> watchIncoming(String uid) => incoming.stream;

  @override
  Stream<CallSignal> watchSignals(String callId) => const Stream.empty();

  @override
  Future<void> sendSignal(String callId, String kind, Map<String, dynamic> payload) async => log.add('signal:$kind');

  @override
  Future<List<Map<String, dynamic>>> iceServers() async => parseIceServers(null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Media implements CallMedia {
  final log = <String>[];

  @override
  Future<void> open(
    List<Map<String, dynamic>> iceServers, {
    required void Function(Map<String, dynamic> candidate) onIce,
    required void Function(bool connected) onConnected,
  }) async => log.add('open');

  @override
  Future<Map<String, dynamic>> createOffer() async => {'type': 'offer', 'sdp': 'o'};

  @override
  Future<Map<String, dynamic>> acceptOffer(Map<String, dynamic> offer) async => {'type': 'answer', 'sdp': 'a'};

  @override
  Future<void> acceptAnswer(Map<String, dynamic> answer) async {}

  @override
  Future<void> addIce(Map<String, dynamic> c) async {}

  @override
  Future<void> setMuted(bool muted) async => log.add('muted:$muted');

  @override
  Future<void> setSpeaker(bool on) async => log.add('speaker:$on');

  @override
  Future<void> close() async => log.add('close');
}

void main() {
  late _Repo repo;
  late _Media media;
  late StreamController<RideRequest> rides;
  late List<Uri> dialled;

  Future<GoRouter> pump(
    WidgetTester tester, {
    required String me,
    Brightness brightness = Brightness.light,
    String? phone = '+60123456789',
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 1000);
    addTearDown(tester.view.reset);
    repo = _Repo();
    media = _Media();
    rides = StreamController<RideRequest>.broadcast();
    addTearDown(rides.close);
    dialled = [];
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: Column(
              children: [
                const Text('trip'),
                // The rider's Call button and the driver's compact one.
                RideCallButton(ride: rideRow('accepted'), peerName: me == rider ? 'Ravi' : 'Aina', phone: phone),
                RideCallButton(
                  key: const ValueKey('compact'),
                  ride: rideRow('accepted'),
                  peerName: 'Aina',
                  compact: true,
                ),
              ],
            ),
          ),
        ),
        GoRoute(
          path: '/ride-call/:id',
          builder: (_, s) => RideCallScreen(callId: s.pathParameters['id']!),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rideCallRepositoryProvider.overrideWithValue(repo),
          callMediaFactoryProvider.overrideWithValue(() => media),
          currentUserIdProvider.overrideWithValue(me),
          rideStreamProvider.overrideWith((ref, id) => rides.stream),
          rideCallDialerProvider.overrideWithValue((uri) async {
            dialled.add(uri);
            return true;
          }),
          routerProvider.overrideWithValue(router),
        ],
        child: MaterialApp.router(
          theme: appTheme(brightness),
          routerConfig: router,
          builder: (_, child) => RideCallListener(child: child!),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  Color keyColour(WidgetTester tester, String key) => tester
      .widget<Material>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Material)).first)
      .color!;

  for (final brightness in Brightness.values) {
    testWidgets('the rider calls the driver in the app (${brightness.name})', (tester) async {
      final router = await pump(tester, me: rider, brightness: brightness);
      final scheme = appTheme(brightness).colorScheme;
      await tester.tap(find.byKey(const ValueKey('ride-call')).first);
      await tester.pumpAndSettle();
      expect(repo.log, ['ring:r1']);
      expect(router.state.matchedLocation, '/ride-call/k1');
      expect(find.text('Ravi'), findsOneWidget);
      expect(find.text('Calling…'), findsOneWidget);
      expect(media.log, ['open']);

      rides.add(rideRow('arrived'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Your driver · WXY 1234\nRide to KL Sentral'), findsOneWidget);
      expect(keyColour(tester, 'ride-call-end'), scheme.error);
      expect(tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor, scheme.surface);

      // The driver answers: the caller sends the offer.
      repo.rows.add(RideCall(callRow(status: 'answered')));
      await tester.pump();
      await tester.pump();
      expect(repo.log, contains('signal:offer'));
      expect(find.text('Connecting…'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ride-call-mute')));
      await tester.pump();
      expect(media.log, contains('muted:true'));
      expect(find.text('Unmute'), findsOneWidget);
      expect(keyColour(tester, 'ride-call-mute'), scheme.primary);
      await tester.tap(find.byKey(const ValueKey('ride-call-speaker')));
      await tester.pump();
      expect(media.log, contains('speaker:true'));

      await tester.tap(find.byKey(const ValueKey('ride-call-end')));
      await tester.pump();
      expect(repo.log.last, 'finish:ended');
      expect(find.text('Call ended'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('trip'), findsOneWidget);
      expect(media.log.last, 'close');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the driver answers an incoming call (${brightness.name})', (tester) async {
      final router = await pump(tester, me: driver, brightness: brightness);
      final scheme = appTheme(brightness).colorScheme;
      repo.incoming.add(RideCall(callRow()));
      await tester.pumpAndSettle();
      expect(router.state.matchedLocation, '/ride-call/k1', reason: 'it rings full screen over the trip');
      expect(find.text('Aina'), findsOneWidget);
      expect(find.text('Incoming call'), findsOneWidget);
      expect(find.byKey(const ValueKey('ride-call-mute')), findsNothing);
      expect(keyColour(tester, 'ride-call-accept'), scheme.primary);
      expect(keyColour(tester, 'ride-call-decline'), scheme.error);
      expect(media.log, isEmpty, reason: 'no microphone until it is answered');

      // The same row again doesn't ring twice.
      repo.incoming.add(RideCall(callRow()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('ride-call-accept')));
      await tester.pump();
      await tester.pump();
      expect(repo.log, ['answer:k1']);
      expect(media.log, ['open']);
      expect(find.text('Connecting…'), findsOneWidget);
      expect(find.byKey(const ValueKey('ride-call-mute')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ride-call-end')));
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(repo.log.last, 'finish:ended');
      expect(find.text('trip'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('declining an incoming call', (tester) async {
    await pump(tester, me: driver, brightness: Brightness.dark);
    repo.incoming.add(RideCall(callRow()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ride-call-decline')));
    await tester.pump();
    expect(repo.log, ['finish:declined']);
    expect(media.log, isEmpty);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('trip'), findsOneWidget);
  });

  testWidgets('the caller giving up stops it ringing', (tester) async {
    await pump(tester, me: driver);
    repo.incoming.add(RideCall(callRow()));
    await tester.pumpAndSettle();
    repo.rows.add(RideCall(callRow(status: 'cancelled')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Missed call'), findsOneWidget);
    expect(find.byKey(const ValueKey('ride-call-accept')), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('trip'), findsOneWidget);
    expect(repo.log, isEmpty);
  });

  testWidgets('answering too late says the call has ended', (tester) async {
    await pump(tester, me: driver);
    repo.incoming.add(RideCall(callRow()));
    await tester.pumpAndSettle();
    repo.answerWins = false;
    await tester.tap(find.byKey(const ValueKey('ride-call-accept')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Missed call'), findsOneWidget);
    expect(media.log, isEmpty);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('the ride ending ends the call', (tester) async {
    await pump(tester, me: rider);
    repo.current = callRow(status: 'answered');
    await tester.tap(find.byKey(const ValueKey('ride-call')).first);
    await tester.pumpAndSettle();
    expect(media.log, ['open']);
    rides.add(rideRow('on_trip'));
    await tester.pump();
    expect(repo.log, ['ring:r1', 'signal:offer']);
    rides.add(rideRow('completed'));
    await tester.pump();
    await tester.pump();
    expect(repo.log.last, 'finish:ended');
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('trip'), findsOneWidget);
    expect(media.log.last, 'close');
  });

  for (final brightness in Brightness.values) {
    testWidgets('a long press offers the phone call (${brightness.name})', (tester) async {
      await pump(tester, me: rider, brightness: brightness);
      await tester.longPress(find.byKey(const ValueKey('ride-call')).first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ride-call-in-app')), findsOneWidget);
      expect(find.text('+60123456789'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ride-call-phone')));
      await tester.pumpAndSettle();
      expect(dialled.single.toString(), 'tel:+60123456789');
      expect(repo.log, isEmpty);

      // Without a number there is only the in-app call: nothing to offer.
      await tester.longPress(find.byKey(const ValueKey('compact')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ride-call-phone')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a call that cannot be placed offers the phone instead', (tester) async {
    await pump(tester, me: rider);
    repo.ringError = Exception('SocketException');
    await tester.tap(find.byKey(const ValueKey('ride-call')).first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Check your connection'), findsOneWidget);
    await tester.tap(find.text('Phone call'));
    await tester.pump();
    expect(dialled.single.toString(), 'tel:+60123456789');
  });

  testWidgets('no call button on a ride nobody can call', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 1000);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [currentUserIdProvider.overrideWithValue(rider)],
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                RideCallButton(ride: rideRow('completed'), peerName: 'Ravi'),
                // Before a driver, a number alone still dials.
                RideCallButton(
                  key: const ValueKey('dial-only'),
                  ride: rideRow('open'),
                  peerName: 'Ravi',
                  phone: '+601',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('ride-call')), findsOneWidget);
  });
}
