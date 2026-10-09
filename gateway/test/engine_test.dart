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

  test('a refusal (not an admin) stops the gateway and says why', () async {
    server.failWith = Exception('PostgrestException(message: GATEWAY_NEEDS_ADMIN, code: 42501)');
    await engine.start();
    expect(engine.state, GatewayState.off);
    expect(engine.stopReason, contains('not an admin'));
    expect(phone.serviceRunning, isFalse);
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
