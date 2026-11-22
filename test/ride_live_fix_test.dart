// The driver's fix a second: what is sent, what is heard and how the sending
// is paced (data/ride_live_fix_repository.dart, data/live_fix_sender.dart).
import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/live_fix.dart';
import 'package:get_ride/src/data/live_fix_sender.dart';
import 'package:get_ride/src/data/realtime_hub.dart';
import 'package:get_ride/src/data/ride_live_fix_repository.dart';
import 'package:get_ride/src/providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final t0 = DateTime.utc(2026, 11, 22, 4, 0, 0, 250);

LiveFix fix(int n, {double? speed = 12.5, double? course = 90, double? accuracy = 4}) => (
  at: LatLng(3.139 + n * 0.0001, 101.6869),
  speed: speed,
  course: course,
  time: t0.add(Duration(seconds: n)),
  accuracy: accuracy,
);

http.Response json(http.Request to, Object? body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'}, request: to);

/// What a server without the function, or the table, answers (PostgREST).
http.Response missing(http.Request to, String code, String message) =>
    json(to, {'code': code, 'details': null, 'hint': null, 'message': message}, 404);

void main() {
  group('what is sent', () {
    test('the position, what the GPS measured with it, and the time it took the fix', () {
      expect(liveFixParams('r1', fix(3), now: DateTime.utc(2030)), {
        'p_ride': 'r1',
        'p_lat': 3.1393,
        'p_lng': 101.6869,
        'p_heading': 90.0,
        'p_speed': 12.5,
        'p_accuracy': 4.0,
        'p_fixed_at': '2026-11-22T04:00:03.250Z',
      });
    });

    test('what the GPS did not measure goes as nothing, never as a number', () {
      final params = liveFixParams('r1', fix(0, speed: null, course: null, accuracy: null), now: t0)!;
      expect(params['p_heading'], isNull);
      expect(params['p_speed'], isNull);
      expect(params['p_accuracy'], isNull);
      final odd = liveFixParams(
        'r1',
        (at: const LatLng(3, 101), speed: double.nan, course: double.infinity, time: t0, accuracy: double.negativeInfinity),
        now: t0,
      )!;
      expect([odd['p_heading'], odd['p_speed'], odd['p_accuracy']], [null, null, null]);
      // It is what goes over the wire: it has to be sayable in JSON.
      expect(() => jsonEncode(odd), returnsNormally);
    });

    test('a fix with no time is stamped now, in UTC whatever the phone is set to', () {
      final now = DateTime.utc(2026, 11, 22, 12, 30, 15, 5);
      final params = liveFixParams('r1', (at: const LatLng(3, 101), speed: null, course: null, time: null, accuracy: null), now: now)!;
      expect(params['p_fixed_at'], '2026-11-22T12:30:15.005Z');
      final local = liveFixParams('r1', (at: const LatLng(3, 101), speed: null, course: null, time: now.toLocal(), accuracy: null), now: now)!;
      expect(local['p_fixed_at'], '2026-11-22T12:30:15.005Z');
    });

    test('a fix with no position is not sent at all', () {
      const nowhere = (at: LatLng(double.nan, 101), speed: 1.0, course: 1.0, time: null, accuracy: 1.0);
      expect(liveFixParams('r1', nowhere, now: t0), isNull);
    });
  });

  group('what is heard', () {
    test('a row as realtime hands it over', () {
      final heard = liveFixOfRow({
        'driver_id': 'd1',
        'ride_id': 'r1',
        'lat': 3.1404,
        'lng': 101.6869,
        'heading': 90, // whole numbers come as ints
        'speed': 12.5,
        'accuracy': 4,
        'fixed_at': '2026-11-22T13:22:40.296+00:00',
        'sent_at': '2026-11-22T13:22:40.298985+00:00',
      })!;
      expect(heard.at, const LatLng(3.1404, 101.6869));
      expect(heard.course, 90.0);
      expect(heard.speed, 12.5);
      expect(heard.accuracy, 4.0);
      expect(heard.time, DateTime.utc(2026, 11, 22, 13, 22, 40, 296));
    });

    test('what the driver\'s phone could not measure is not known here either', () {
      final heard = liveFixOfRow({'lat': 3, 'lng': 101, 'heading': null, 'speed': null, 'accuracy': null, 'fixed_at': null})!;
      expect(heard.at, const LatLng(3, 101));
      expect([heard.course, heard.speed, heard.accuracy, heard.time], [null, null, null, null]);
    });

    test('a row with no position is nothing: a delete, or a row that is not one', () {
      expect(liveFixOfRow(const {}), isNull);
      expect(liveFixOfRow({'driver_id': 'd1'}), isNull);
      expect(liveFixOfRow({'lat': 3.1, 'lng': null}), isNull);
      expect(liveFixOfRow({'lat': 91, 'lng': 101}), isNull);
      expect(liveFixOfRow({'lat': 3, 'lng': -181}), isNull);
      expect(liveFixOfRow({'lat': 'north', 'lng': 101}), isNull);
    });

    test('numbers sent as text are read; a course is kept within the compass', () {
      final heard = liveFixOfRow({'lat': '3.5', 'lng': '101.5', 'heading': '365', 'speed': '-1', 'fixed_at': 'not a time'})!;
      expect(heard.at, const LatLng(3.5, 101.5));
      expect(heard.course, 5.0);
      expect(heard.speed, isNull, reason: 'no car goes at less than nothing');
      expect(heard.time, isNull);
    });

    test('a fix sent and heard is the same fix', () {
      final params = liveFixParams('r1', fix(7), now: t0)!;
      final heard = liveFixOfRow({
        'lat': params['p_lat'],
        'lng': params['p_lng'],
        'heading': params['p_heading'],
        'speed': params['p_speed'],
        'accuracy': params['p_accuracy'],
        'fixed_at': params['p_fixed_at'],
      });
      expect(heard, fix(7));
    });
  });

  group('a server without the channel', () {
    test('says so in one of these ways', () {
      for (final code in ['PGRST202', '42883', 'PGRST205', '42P01']) {
        expect(liveFixUnsupported(PostgrestException(message: 'x', code: code)), isTrue, reason: code);
      }
      expect(
        liveFixUnsupported(const PostgrestException(message: 'Could not find the function public.ride_live_fix(p_ride) in the schema cache')),
        isTrue,
      );
      expect(
        liveFixUnsupported(const PostgrestException(message: "Could not find the table 'public.ride_live_fixes' in the schema cache")),
        isTrue,
      );
    });

    test('anything else is a failure that may pass: refused, no connection, a timeout', () {
      expect(liveFixUnsupported(const PostgrestException(message: 'permission denied for table ride_live_fixes', code: '42501')), isFalse);
      expect(liveFixUnsupported(const PostgrestException(message: 'JWT expired', code: 'PGRST301')), isFalse);
      expect(liveFixUnsupported(TimeoutException('slow')), isFalse);
      expect(liveFixUnsupported(Exception('SocketException: failed host lookup')), isFalse);
    });
  });

  group('the repository', () {
    late List<http.Request> asked;
    late http.Response Function(http.Request) answer;
    late SupabaseClient db;
    late List<void Function(PostgresChangePayload)> listeners;
    late List<(String table, PostgresChangeEvent event, PostgresChangeFilter? filter)> opened;
    late int closed;

    setUp(() {
      asked = [];
      listeners = [];
      opened = [];
      closed = 0;
      answer = (r) => json(r, []);
      db = SupabaseClient(
        'http://localhost',
        'anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((r) async {
          asked.add(r);
          return answer(r);
        }),
      );
      RealtimeHub.debugUse(
        db,
        RealtimeHub((name, table, event, filter, onChange, onStatus) {
          opened.add((table, event, filter));
          listeners.add(onChange);
          return name;
        }, (_) => closed++),
      );
    });

    PostgresChangePayload change(Map<String, dynamic> row, {PostgresChangeEvent type = PostgresChangeEvent.update}) =>
        PostgresChangePayload(
          schema: 'public',
          table: 'ride_live_fixes',
          commitTimestamp: DateTime.utc(2026, 11, 22),
          eventType: type,
          newRecord: row,
          oldRecord: const {},
          errors: null,
        );

    test('sends a fix through ride_live_fix() and says what the server answered', () async {
      answer = (r) => json(r, true);
      expect(await RideLiveFixRepository(db).send('r1', fix(2)), isTrue);
      expect(asked.single.url.path, endsWith('/rpc/ride_live_fix'));
      expect(jsonDecode(asked.single.body), liveFixParams('r1', fix(2), now: t0));
      answer = (r) => json(r, false);
      expect(await RideLiveFixRepository(db).send('r1', fix(3)), isFalse, reason: 'the ride takes none from this phone');
    });

    test('a server without the function: the error says so', () async {
      answer = (r) => missing(r, 'PGRST202', 'Could not find the function public.ride_live_fix(p_ride) in the schema cache');
      Object? error;
      try {
        await RideLiveFixRepository(db).send('r1', fix(2));
      } catch (e) {
        error = e;
      }
      expect(error, isNotNull);
      expect(liveFixUnsupported(error!), isTrue);
    });

    test("hears the ride's fixes over realtime, each as it is written", () async {
      final heard = <LiveFix>[];
      final sub = RideLiveFixRepository(db).watch('r1').listen(heard.add);
      await pumpEventQueue();
      // One channel on this ride's rows, and one question: is there such a
      // table?
      expect(asked.single.url.path, endsWith('/ride_live_fixes'));
      expect(asked.single.url.queryParameters['ride_id'], 'eq.r1');
      expect(opened.single.$1, 'ride_live_fixes');
      expect(opened.single.$2, PostgresChangeEvent.all);
      expect(opened.single.$3!.column, 'ride_id');
      expect(opened.single.$3!.value, 'r1');
      expect(heard, isEmpty, reason: 'nothing from before the listening began');

      listeners.single(change({'lat': 3.1, 'lng': 101.6, 'heading': 45, 'speed': 9, 'accuracy': 5, 'fixed_at': '2026-11-22T04:00:01Z'},
          type: PostgresChangeEvent.insert));
      listeners.single(change({'lat': 3.2, 'lng': 101.7, 'heading': null, 'speed': 0, 'accuracy': 6, 'fixed_at': '2026-11-22T04:00:02Z'}));
      // A delete comes with no row: not a fix.
      listeners.single(change(const {}, type: PostgresChangeEvent.delete));
      await pumpEventQueue();
      expect(heard.map((f) => f.at), [const LatLng(3.1, 101.6), const LatLng(3.2, 101.7)]);
      expect(heard.last.speed, 0, reason: 'standing still is a speed, not "not known"');
      expect(heard.last.course, isNull);

      await sub.cancel();
      expect(closed, 1, reason: 'the channel is let go of with the map');
    });

    test('a server without the table: nothing to listen to, and no channel left open', () async {
      answer = (r) => missing(r, 'PGRST205', "Could not find the table 'public.ride_live_fixes' in the schema cache");
      var done = false;
      final heard = <LiveFix>[];
      final sub = RideLiveFixRepository(db).watch('r1').listen(heard.add, onDone: () => done = true);
      await pumpEventQueue();
      expect(done, isTrue);
      expect(opened.length - closed, 0, reason: 'the channel is let go of: it would be asked for again and again');
      expect(heard, isEmpty);
      await sub.cancel();
      expect(closed, 1, reason: 'and let go of once');
    });

    test('a server that cannot be reached just now is listened to all the same', () async {
      answer = (_) => throw http.ClientException('no route to host');
      var done = false;
      final sub = RideLiveFixRepository(db).watch('r1').listen((_) {}, onDone: () => done = true);
      await pumpEventQueue();
      expect(opened.length, 1, reason: 'realtime connects when the network is back');
      expect(closed, 0);
      expect(done, isFalse);
      await sub.cancel();
    });

    test('a server that refuses the question is listened to all the same', () async {
      answer = (r) => json(r, {'code': '42501', 'message': 'permission denied for table ride_live_fixes'}, 403);
      var done = false;
      final sub = RideLiveFixRepository(db).watch('r1').listen((_) {}, onDone: () => done = true);
      await pumpEventQueue();
      expect(opened.length, 1);
      expect(closed, 0);
      expect(done, isFalse);
      await sub.cancel();
    });

    test('given up before the answer came: the channel is let go of once', () async {
      final hold = Completer<http.Response>();
      db = SupabaseClient(
        'http://localhost',
        'anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((r) => hold.future),
      );
      RealtimeHub.debugUse(
        db,
        RealtimeHub((name, table, event, filter, onChange, onStatus) {
          opened.add((table, event, filter));
          return name;
        }, (_) => closed++),
      );
      final sub = RideLiveFixRepository(db).watch('r1').listen((_) {});
      await pumpEventQueue();
      await sub.cancel();
      expect(opened.length, 1);
      expect(closed, 1);
      hold.complete(http.Response('{"code":"PGRST205","message":"Could not find the table"}', 404,
          headers: {'content-type': 'application/json'}));
      await pumpEventQueue();
      expect(closed, 1, reason: 'not let go of twice');
    });

    test("a demo ride is never asked of a server; a real one's fixes come from the repository", () async {
      final container = ProviderContainer(overrides: [supabaseProvider.overrideWithValue(db)]);
      addTearDown(container.dispose);
      expect(container.read(rideCarFixesProvider('demo-1')), isNull);
      final open = container.read(rideCarFixesProvider('r1'));
      final sub = open!().listen((_) {});
      await pumpEventQueue();
      expect(opened.single.$3!.value, 'r1');
      await sub.cancel();
    });

    test('with no server at all there is simply nothing to hear', () async {
      // As in a test that never set one up: asking for the client throws.
      final container = ProviderContainer(overrides: [supabaseProvider.overrideWith((ref) => throw StateError('no client'))]);
      addTearDown(container.dispose);
      final heard = <LiveFix>[];
      var done = false;
      container.read(rideCarFixesProvider('r1'))!().listen(heard.add, onDone: () => done = true);
      await pumpEventQueue();
      expect(done, isTrue);
      expect(heard, isEmpty);
    });
  });

  group('the sender', () {
    /// A send that is answered when the test says so.
    late List<(LiveFix, Completer<bool>)> sends;
    Future<bool> send(LiveFix f) {
      final c = Completer<bool>();
      sends.add((f, c));
      return c.future;
    }

    setUp(() => sends = []);

    test('a fix a second: each is sent as it comes', () {
      fakeAsync((clock) {
        final sender = LiveFixSender((f) {
          sends.add((f, Completer<bool>()..complete(true)));
          return Future.value(true);
        });
        for (var n = 0; n < 5; n++) {
          sender.offer(fix(n));
          clock.elapse(const Duration(seconds: 1));
        }
        expect(sends.map((s) => s.$1), [for (var n = 0; n < 5; n++) fix(n)]);
        sender.dispose();
      });
    });

    test('one at a time, and while one is on its way only the newest is kept', () {
      fakeAsync((clock) {
        final sender = LiveFixSender(send);
        sender.offer(fix(0));
        expect(sends.length, 1);
        // The connection is slow: three more fixes come before it answers.
        for (var n = 1; n <= 3; n++) {
          clock.elapse(const Duration(seconds: 1));
          sender.offer(fix(n));
        }
        expect(sends.length, 1, reason: 'never two on their way');
        sends[0].$2.complete(true);
        clock.flushMicrotasks();
        expect(sends.length, 2);
        expect(sends[1].$1, fix(3), reason: 'the newest, not the ones it overtook');
        sends[1].$2.complete(true);
        clock.elapse(const Duration(seconds: 2));
        expect(sends.length, 2, reason: 'and nothing is sent twice');
        sender.dispose();
      });
    });

    test('a burst of fixes is not a burst of sends', () {
      fakeAsync((clock) {
        final sender = LiveFixSender((f) {
          sends.add((f, Completer<bool>()));
          return Future.value(true);
        });
        // Ten fixes in a second.
        for (var n = 0; n < 10; n++) {
          sender.offer(fix(n));
          clock.elapse(const Duration(milliseconds: 100));
        }
        clock.elapse(const Duration(seconds: 1));
        // At 0 s; then 0.7 s on, the newest by then; then 0.7 s after that.
        expect(sends.map((s) => s.$1), [fix(0), fix(6), fix(9)], reason: 'no sooner than $liveFixSendLeast after the last, and the newest then');
        sender.dispose();
      });
    });

    test('a send that fails is not sent again; after a pause the newest fix goes', () {
      fakeAsync((clock) {
        final sender = LiveFixSender(send);
        sender.offer(fix(0));
        sends[0].$2.completeError(Exception('no connection'));
        clock.flushMicrotasks();
        sender.offer(fix(1));
        sender.offer(fix(2));
        clock.elapse(liveFixRetryAfter - const Duration(milliseconds: 1));
        expect(sends.length, 1, reason: 'not while the pause runs');
        clock.elapse(const Duration(milliseconds: 1));
        expect(sends.length, 2);
        expect(sends[1].$1, fix(2));
        sender.dispose();
      });
    });

    test('a send that is never answered is given up on, and the next goes', () {
      fakeAsync((clock) {
        final sender = LiveFixSender(send);
        sender.offer(fix(0));
        clock.elapse(const Duration(seconds: 1));
        sender.offer(fix(1));
        clock.elapse(liveFixSendTimeout);
        expect(sends.length, 1, reason: 'still held by the pause after a failure');
        clock.elapse(liveFixRetryAfter);
        expect(sends.length, 2);
        expect(sends[1].$1, fix(1));
        sender.dispose();
      });
    });

    test('a ride that takes no fixes is left alone for a while, then tried again', () {
      fakeAsync((clock) {
        final sender = LiveFixSender(send);
        sender.offer(fix(0));
        sender.offer(fix(1));
        sends[0].$2.complete(false);
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 2));
        expect(sends.length, 1, reason: 'the fix that was waiting is dropped too');
        sender.offer(fix(2));
        clock.elapse(liveFixRefusedHold - const Duration(seconds: 3));
        expect(sends.length, 1);
        clock.elapse(const Duration(seconds: 1));
        expect(sends.length, 2);
        expect(sends[1].$1, fix(2));
        expect(sender.stopped, isFalse);
        sender.dispose();
      });
    });

    test('a server that has nowhere to take one is not asked again', () {
      fakeAsync((clock) {
        final sender = LiveFixSender(send, unsupported: liveFixUnsupported);
        sender.offer(fix(0));
        sends[0].$2.completeError(const PostgrestException(message: 'no such function', code: 'PGRST202'));
        clock.flushMicrotasks();
        expect(sender.stopped, isTrue);
        for (var n = 1; n < 20; n++) {
          sender.offer(fix(n));
          clock.elapse(const Duration(seconds: 1));
        }
        expect(sends.length, 1);
        sender.dispose();
      });
    });

    test('a send that throws before it is even on its way is a failure like any other', () {
      fakeAsync((clock) {
        var calls = 0;
        final sender = LiveFixSender((f) {
          calls++;
          throw StateError('no client');
        });
        sender.offer(fix(0));
        clock.flushMicrotasks();
        sender.offer(fix(1));
        clock.elapse(liveFixRetryAfter);
        expect(calls, 2);
        sender.dispose();
      });
    });

    test('a fix that was waiting is forgotten when the ride is no longer under way', () {
      fakeAsync((clock) {
        final sender = LiveFixSender(send);
        sender.offer(fix(0));
        sender.offer(fix(1));
        sender.drop();
        sends[0].$2.complete(true);
        clock.elapse(const Duration(seconds: 5));
        expect(sends.length, 1);
        sender.dispose();
      });
    });

    test('disposed, it sends nothing more and leaves no timer behind', () {
      fakeAsync((clock) {
        final sender = LiveFixSender(send);
        sender.offer(fix(0));
        sender.offer(fix(1));
        sender.dispose();
        sends[0].$2.complete(true);
        clock.elapse(const Duration(minutes: 1));
        sender.offer(fix(2));
        clock.elapse(const Duration(minutes: 1));
        expect(sends.length, 1);
        expect(clock.pendingTimers, isEmpty);
      });
    });
  });
}
