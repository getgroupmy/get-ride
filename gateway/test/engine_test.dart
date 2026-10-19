import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getride_gateway/src/core.dart';
import 'package:getride_gateway/src/engine.dart';

import 'fakes.dart';

void main() {
  late FakeBackend server;
  late FakeSms phone;
  late DateTime now;
  late GatewayEngine engine;

  setUp(() {
    server = FakeBackend();
    phone = FakeSms();
    now = DateTime(2026, 10, 9, 9);
    engine = GatewayEngine(
      backend: server,
      platform: phone,
      config: () => const GatewayConfig(deviceId: 'install-1', label: 'Office', subscriptionId: 2),
      schedule: false,
      now: () => now,
    );
  });

  tearDown(() => engine.dispose());

  test('online: sends the routed jobs from the chosen SIM and reports each', () async {
    server.queue.addAll(const [
      SmsJob(id: 'j1', channel: 'otp', to: '+60123456789', body: 'Your code is 1234'),
      SmsJob(id: 'j2', channel: 'marketing', to: '+60111111111', body: 'Promo'),
    ]);
    phone.failTo.add('+60111111111');
    await engine.start();

    expect(engine.state, GatewayState.online);
    expect(engine.device, 'dev-1');
    expect(server.heartbeats, ['install-1']);
    expect(phone.sent.map((s) => (s.$1, s.$3)), [('+60123456789', 2), ('+60111111111', 2)]);
    expect(server.reports, [('j1', true, null), ('j2', false, 'Radio off')]);
    expect((engine.stats.sent, engine.stats.failed), (1, 1));
    expect(phone.serviceRunning, isTrue);
    // The log names the number masked, never the code.
    expect(engine.log.entries.map((e) => e.text).join('\n'), isNot(contains('1234')));
  });

  test('heartbeats once a minute, not every round', () async {
    await engine.start();
    now = now.add(const Duration(seconds: 30));
    await engine.tick();
    expect(server.heartbeats, hasLength(1));
    now = now.add(const Duration(seconds: 31));
    await engine.tick();
    expect(server.heartbeats, hasLength(2));
  });

  test('a received SMS is acknowledged on the phone only once the server has it', () async {
    phone.pendingList.add(IncomingSms(id: 'p1', from: '+60199999999', body: 'While closed', at: now));
    server.failWith = Exception('SocketException: Failed host lookup');
    await engine.start();
    expect(engine.state, GatewayState.reconnecting);
    phone.receive(IncomingSms(id: 'p2', from: '+60188888888', body: 'Hello', at: now));
    await Future<void>.delayed(Duration.zero);
    expect(phone.acked, isEmpty, reason: 'the server does not have them yet');

    server.failWith = null;
    now = now.add(const Duration(seconds: 6));
    await engine.tick();
    expect(engine.state, GatewayState.online);
    expect(server.received.map((s) => s.id), ['p1', 'p2']);
    expect(phone.acked, ['p1', 'p2']);
    expect(engine.stats.received, 2);
  });

  test('a lost connection backs off and does not hammer the server', () async {
    server.failWith = Exception('SocketException');
    await engine.start();
    expect(engine.state, GatewayState.reconnecting);
    final calls = server.heartbeats.length;
    now = now.add(const Duration(seconds: 3));
    await engine.tick(); // within the 5 s backoff: skipped
    server.failWith = null;
    await engine.tick();
    expect(server.heartbeats.length, calls);
    now = now.add(const Duration(seconds: 3));
    await engine.tick();
    expect(engine.state, GatewayState.online);
  });

  test('a lost report is sent again, but the SMS is not', () async {
    server.queue.add(const SmsJob(id: 'j1', channel: 'otp', to: '+60123456789', body: 'Your code is 1234'));
    server.failReports = Exception('SocketException');
    await engine.start();
    expect(phone.sent, hasLength(1));
    expect(server.reports, isEmpty);

    server.failReports = null;
    now = now.add(const Duration(seconds: 6));
    await engine.tick();
    expect(server.reports, [('j1', true, null)]);
    expect(phone.sent, hasLength(1), reason: 'sent once');
  });

  group('asking for new SMS (one timer, armed for the next due round)', () {
    /// Runs [body] on a fake clock with an engine that schedules its own
    /// rounds, as on the phone. The engine's clock is the fake one.
    void onFakeClock(void Function(FakeAsync async, GatewayEngine engine) body) {
      fakeAsync((async) {
        final start = DateTime(2026, 10, 9, 9);
        final e = GatewayEngine(
          backend: server,
          platform: phone,
          config: () => const GatewayConfig(deviceId: 'install-1', label: 'Office', subscriptionId: 2),
          now: () => start.add(async.elapsed),
        );
        unawaited(e.start());
        async.flushMicrotasks();
        body(async, e);
        unawaited(e.stop());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty, reason: 'stopping cancels the timer');
        e.dispose();
      });
    }

    /// The only timer pending: one-shot, never periodic.
    Duration armed(FakeAsync async) {
      expect(async.periodicTimerCount, 0);
      expect(async.pendingTimers, hasLength(1));
      return async.pendingTimers.single.duration;
    }

    /// Moves the clock a second at a time for [seconds], returning the
    /// seconds (from now) at which a round asked the server.
    List<int> run(FakeAsync async, int seconds) {
      final at = <int>[];
      for (var s = 1; s <= seconds; s++) {
        final before = server.claims;
        async.elapse(const Duration(seconds: 1));
        if (server.claims > before) at.add(s);
      }
      return at;
    }

    List<int> gaps(List<int> at) => [for (var i = 1; i < at.length; i++) at[i] - at[i - 1]];

    test('every 5 s for the first quiet minute, then 10 s, then every 15 s', () {
      onFakeClock((async, engine) {
        expect(server.claims, 1);
        expect(armed(async), const Duration(seconds: 5));
        final at = run(async, 300);
        final g = gaps(at);
        expect(at.first, 5);
        expect(g.where((d) => d == 5).length, inInclusiveRange(10, 12));
        expect(g.where((d) => d == 10).length, inInclusiveRange(5, 6));
        expect(g.every((d) => d == 5 || d == 10 || d == 15), isTrue, reason: '$g');
        expect(g.sublist(g.length - 5), everyElement(15));
        // Five quiet minutes: about 35 asks, where every 5 s would be 60.
        expect(at.length, lessThan(40));
        // Still says it is here once a minute.
        expect(server.heartbeats.length, greaterThanOrEqualTo(5));
        expect(armed(async), const Duration(seconds: 15));
      });
    });

    test('the admin\'s longest wait from the heartbeat: 5 s, 10 s, then that', () {
      server.pollMaxSeconds = 30;
      onFakeClock((async, engine) {
        expect(engine.quietMax, const Duration(seconds: 30));
        final g = gaps(run(async, 600));
        expect(g.every((d) => d == 5 || d == 10 || d == 30), isTrue, reason: '$g');
        expect(g.where((d) => d == 10), isNotEmpty);
        expect(g.sublist(g.length - 5), everyElement(30));
        expect(armed(async), const Duration(seconds: 30));
      });
    });

    test('a longest wait under 10 s caps the ramp at it', () {
      server.pollMaxSeconds = 8;
      onFakeClock((async, engine) {
        final g = gaps(run(async, 300));
        expect(g.every((d) => d == 5 || d == 8), isTrue, reason: '$g');
        expect(g.sublist(g.length - 5), everyElement(8));
      });
    });

    test('a missing or invalid longest wait keeps 15 s', () {
      for (final bad in [null, 3, 120, 'soon']) {
        server.pollMaxSeconds = bad;
        onFakeClock((async, engine) {
          run(async, 300);
          expect(engine.quietMax, const Duration(seconds: 15), reason: '$bad');
          expect(armed(async), const Duration(seconds: 15), reason: '$bad');
        });
      }
    });

    test('a change is picked up at the next heartbeat, without a restart', () {
      onFakeClock((async, engine) {
        run(async, 600);
        expect(armed(async), const Duration(seconds: 15));
        server.pollMaxSeconds = 6;
        final beats = server.heartbeats.length;
        // Within a minute (the heartbeat) and the round after it.
        final at = run(async, 75);
        expect(server.heartbeats.length, beats + 1);
        expect(engine.quietMax, const Duration(seconds: 6));
        expect(armed(async), const Duration(seconds: 6));
        expect(gaps(at).last, 6);
        expect(engine.log.entries.map((e) => e.text), contains('Longest wait for a sign-in code: 6 s.'));
        // And back to the default when the server stops saying.
        server.pollMaxSeconds = null;
        run(async, 75);
        expect(armed(async), const Duration(seconds: 15));
      });
    });

    test('no timer fires between due times: one wake-up per round', () {
      onFakeClock((async, engine) {
        run(async, 600); // quiet: every 15 s
        final claims = server.claims;
        final wait = armed(async);
        expect(wait, const Duration(seconds: 15));
        final timer = async.pendingTimers.single;
        // Just short of due: nothing has run, and the same single timer waits.
        async.elapse(wait - const Duration(milliseconds: 1));
        expect(server.claims, claims);
        expect(armed(async), wait);
        expect(identical(async.pendingTimers.single, timer), isTrue, reason: 'not re-armed in between');
        async.elapse(const Duration(milliseconds: 1));
        expect(server.claims, claims + 1);
        expect(armed(async), const Duration(seconds: 15));
      });
    });

    test('a sign-in code queued while quiet goes out within 15 s, and polling is fast again after', () {
      onFakeClock((async, engine) {
        run(async, 600);
        for (var offset = 0; offset < 15; offset++) {
          // Wherever in the interval the code is queued.
          run(async, offset);
          server.queue.add(SmsJob(id: 'otp-$offset', channel: 'otp', to: '+60123456789', body: 'Your code is 1'));
          var waited = 0;
          while (phone.sent.length <= offset) {
            run(async, 1);
            waited++;
            expect(waited, lessThanOrEqualTo(15), reason: 'queued at offset $offset');
          }
          // The claim re-armed the timer at the busy interval.
          expect(armed(async), const Duration(seconds: 5));
          expect(run(async, 5), [5]);
          run(async, 600); // and quiet again
        }
      });
    });

    test('a received SMS is handed over at once and re-arms the timer at 5 s', () {
      onFakeClock((async, engine) {
        run(async, 600);
        expect(armed(async), const Duration(seconds: 15));
        async.elapse(const Duration(seconds: 3));
        final claims = server.claims;
        phone.receive(IncomingSms(id: 'r1', from: '+60188888888', body: 'Hi', at: DateTime(2026)));
        async.flushMicrotasks();
        expect(server.received.map((s) => s.id), ['r1']);
        expect(server.claims, claims + 1);
        expect(armed(async), const Duration(seconds: 5), reason: 'the old 15 s timer was replaced');
        expect(run(async, 5), [5]);
      });
    });

    test('after a failure the one timer waits out the backoff, then the busy interval resumes', () {
      onFakeClock((async, engine) {
        server.failWith = Exception('SocketException');
        async.elapse(const Duration(seconds: 5));
        expect(engine.state, GatewayState.reconnecting);
        expect(armed(async), const Duration(seconds: 5)); // backoffAfter(1)
        async.elapse(const Duration(seconds: 5));
        expect(armed(async), const Duration(seconds: 10)); // backoffAfter(2)
        server.failWith = null;
        final claims = server.claims;
        async.elapse(const Duration(seconds: 10));
        expect(engine.state, GatewayState.online);
        expect(server.claims, claims + 1);
        expect(armed(async), const Duration(seconds: 5));
      });
    });
  });

  test('a refusal (not an admin) stops the gateway and says why', () async {
    server.failWith = Exception('PostgrestException(message: GATEWAY_NEEDS_ADMIN, code: 42501)');
    await engine.start();
    expect(engine.state, GatewayState.off);
    expect(engine.stopReason, contains('not an admin'));
    expect(phone.serviceRunning, isFalse);
  });

  group('sharing the phone\'s internet', () {
    late GatewayConfig config;

    setUp(() {
      config = const GatewayConfig(
        deviceId: 'install-1',
        label: 'Office',
        gatewayKey: 'device-key',
        shareInternet: true,
        mobileDataOnly: true,
      );
      engine.dispose();
      engine = GatewayEngine(
        backend: server,
        platform: phone,
        config: () => config,
        schedule: false,
        relayUrl: 'wss://relay.test/phone',
        now: () => now,
      );
    });

    test('starts with the gateway, with the device key, and stops with it', () async {
      expect(phone.proxyStarts, isEmpty);
      await engine.start();
      expect(engine.state, GatewayState.online);
      expect(phone.proxyStarts, [('wss://relay.test/phone', 'device-key', 'Office', true)]);

      phone.proxyEvent('connecting');
      phone.proxyEvent('connected');
      expect(engine.proxy, ProxyState.connected);
      expect(phone.serviceText, contains('internet shared'));
      phone.proxyEvent('request', {'host': 'example.com', 'status': 200});
      phone.proxyEvent('request', {'host': 'down.example', 'error': 'timeout'});
      expect(engine.stats.relayed, 1);
      final lines = engine.log.entries.map((e) => e.text).join('\n');
      expect(lines, contains('example.com (200)'));
      expect(lines, contains('down.example failed: timeout'));

      await engine.stop();
      expect(phone.proxyRunning, isFalse);
      expect(engine.proxy, ProxyState.off);
    });

    test('not shared while the switch is off, nor before pairing; the switch moves it live', () async {
      config = const GatewayConfig(deviceId: 'install-1', gatewayKey: 'device-key');
      await engine.start();
      expect(phone.proxyStarts, isEmpty);

      config = const GatewayConfig(deviceId: 'install-1', gatewayKey: 'device-key', shareInternet: true);
      await engine.syncProxy();
      expect(phone.proxyStarts, hasLength(1));
      phone.proxyEvent('connected');
      expect(engine.proxy, ProxyState.connected);

      config = const GatewayConfig(deviceId: 'install-1', gatewayKey: 'device-key', shareInternet: false);
      await engine.syncProxy();
      expect(phone.proxyRunning, isFalse);
      expect(engine.proxy, ProxyState.off);

      config = const GatewayConfig(deviceId: 'install-1', shareInternet: true);
      await engine.syncProxy();
      expect(phone.proxyStarts, hasLength(1), reason: 'no device key, nothing to connect with');
    });

    test('a refusal from the relay is kept as the reason; an outage is logged once', () async {
      await engine.start();
      phone.proxyEvent('reconnecting', {'reason': 'Connection reset'});
      phone.proxyEvent('reconnecting', {'reason': 'Connection reset'});
      expect(engine.proxy, ProxyState.reconnecting);
      expect(engine.log.entries.where((e) => e.text.contains('Retrying')), hasLength(1));
      phone.proxyEvent('error', {'reason': 'This phone is not paired any more (HTTP 401).'});
      expect(engine.proxy, ProxyState.error);
      expect(engine.proxyReason, contains('not paired'));
      expect(engine.running, isTrue, reason: 'SMS go on without it');
    });
  });

  test('stopping ends the service; starting again clears the old reason', () async {
    await engine.start();
    await engine.stop();
    expect(engine.running, isFalse);
    expect(phone.serviceRunning, isFalse);
    await engine.start();
    expect(engine.stopReason, isNull);
    expect(engine.state, GatewayState.online);
  });
}
