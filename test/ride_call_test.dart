// Rider ↔ driver calls (migration 0131): the rules, and one end of a call on
// the shared call engine.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/push_logic.dart';
import 'package:get_ride/src/core/ride_call.dart';
import 'package:get_ride/src/core/ride_chat.dart';
import 'package:get_ride/src/core/support_call.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_call_repository.dart';
import 'package:get_ride/src/features/support/call/call_media.dart';
import 'package:get_ride/src/features/support/call/call_session.dart';

const rider = 'rider-1', driver = 'driver-1';
final t0 = DateTime.utc(2026, 10, 9, 9);

RideCall rideCall({String status = 'ringing', bool fromRider = true, String? callerName = 'Aina'}) => RideCall({
  'id': 'k1',
  'request_id': 'r1',
  'caller_id': fromRider ? rider : driver,
  'callee_id': fromRider ? driver : rider,
  'caller_role': fromRider ? 'rider' : 'partner',
  'caller_name': fromRider ? callerName : 'Ravi',
  'callee_name': fromRider ? 'Ravi' : callerName,
  'status': status,
  'created_at': t0.toIso8601String(),
  'answered_at': status == 'answered' ? t0.add(const Duration(seconds: 5)).toIso8601String() : null,
});

RideRequest ride(String status, {String? partner = driver}) => RideRequest({
  'id': 'r1',
  'rider_id': rider,
  'partner_id': partner,
  'status': status,
  'partner_plate': 'WXY 1234',
  'drop_name': 'KL Sentral',
});

class _FakeRepo implements RideCallRepository {
  final rows = StreamController<RideCall>.broadcast();
  final signals = StreamController<CallSignal>.broadcast();
  final sent = <String>[];
  final finished = <CallStatus>[];

  @override
  Stream<RideCall> watch(String callId) => rows.stream;

  @override
  Stream<CallSignal> watchSignals(String callId) => signals.stream;

  @override
  Future<List<Map<String, dynamic>>> iceServers() async => parseIceServers(null);

  @override
  Future<void> sendSignal(String callId, String kind, Map<String, dynamic> payload) async => sent.add(kind);

  @override
  Future<void> finish(String callId, CallStatus status) async => finished.add(status);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMedia implements CallMedia {
  final log = <String>[];

  @override
  Future<void> open(
    List<Map<String, dynamic>> iceServers, {
    required void Function(Map<String, dynamic> candidate) onIce,
    required void Function(bool connected) onConnected,
  }) async => log.add('open');

  @override
  Future<Map<String, dynamic>> createOffer() async {
    log.add('offer');
    return {'type': 'offer', 'sdp': 'o'};
  }

  @override
  Future<Map<String, dynamic>> acceptOffer(Map<String, dynamic> offer) async {
    log.add('accept-offer');
    return {'type': 'answer', 'sdp': 'a'};
  }

  @override
  Future<void> acceptAnswer(Map<String, dynamic> answer) async => log.add('accept-answer');

  @override
  Future<void> addIce(Map<String, dynamic> c) async {}

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  Future<void> setSpeaker(bool on) async {}

  @override
  Future<void> close() async => log.add('close');
}

void main() {
  group('rules', () {
    test('the database says answered where the engine says accepted', () {
      expect(rideCallStatusName(CallStatus.accepted), 'answered');
      expect(rideCallStatusName(CallStatus.cancelled), 'cancelled');
      expect(parseRideCallStatus('answered'), CallStatus.accepted);
      expect(parseRideCallStatus('cancelled'), CallStatus.cancelled);
      expect(parseRideCallStatus('weird'), CallStatus.ended);
      expect(rideCall(status: 'answered').status, CallStatus.accepted);
      expect(rideCall().withStatus(CallStatus.accepted).raw['status'], 'answered');
      expect(CallStatus.cancelled.isOver, isTrue);
    });

    test('who is on the call, who rang, and when it was answered', () {
      final c = rideCall();
      expect(c.callerRole, RideChatRole.rider);
      expect(c.startedBy(rider), isTrue);
      expect(c.startedBy(driver), isFalse);
      expect(c.involves(driver), isTrue);
      expect(c.involves('someone'), isFalse);
      expect(c.startedAt, isNull);
      expect(rideCall(status: 'answered').startedAt, t0.add(const Duration(seconds: 5)));
    });

    test('hanging up: the caller cancels, the callee declines, either ends', () {
      expect(rideCall().hangUpStatus(outgoing: true), CallStatus.cancelled);
      expect(rideCall().hangUpStatus(outgoing: false), CallStatus.declined);
      expect(rideCall(status: 'answered').hangUpStatus(outgoing: true), CallStatus.ended);
      expect(rideCall(status: 'answered').hangUpStatus(outgoing: false), CallStatus.ended);
    });

    test('who can do what, and when', () {
      final c = rideCall();
      final soon = t0.add(const Duration(seconds: 10));
      expect(canAnswerRideCall(c, driver, soon), isTrue);
      expect(canAnswerRideCall(c, rider, soon), isFalse, reason: 'not your own call');
      expect(canAnswerRideCall(c, 'someone', soon), isFalse);
      expect(canAnswerRideCall(c, driver, t0.add(callRingTimeout)), isFalse, reason: 'it rang out');
      expect(canAnswerRideCall(rideCall(status: 'cancelled'), driver, soon), isFalse);
      expect(canCancelRideCall(c, rider), isTrue);
      expect(canCancelRideCall(c, driver), isFalse);
      expect(canCancelRideCall(rideCall(status: 'answered'), rider), isFalse);
      expect(canEndRideCall(c, rider), isFalse, reason: 'a ringing call is cancelled, not ended');
      expect(canEndRideCall(rideCall(status: 'answered'), driver), isTrue);
      expect(canEndRideCall(rideCall(status: 'answered'), 'someone'), isFalse);
      expect(rangOut(c, t0.add(const Duration(seconds: 44))), isFalse);
      expect(rangOut(c, t0.add(callRingTimeout)), isTrue);
    });

    test('calls only while a driver is on the job', () {
      for (final s in ['accepted', 'arrived', 'on_trip']) {
        expect(rideCallsAvailable(ride(s)), isTrue, reason: s);
        expect(rideCallMustEnd(RideStatus.parse(s)), isFalse, reason: s);
      }
      for (final s in ['open', 'completed', 'cancelled', 'expired']) {
        expect(rideCallsAvailable(ride(s)), isFalse, reason: s);
        expect(rideCallMustEnd(RideStatus.parse(s)), isTrue, reason: s);
      }
      expect(rideCallsAvailable(ride('accepted', partner: null)), isFalse);
      expect(rideCallsAvailable(ride('accepted', partner: rider)), isFalse, reason: 'nobody to call');
    });

    test('each end sees the other, and the ride the call is about', () {
      final c = rideCall();
      expect(rideCallPeerName(c, driver), 'Aina');
      expect(rideCallPeerName(c, rider), 'Ravi');
      expect(rideCallPeerName(rideCall(callerName: null), driver), 'Your passenger');
      expect(rideCallPeerName(RideCall({...c.raw, 'callee_name': ' '}), rider), 'Your driver');
      expect(rideCallContext(c, rider, ride: ride('accepted')), 'Your driver · WXY 1234\nRide to KL Sentral');
      expect(rideCallContext(c, driver, ride: ride('accepted')), 'Your passenger\nRide to KL Sentral');
      expect(rideCallContext(c, driver), 'Your passenger');
    });

    test('a finished call goes back to the ride, on the right side', () {
      expect(rideCallHome(rideCall(), rider), '/ride/r1');
      expect(rideCallHome(rideCall(), driver), '/drive/trip/r1');
      expect(rideCallHome(rideCall(fromRider: false), driver), '/drive/trip/r1');
      expect(rideCallHome(rideCall(fromRider: false), rider), '/ride/r1');
    });

    test('why a call could not be placed', () {
      expect(rideCallFailure('PostgrestException(code: 23505)'), 'There is already a call on this ride.');
      expect(rideCallFailure('RIDE_CALL_NOT_ALLOWED'), 'Calls are only available during the ride.');
      expect(rideCallFailure('SocketException'), contains('connection'));
    });

    test('tapping the notification opens the incoming call', () {
      expect(
        pushRouteFor({'type': 'ride_call', 'request_id': 'r1', 'call_id': 'k1', 'role': 'partner'}),
        '/ride-call/k1',
      );
      expect(pushRouteFor({'type': 'ride_call', 'request_id': 'r1'}), isNull);
    });

    test('the headline for a call the caller gave up on', () {
      expect(callHeadline(CallStatus.cancelled, outgoing: true, connected: false), 'Call cancelled');
      expect(callHeadline(CallStatus.cancelled, outgoing: false, connected: false), 'Missed call');
    });
  });

  group('session', () {
    late _FakeRepo repo;
    late _FakeMedia media;

    setUp(() {
      repo = _FakeRepo();
      media = _FakeMedia();
    });

    test('the caller offers once the other side answers', () async {
      final s = CallSession<RideCall>(repo: repo, media: media, me: rider, call: rideCall(), clock: () => t0);
      await s.start();
      expect(s.outgoing, isTrue);
      repo.rows.add(rideCall(status: 'answered'));
      await pumpEventQueue();
      expect(repo.sent, ['offer']);
      repo.signals.add(const CallSignal(id: 1, sender: driver, kind: 'answer', payload: {'sdp': 'a'}));
      await pumpEventQueue();
      expect(media.log, ['open', 'offer', 'accept-answer']);
      await s.hangUp();
      expect(repo.finished, [CallStatus.ended]);
      s.dispose();
    });

    test('the caller hanging up before an answer cancels', () async {
      final s = CallSession<RideCall>(repo: repo, media: media, me: rider, call: rideCall(), clock: () => t0);
      await s.start();
      await s.hangUp();
      expect(repo.finished, [CallStatus.cancelled]);
      expect(s.call.raw['status'], 'cancelled');
      expect(media.log.last, 'close');
      s.dispose();
    });

    test('the answering side replies to the offer', () async {
      final s = CallSession<RideCall>(
        repo: repo,
        media: media,
        me: driver,
        call: rideCall(status: 'answered'),
        clock: () => t0,
      );
      await s.start();
      expect(s.outgoing, isFalse);
      repo.signals.add(const CallSignal(id: 1, sender: rider, kind: 'offer', payload: {'sdp': 'o'}));
      await pumpEventQueue();
      expect(repo.sent, ['answer']);
      expect(media.log, ['open', 'accept-offer']);
      s.dispose();
    });

    test('nobody answering: the caller records it missed', () async {
      final s = CallSession<RideCall>(
        repo: repo,
        media: media,
        me: rider,
        call: rideCall(),
        clock: () => t0.add(callRingTimeout),
      );
      await s.start();
      await Future<void>.delayed(Duration.zero);
      await pumpEventQueue();
      expect(repo.finished, [CallStatus.missed]);
      expect(s.isOver, isTrue);
      s.dispose();
    });

    test('the other side ending it ends it here', () async {
      final s = CallSession<RideCall>(
        repo: repo,
        media: media,
        me: driver,
        call: rideCall(status: 'answered'),
        clock: () => t0,
      );
      await s.start();
      repo.rows.add(rideCall(status: 'ended'));
      await pumpEventQueue();
      expect(s.isOver, isTrue);
      expect(media.log.last, 'close');
      expect(repo.finished, isEmpty);
      s.dispose();
    });
  });
}
