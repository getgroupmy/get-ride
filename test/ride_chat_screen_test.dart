// The rider ↔ driver chat screen and the Message buttons that open it, in
// both themes.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/ride_chat.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_chat_repository.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/partner/partner_trip_screen.dart';
import 'package:get_ride/src/features/ride/ride_chat_screen.dart';
import 'package:get_ride/src/data/fare_coin_store.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/features/wallet/wallet_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Repo implements RideChatRepository {
  final rows = StreamController<List<RideMessage>>.broadcast();
  final sent = <String>[];
  final marked = <String>[];

  @override
  Stream<List<RideMessage>> watch(String requestId) => rows.stream;

  @override
  Future<void> sendText(String requestId, RideChatRole role, String body, {bool quick = false}) async =>
      sent.add('${role.name}:${quick ? 'quick' : 'text'}:$body');

  @override
  Future<void> sendLocation(String requestId, RideChatRole role, double lat, double lng) async =>
      sent.add('${role.name}:location:$lat,$lng');

  @override
  Future<void> mark(List<String> ids, RideMessageStatus to) async => marked.add('${ids.join(',')}:${to.name}');

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Rides implements RideRepository {
  @override
  Future<void> publishPartnerLocation(String id, double lat, double lng, double? heading) async {}

  @override
  Future<void> publishRiderLocation(String id, double lat, double lng) async {}

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

RideRequest _ride(String status) => RideRequest({
  'id': 'r1',
  'rider_id': 'rider',
  'partner_id': 'driver',
  'rider_name': 'Aina',
  'partner_name': 'Ravi',
  'partner_phone': '+60123456789',
  'status': status,
  'pickup_name': 'KLCC',
  'drop_name': 'KL Sentral',
  'pickup_lat': 3.1579,
  'pickup_lng': 101.7116,
  'drop_lat': 3.134,
  'drop_lng': 101.686,
});

RideMessage _msg(
  String id,
  String from,
  String body, {
  RideMessageStatus status = RideMessageStatus.sent,
  int minute = 0,
}) => RideMessage(
  id: id,
  requestId: 'r1',
  senderId: from,
  senderRole: from == 'rider' ? RideChatRole.rider : RideChatRole.partner,
  type: RideMessageType.text,
  body: body,
  status: status,
  createdAt: DateTime.now().subtract(Duration(minutes: 30 - minute)),
);

void main() {
  Future<(_Repo, List<Uri>)> pumpChat(
    WidgetTester tester, {
    required String me,
    required String status,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = const Size(500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = _Repo();
    final opened = <Uri>[];
    addTearDown(repo.rows.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rideChatRepositoryProvider.overrideWithValue(repo),
          rideStreamProvider.overrideWith((ref, id) => Stream.value(_ride(status))),
          currentUserIdProvider.overrideWithValue(me),
          tripFixProvider.overrideWithValue(() async => const LatLng(2.93, 101.83)),
          rideChatLauncherProvider.overrideWithValue((uri) async {
            opened.add(uri);
            return true;
          }),
        ],
        child: MaterialApp(
          theme: appTheme(brightness),
          home: const RideChatScreen(requestId: 'r1'),
        ),
      ),
    );
    await tester.pump();
    return (repo, opened);
  }

  for (final brightness in Brightness.values) {
    testWidgets('the rider chats with the driver (${brightness.name})', (tester) async {
      final (repo, opened) = await pumpChat(tester, me: 'rider', status: 'accepted', brightness: brightness);
      repo.rows.add([
        _msg('m1', 'rider', 'At the gate', status: RideMessageStatus.read),
        _msg('m2', 'driver', "I'm on my way", minute: 1),
        RideMessage(
          id: 'm3',
          requestId: 'r1',
          senderId: 'driver',
          senderRole: RideChatRole.partner,
          type: RideMessageType.location,
          latitude: 3.1,
          longitude: 101.6,
          status: RideMessageStatus.delivered,
          createdAt: DateTime.now(),
        ),
      ]);
      await tester.pump();
      await tester.pump();

      expect(find.text('Ravi'), findsOneWidget);
      expect(find.text('Your driver'), findsOneWidget);
      expect(find.byKey(const ValueKey('ride-chat-day-Today')), findsOneWidget);
      expect(find.text('At the gate'), findsOneWidget);
      expect(find.byKey(const ValueKey('tick-read-m1')), findsOneWidget);
      expect(find.byKey(const ValueKey('tick-sent-m2')), findsNothing, reason: 'theirs carry no tick');

      // Mine on the right in the primary colour, theirs on the left.
      final scheme = appTheme(brightness).colorScheme;
      final mine = tester.widget<Container>(find.byKey(const ValueKey('ride-message-m1')));
      final theirs = tester.widget<Container>(find.byKey(const ValueKey('ride-message-m2')));
      expect((mine.decoration! as BoxDecoration).color, scheme.primary);
      expect((theirs.decoration! as BoxDecoration).color, scheme.surfaceContainerHighest);
      expect(tester.getCenter(find.text('At the gate')).dx, greaterThan(250));
      expect(tester.getCenter(find.text("I'm on my way")).dx, lessThan(250));

      // What reached me is delivered, then read while I'm looking at it.
      expect(repo.marked, ['m2:delivered', 'm2,m3:read']);

      // The rider's quick replies, the text box and the location.
      expect(find.byKey(const ValueKey("quick-I'm at the pickup point")), findsOneWidget);
      expect(find.byKey(const ValueKey("quick-I've arrived")), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('quick-Please call me')));
      await tester.tap(find.byKey(const ValueKey('quick-Please call me')));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('ride-chat-input')), '  Blue shirt  ');
      await tester.tap(find.byKey(const ValueKey('ride-chat-send')));
      await tester.pump();
      expect(find.text('Blue shirt'), findsNothing, reason: 'the box clears once sent');
      await tester.tap(find.byKey(const ValueKey('ride-chat-location')));
      await tester.pump();
      expect(repo.sent, ['rider:quick:Please call me', 'rider:text:Blue shirt', 'rider:location:2.93,101.83']);

      await tester.tap(find.byKey(const ValueKey('ride-location-m3')));
      await tester.pump();
      expect(opened.single.toString(), contains('query=3.100000,101.600000'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('after the ride the chat is read-only (${brightness.name})', (tester) async {
      final (repo, _) = await pumpChat(tester, me: 'driver', status: 'completed', brightness: brightness);
      repo.rows.add([_msg('m1', 'rider', 'Thanks!', status: RideMessageStatus.read)]);
      await tester.pump();
      await tester.pump();
      expect(find.text('Thanks!'), findsOneWidget);
      expect(find.text('Aina'), findsOneWidget);
      expect(find.byKey(const ValueKey('ride-chat-closed')), findsOneWidget);
      expect(find.textContaining('read-only'), findsOneWidget);
      expect(find.byKey(const ValueKey('ride-chat-input')), findsNothing);
      expect(find.byKey(const ValueKey('ride-chat-quick')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the driver gets the driver\'s quick replies and an empty thread says so', (tester) async {
    final (repo, _) = await pumpChat(tester, me: 'driver', status: 'arrived', brightness: Brightness.dark);
    repo.rows.add(const []);
    await tester.pump();
    await tester.pump();
    expect(find.text('No messages yet'), findsOneWidget);
    expect(find.text('Your passenger'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey("quick-I've arrived")));
    await tester.pump();
    expect(repo.sent, ["partner:quick:I've arrived"]);
  });

  testWidgets('somebody else\'s ride has no chat for them', (tester) async {
    await pumpChat(tester, me: 'stranger', status: 'accepted');
    await tester.pump();
    expect(find.text('Not your ride'), findsOneWidget);
    expect(find.byKey(const ValueKey('ride-chat-input')), findsNothing);
  });

  for (final brightness in Brightness.values) {
    testWidgets('the driver\'s Message button shows unread and opens the chat (${brightness.name})', (tester) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = _Repo();
      addTearDown(repo.rows.close);
      final router = GoRouter(
        initialLocation: '/drive/trip/r1',
        routes: [
          GoRoute(
            path: '/drive/trip/:id',
            builder: (_, s) => PartnerTripScreen(requestId: s.pathParameters['id']!),
            routes: [
              GoRoute(
                path: 'chat',
                builder: (_, s) => RideChatScreen(requestId: s.pathParameters['id']!),
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            rideRepositoryProvider.overrideWithValue(_Rides()),
            rideChatRepositoryProvider.overrideWithValue(repo),
            rideStreamProvider.overrideWith((ref, id) => Stream.value(_ride('accepted'))),
            tripFixProvider.overrideWithValue(() async => null),
            currentUserIdProvider.overrideWithValue('driver'),
          ],
          child: MaterialApp.router(theme: appTheme(brightness), routerConfig: router),
        ),
      );
      await tester.pump();
      repo.rows.add([
        _msg('m1', 'rider', "I'm at the pickup point"),
        _msg('m2', 'rider', 'Blue shirt', minute: 1),
        _msg('m3', 'driver', 'OK', minute: 2),
      ]);
      await tester.pump();
      await tester.pump();

      final badge = tester.widget<Badge>(find.byKey(const ValueKey('ride-chat-badge')));
      expect(badge.isLabelVisible, isTrue);
      expect(find.descendant(of: find.byType(Badge), matching: find.text('2')), findsOneWidget);
      // No phone on this ride, but an in-app call needs none (migration 0131).
      expect(find.byKey(const ValueKey('ride-call')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('trip-message')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(RideChatScreen), findsOneWidget);
      expect(find.text('Blue shirt'), findsOneWidget);
      expect(repo.marked.last, 'm1,m2:read');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the rider\'s Message opens the in-app chat, not the SMS app', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = _Repo();
    addTearDown(repo.rows.close);
    final router = GoRouter(
      initialLocation: '/ride/r1',
      routes: [
        GoRoute(
          path: '/ride/:id',
          builder: (_, s) => RideTrackingScreen(requestId: s.pathParameters['id']!),
          routes: [
            GoRoute(
              path: 'chat',
              builder: (_, s) => RideChatScreen(requestId: s.pathParameters['id']!),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rideRepositoryProvider.overrideWithValue(_Rides()),
          rideChatRepositoryProvider.overrideWithValue(repo),
          rideStreamProvider.overrideWith((ref, id) => Stream.value(_ride('arrived'))),
          riderPositionStreamProvider.overrideWithValue(() => const Stream.empty()),
          fareCoinChoiceStoreProvider.overrideWithValue(FareCoinChoiceStore()),
          walletBalancesProvider.overrideWith((ref) async => const []),
          walletTxProvider.overrideWith((ref) async => const []),
          currentUserIdProvider.overrideWithValue('rider'),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    repo.rows.add([_msg('m1', 'driver', "I've arrived")]);
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(find.text('Call'), findsOneWidget);
    expect(find.descendant(of: find.byType(Badge), matching: find.text('1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ride-message')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(RideChatScreen), findsOneWidget);
    expect(find.text("I've arrived"), findsOneWidget);
    expect(repo.marked.last, 'm1:read');
  });
}
