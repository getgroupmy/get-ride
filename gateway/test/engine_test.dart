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

  group('asking for new SMS', () {
    /// Calls the timer's [GatewayEngine.poll] once a second for [seconds],
    /// returning the seconds (from now) at which a round asked the server.
    Future<List<int>> run(int seconds) async {
      final at = <int>[];
      for (var s = 1; s <= seconds; s++) {
        now = now.add(const Duration(seconds: 1));
        final before = server.claims;
        await engine.poll();
        if (server.claims > before) at.add(s);
      }
      return at;
    }

    List<int> gaps(List<int> at) => [for (var i = 1; i < at.length; i++) at[i] - at[i - 1]];

    test('every 5 s for the first quiet minute, then 10 s, then every 15 s', () async {
      await engine.start();
      expect(server.claims, 1);
      final at = await run(300);
      final g = gaps(at);
      // The first minute at 5 s, the second at 10 s, then 15 s.
      expect(at.first, 5);
      expect(g.where((d) => d == 5).length, inInclusiveRange(10, 12));
      expect(g.where((d) => d == 10).length, inInclusiveRange(5, 6));
      expect(g.every((d) => d == 5 || d == 10 || d == 15), isTrue, reason: '$g');
      expect(g.sublist(g.length - 5), everyElement(15));
      // Five quiet minutes: about 35 asks, where every 5 s would be 60.
      expect(at.length, lessThan(40));
      // Still says it is here once a minute.
      expect(server.heartbeats.length, greaterThanOrEqualTo(5));
    });

    test('a sign-in code queued while quiet goes out within 15 s, and polling is fast again after', () async {
      await engine.start();
      await run(600); // long quiet: the slowest interval
      expect(engine.pollInterval, const Duration(seconds: 15));
      for (var offset = 0; offset < 15; offset++) {
        // Wherever in the interval the code is queued.
        await run(offset);
        server.queue.add(SmsJob(id: 'otp-$offset', channel: 'otp', to: '+60123456789', body: 'Your code is 1'));
        var waited = 0;
        while (phone.sent.length <= offset) {
          await run(1);
          waited++;
          expect(waited, lessThanOrEqualTo(15), reason: 'queued at offset $offset');
        }
        // Work makes it fast again: the next ask is 5 s later.
        expect(engine.pollInterval, const Duration(seconds: 5));
        expect(await run(5), [5]);
        await run(600); // and quiet again
      }
    });

    test('a received SMS is handed over at once, not at the next round', () async {
      await engine.start();
      await run(600);
      final claims = server.claims;
      now = now.add(const Duration(seconds: 1));
      phone.receive(IncomingSms(id: 'r1', from: '+60188888888', body: 'Hi', at: now));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(server.received.map((s) => s.id), ['r1']);
      expect(server.claims, claims + 1);
      expect(engine.pollInterval, const Duration(seconds: 5));
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
