import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/support_call.dart';
import 'package:get_ride/src/data/support_call_repository.dart';
import 'package:get_ride/src/features/support/call/call_media.dart';
import 'package:get_ride/src/features/support/call/call_session.dart';

const user = 'user-1', agent = 'agent-1';
final t0 = DateTime.utc(2026, 10, 7, 9);

SupportCall callRow({String status = 'ringing', bool fromUser = true, String? answeredBy, DateTime? createdAt}) =>
    SupportCall({
      'id': 'c1',
      'profile_id': user,
      'caller_role': fromUser ? 'user' : 'admin',
      'caller_id': fromUser ? user : agent,
      'caller_name': fromUser ? 'Aina' : 'Hafiz',
      'answered_by': answeredBy,
      'answered_by_name': answeredBy == null ? null : 'Hafiz',
      'status': status,
      'created_at': (createdAt ?? t0).toIso8601String(),
    });

/// The database between the two ends: the call row and the signals, shared.
class _FakeRepo implements SupportCallRepository {
  final rows = StreamController<SupportCall>.broadcast();
  final signals = StreamController<CallSignal>.broadcast();
  final sent = <({String kind, Map<String, dynamic> payload})>[];
  final finished = <CallStatus>[];
  var _id = 0;
  String sender = user;

  @override
  Stream<SupportCall> watch(String callId) => rows.stream;

  @override
  Stream<CallSignal> watchSignals(String callId) => signals.stream;

  @override
  Future<List<Map<String, dynamic>>> iceServers() async => parseIceServers(null);

  @override
  Future<void> sendSignal(String callId, String kind, Map<String, dynamic> payload) async =>
      sent.add((kind: kind, payload: payload));

  @override
  Future<void> finish(String callId, CallStatus status) async => finished.add(status);

  void signal(String from, String kind, Map<String, dynamic> payload) =>
      signals.add(CallSignal(id: ++_id, sender: from, kind: kind, payload: payload));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMedia implements CallMedia {
  final log = <String>[];
  bool failOpen = false;
  void Function(Map<String, dynamic>)? onIce;
  void Function(bool)? onConnected;

  @override
  Future<void> open(
    List<Map<String, dynamic>> iceServers, {
    required void Function(Map<String, dynamic> candidate) onIce,
    required void Function(bool connected) onConnected,
  }) async {
    if (failOpen) throw Exception('denied');
    this.onIce = onIce;
    this.onConnected = onConnected;
    log.add('open');
  }

  @override
  Future<Map<String, dynamic>> createOffer() async {
    log.add('offer');
    return {'type': 'offer', 'sdp': 'o'};
  }

  @override
  Future<Map<String, dynamic>> acceptOffer(Map<String, dynamic> offer) async {
    log.add('accept-offer:${offer['sdp']}');
    return {'type': 'answer', 'sdp': 'a'};
  }

  @override
  Future<void> acceptAnswer(Map<String, dynamic> answer) async => log.add('accept-answer:${answer['sdp']}');

  @override
  Future<void> addIce(Map<String, dynamic> c) async => log.add('ice:${c['candidate']}');

  @override
  Future<void> setMuted(bool muted) async => log.add('muted:$muted');

  @override
  Future<void> setSpeaker(bool on) async => log.add('speaker:$on');

  @override
  Future<void> close() async => log.add('close');
}

void main() {
  group('rules', () {
    test('who rang and who is on the call', () {
      final c = callRow(answeredBy: agent);
      expect(c.fromUser, isTrue);
      expect(c.startedBy(user), isTrue);
      expect(c.startedBy(agent), isFalse);
      expect(c.involves(agent), isTrue);
      expect(c.involves('someone'), isFalse);
      expect(callRow(fromUser: false).startedBy(agent), isTrue);
    });

    test('a ringing call rings out after the timeout', () {
      final c = callRow();
      expect(rangOut(c, t0.add(const Duration(seconds: 44))), isFalse);
      expect(rangOut(c, t0.add(callRingTimeout)), isTrue);
      expect(rangOut(callRow(status: 'accepted'), t0.add(const Duration(hours: 1))), isFalse);
    });

    test('each end names the other', () {
      expect(callPeerName(callRow(), asAgent: true), 'Aina');
      expect(callPeerName(callRow(), asAgent: false), 'Support');
      expect(callPeerName(callRow(answeredBy: agent), asAgent: false), 'Hafiz');
      expect(callPeerName(callRow(fromUser: false), asAgent: false), 'Hafiz');
      expect(callPeerName(callRow(fromUser: false), asAgent: true, userName: 'Aina R'), 'Aina R');
    });

    test('the headline under the name', () {
      expect(callHeadline(CallStatus.ringing, outgoing: true, connected: false), 'Calling…');
      expect(callHeadline(CallStatus.ringing, outgoing: false, connected: false), 'Incoming call');
      expect(callHeadline(CallStatus.accepted, outgoing: true, connected: false), 'Connecting…');
      expect(
        callHeadline(CallStatus.accepted, outgoing: true, connected: true, elapsed: const Duration(seconds: 75)),
        '1:15',
      );
      expect(callHeadline(CallStatus.missed, outgoing: true, connected: false), 'No answer');
      expect(callHeadline(CallStatus.declined, outgoing: true, connected: false), 'Call declined');
      expect(formatCallDuration(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
    });

    test('ICE servers from turn-credentials, STUN when it says nothing', () {
      expect(
        parseIceServers({
          'iceServers': [
            {'urls': 'stun:s:3478'},
            {
              'urls': ['turn:t:3478'],
              'username': 'u',
              'credential': 'p',
            },
            {'urls': []},
          ],
        }),
        [
          {
            'urls': ['stun:s:3478'],
          },
          {
            'urls': ['turn:t:3478'],
            'username': 'u',
            'credential': 'p',
          },
        ],
      );
      expect(parseIceServers(null).single['urls'], ['stun:stun.l.google.com:19302']);
      expect(parseIceServers({'iceServers': 'nope'}), hasLength(1));
    });

    test('statuses parse, unknown as ended', () {
      expect(CallStatus.parse('accepted'), CallStatus.accepted);
      expect(CallStatus.parse('weird'), CallStatus.ended);
      expect(CallStatus.missed.isOver, isTrue);
      expect(CallStatus.ringing.isOver, isFalse);
    });
  });

  group('session', () {
    late _FakeRepo repo;
    late _FakeMedia media;

    setUp(() {
      repo = _FakeRepo();
      media = _FakeMedia();
    });

    test('the caller offers once answered, then takes the answer and the candidates', () async {
      final s = CallSession(repo: repo, media: media, me: user, call: callRow(), clock: () => t0);
      await s.start();
      expect(s.outgoing, isTrue);
      expect(media.log, ['open']);

      // A candidate the other side sends before its answer waits for it.
      repo.signal(agent, 'ice', {'candidate': 'early'});
      repo.rows.add(callRow(status: 'accepted', answeredBy: agent));
      await pumpEventQueue();
      expect(repo.sent.map((s) => s.kind), ['offer']);
      expect(media.log, ['open', 'offer']);

      repo.signal(agent, 'answer', {'type': 'answer', 'sdp': 'a'});
      repo.signal(agent, 'ice', {'candidate': 'late'});
      await pumpEventQueue();
      expect(media.log, ['open', 'offer', 'accept-answer:a', 'ice:early', 'ice:late']);

      // Its own candidates go to the other side; its own signals are ignored.
      media.onIce!({'candidate': 'mine'});
      repo.signal(user, 'answer', {'sdp': 'echo'});
      await pumpEventQueue();
      expect(repo.sent.map((s) => s.kind), ['offer', 'ice']);
      expect(media.log.where((l) => l.contains('echo')), isEmpty);
      s.dispose();
    });

    test('the side that answers replies to the offer', () async {
      final s = CallSession(
        repo: repo,
        media: media,
        me: agent,
        call: callRow(status: 'accepted', answeredBy: agent),
      );
      await s.start();
      expect(s.outgoing, isFalse);
      repo.signal(user, 'offer', {'type': 'offer', 'sdp': 'o'});
      await pumpEventQueue();
      expect(media.log, ['open', 'accept-offer:o']);
      expect(repo.sent.single.kind, 'answer');
      expect(repo.sent.single.payload['sdp'], 'a');
      s.dispose();
    });

    test('connected starts the clock; mute and speaker reach the audio', () async {
      var now = t0;
      final s = CallSession(
        repo: repo,
        media: media,
        me: agent,
        call: callRow(status: 'accepted', answeredBy: agent),
        clock: () => now,
      );
      await s.start();
      media.onConnected!(true);
      now = t0.add(const Duration(seconds: 12));
      expect(s.connected, isTrue);
      expect(s.elapsed, const Duration(seconds: 12));
      await s.toggleMute();
      await s.toggleSpeaker();
      expect(s.muted, isTrue);
      expect(media.log, containsAllInOrder(['muted:true', 'speaker:true']));
      s.dispose();
    });

    test('the other side hanging up ends it here and releases the microphone', () async {
      final s = CallSession(repo: repo, media: media, me: user, call: callRow(), clock: () => t0);
      await s.start();
      repo.rows.add(callRow(status: 'ended', answeredBy: agent));
      await pumpEventQueue();
      expect(s.isOver, isTrue);
      expect(media.log.last, 'close');
      expect(repo.finished, isEmpty, reason: 'already over; nothing to write');
      s.dispose();
    });

    test('hanging up an incoming call that is still ringing declines it', () async {
      final s = CallSession(repo: repo, media: media, me: user, call: callRow(fromUser: false), clock: () => t0);
      await s.start();
      await s.hangUp();
      expect(repo.finished, [CallStatus.declined]);
      expect(s.status, CallStatus.declined);
      expect(media.log.last, 'close');
    });

    test('an unanswered outgoing call rings out as missed', () async {
      // Started 44.95 s after it was placed: 50 ms of ringing left.
      final now = t0.add(callRingTimeout - const Duration(milliseconds: 50));
      final s = CallSession(repo: repo, media: media, me: user, call: callRow(), clock: () => now);
      await s.start();
      expect(repo.finished, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(repo.finished, [CallStatus.missed]);
      expect(s.isOver, isTrue);
    });

    test('an answered call whose audio never starts is given up', () async {
      final s = CallSession(
        repo: repo,
        media: media,
        me: agent,
        call: callRow(status: 'accepted', answeredBy: agent),
        clock: () => t0,
        connectTimeout: const Duration(milliseconds: 50),
      );
      await s.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(s.error, contains("Couldn't connect"));
      expect(repo.finished, [CallStatus.ended]);
      expect(media.log.last, 'close');
    });

    test('audio that starts in time keeps the call', () async {
      final s = CallSession(
        repo: repo,
        media: media,
        me: agent,
        call: callRow(status: 'accepted', answeredBy: agent),
        clock: () => t0,
        connectTimeout: const Duration(milliseconds: 50),
      );
      await s.start();
      media.onConnected!(true);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(s.error, isNull);
      expect(s.isOver, isFalse);
      s.dispose();
    });

    test('no microphone, no call', () async {
      media.failOpen = true;
      final s = CallSession(repo: repo, media: media, me: user, call: callRow(), clock: () => t0);
      await s.start();
      expect(s.error, contains('microphone'));
      expect(repo.finished, [CallStatus.ended]);
      expect(s.isOver, isTrue);
    });
  });
}
