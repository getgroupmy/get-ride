import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/app.dart' show routerProvider;
import 'package:get_ride/src/core/support_call.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/support_call_repository.dart';
import 'package:get_ride/src/features/support/call/call_media.dart';
import 'package:get_ride/src/features/support/call/call_screen.dart';
import 'package:get_ride/src/features/support/call/call_session.dart';
import 'package:get_ride/src/features/support/call/incoming_call_listener.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';

const user = 'user-1', agent = 'agent-1';

Map<String, dynamic> row({String status = 'ringing', bool fromUser = false, String? answeredBy}) => {
  'id': 'c1',
  'profile_id': user,
  'caller_role': fromUser ? 'user' : 'admin',
  'caller_id': fromUser ? user : agent,
  'caller_name': fromUser ? 'Aina' : 'Hafiz',
  'answered_by': answeredBy,
  'status': status,
  'created_at': DateTime.now().toUtc().toIso8601String(),
};

class _Repo implements SupportCallRepository {
  final incomingUser = StreamController<SupportCall>.broadcast();
  final incomingAgents = StreamController<SupportCall>.broadcast();
  final rows = StreamController<SupportCall>.broadcast();
  final log = <String>[];
  bool answerWins = true;
  Map<String, dynamic> current = row();

  @override
  Stream<SupportCall> watchIncomingForUser(String uid) => incomingUser.stream;

  @override
  Stream<SupportCall> watchIncomingForAgents() => incomingAgents.stream;

  @override
  Future<bool> answer(SupportCall call, {String? agentName}) async {
    log.add('answer:${call.id}');
    return answerWins;
  }

  @override
  Future<void> finish(String callId, CallStatus status) async => log.add('finish:${status.name}');

  @override
  Future<SupportCall> ringSupport({String? ticketId, String? callerName}) async {
    log.add('ring-support:$ticketId:$callerName');
    return SupportCall(row(fromUser: true));
  }

  @override
  Future<SupportCall?> fetch(String callId) async => SupportCall(current);

  @override
  Stream<SupportCall> watch(String callId) => rows.stream;

  @override
  Stream<CallSignal> watchSignals(String callId) => const Stream.empty();

  @override
  Future<List<Map<String, dynamic>>> iceServers() async => parseIceServers(null);

  @override
  Future<void> sendSignal(String callId, String kind, Map<String, dynamic> payload) async => log.add('signal:$kind');

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

  Future<GoRouter> pump(WidgetTester tester, {required String me, bool agentAccess = false}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 1000);
    addTearDown(tester.view.reset);
    repo = _Repo();
    media = _Media();
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: Consumer(
              builder: (c, ref, _) => Column(
                children: [
                  const Text('home'),
                  // The ticket screen's Call button.
                  TextButton(
                    key: const ValueKey('ring'),
                    onPressed: () => callSupport(c, ref, ticketId: 't1', name: 'Aina'),
                    child: const Text('Call support'),
                  ),
                ],
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/call/:id',
          builder: (_, s) => CallScreen(callId: s.pathParameters['id']!),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          supportCallRepositoryProvider.overrideWithValue(repo),
          callMediaFactoryProvider.overrideWithValue(() => media),
          currentUserIdProvider.overrideWithValue(me),
          profileProvider.overrideWith((ref) async => Profile({'id': me, 'name': me == agent ? 'Hafiz' : 'Aina'})),
          moduleAccessProvider.overrideWith((ref, id) => agentAccess ? AccessLevel.edit : AccessLevel.none),
          routerProvider.overrideWithValue(router),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          builder: (_, child) => IncomingCallListener(child: child!),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('a user answers an agent and lands on the call', (tester) async {
    await pump(tester, me: user);
    repo.incomingUser.add(SupportCall(row()));
    await tester.pump();
    await tester.pump();
    expect(find.text('Hafiz is calling'), findsOneWidget);
    repo.current = row(status: 'accepted');
    await tester.tap(find.byKey(const ValueKey('incoming-answer')));
    await tester.pumpAndSettle();
    expect(repo.log, ['answer:c1']);
    expect(find.byKey(const ValueKey('call-peer')), findsOneWidget);
    expect(find.text('Hafiz'), findsOneWidget);
    expect(find.text('Connecting…'), findsOneWidget);
    expect(media.log, ['open']);
    await tester.tap(find.byKey(const ValueKey('call-end')));
    await tester.pump();
    expect(repo.log.last, 'finish:ended');
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(media.log.last, 'close');
  });

  testWidgets('a user turning an agent down declines the call', (tester) async {
    await pump(tester, me: user);
    repo.incomingUser.add(SupportCall(row()));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('incoming-decline')));
    await tester.pump();
    expect(repo.log, ['finish:declined']);
    expect(find.text('Hafiz is calling'), findsNothing);
  });

  testWidgets('agents see users ringing; passing leaves it ringing for the others', (tester) async {
    await pump(tester, me: agent, agentAccess: true);
    repo.incomingAgents.add(SupportCall(row(fromUser: true)));
    await tester.pump();
    await tester.pump();
    expect(find.text('Aina is calling support'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('incoming-decline')));
    await tester.pump();
    expect(repo.log, isEmpty, reason: 'one agent passing does not end the call');
    expect(find.text('Aina is calling support'), findsNothing);
  });

  testWidgets('a call another agent took stops ringing; answering too late says so', (tester) async {
    await pump(tester, me: agent, agentAccess: true);
    repo.incomingAgents.add(SupportCall(row(fromUser: true)));
    await tester.pump();
    await tester.pump();
    repo.incomingAgents.add(SupportCall(row(fromUser: true, status: 'accepted', answeredBy: 'agent-2')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Aina is calling support'), findsNothing);

    repo.incomingAgents.add(SupportCall({...row(fromUser: true), 'id': 'c2'}));
    await tester.pump();
    await tester.pump();
    repo.answerWins = false;
    await tester.tap(find.byKey(const ValueKey('incoming-answer')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Another agent answered this call.'), findsOneWidget);
    expect(find.byKey(const ValueKey('call-peer')), findsNothing);
  });

  testWidgets('users never hear agent-queue calls, and their own calls never ring them', (tester) async {
    await pump(tester, me: user);
    repo.incomingAgents.add(SupportCall(row(fromUser: true)));
    repo.incomingUser.add(SupportCall(row(fromUser: true)));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('incoming-answer')), findsNothing);
  });

  testWidgets('a user rings support from their ticket and waits on the call screen', (tester) async {
    final router = await pump(tester, me: user);
    repo.current = row(fromUser: true);
    await tester.tap(find.byKey(const ValueKey('ring')));
    await tester.pumpAndSettle();
    expect(repo.log, ['ring-support:t1:Aina']);
    expect(router.state.matchedLocation, '/call/c1');
    expect(find.text('Calling…'), findsOneWidget);
    expect(find.text('Support'), findsOneWidget);
    // The agent answers: the caller sends the offer.
    repo.rows.add(SupportCall(row(fromUser: true, status: 'accepted', answeredBy: agent)));
    await tester.pump();
    await tester.pump();
    expect(repo.log, contains('signal:offer'));
    await tester.tap(find.byKey(const ValueKey('call-mute')));
    await tester.pump();
    expect(media.log, contains('muted:true'));
    expect(find.text('Unmute'), findsOneWidget);
    // Leave the test with the call hung up so nothing is left ringing.
    await tester.tap(find.byKey(const ValueKey('call-end')));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });
}
