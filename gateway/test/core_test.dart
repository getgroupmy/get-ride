import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:getride_gateway/src/app.dart';
import 'package:getride_gateway/src/core.dart';

void main() {
  test('a job reads off a claimed outbox row', () {
    final j = SmsJob.fromRow({
      'id': 'a1',
      'channel': 'otp',
      'to_phone': ' +60123456789 ',
      'body': 'Your code is 1234',
      'attempts': 2,
    })!;
    expect(j.to, '+60123456789');
    expect(j.attempts, 2);
    expect(SmsJob.fromRow({'id': 'a2', 'to_phone': '', 'body': 'x'}), isNull);
  });

  test('the log hides numbers and never shows a sign-in code', () {
    expect(maskPhone('+60123456789'), '+6012****789');
    expect(maskPhone('0123456789'), '012****789');
    expect(maskPhone('12345'), '12345');
    final s = jobSummary(const SmsJob(id: 'x', channel: 'otp', to: '+60123456789', body: 'Your code is 4321'));
    expect(s, 'Sign-in code to +6012****789');
    expect(s, isNot(contains('4321')));
  });

  test('backoff doubles from five seconds to at most two minutes', () {
    expect([for (var i = 0; i <= 7; i++) backoffAfter(i).inSeconds], [0, 5, 10, 20, 40, 80, 120, 120]);
  });

  test('server refusals stop the gateway with a reason; network errors do not', () {
    expect(gatewayRefusal(Exception('PostgrestException(message: GATEWAY_NEEDS_ADMIN)')), contains('not an admin'));
    expect(gatewayRefusal(Exception('NOT_A_GATEWAY')), isNotNull);
    expect(gatewayRefusal(Exception('SocketException: Failed host lookup')), isNull);
    expect(describeError(Exception('SocketException: Failed host lookup')), 'No connection to the server.');
  });

  test('pairing codes are read as typed, and the pairing answer gives the key or why not', () {
    expect(normalizePairCode('abcd-2345 '), 'ABCD2345');
    expect(isPairCode('ABCD-2345'), isTrue);
    expect(isPairCode('ABCD-234'), isFalse);
    final key = 'k' * 64;
    expect(pairResult({'key': key, 'device': 'd1'}).key, key);
    expect(
      pairResult({'error': 'GATEWAY_PAIR_CODE', 'hint': 'That code is wrong or has expired.'}).error,
      'That code is wrong or has expired.',
    );
    expect(pairResult(null).error, contains('Please try again'));
    expect(gatewayRefusal(Exception('GATEWAY_KEY_INVALID')), contains('no longer paired'));
  });

  test('incoming SMS and SIMs read off the platform maps', () {
    final s = IncomingSms.fromMap({'id': 'p1', 'from': '+60199999999', 'body': 'Hi', 'at': 1700000000000})!;
    expect(s.at, DateTime.fromMillisecondsSinceEpoch(1700000000000));
    expect(IncomingSms.fromMap({'id': '', 'from': 'x'}), isNull);
    final sim = SimCard.fromMap({'id': 3, 'label': 'Maxis', 'number': '+60111', 'slot': 1})!;
    expect(sim.title, 'SIM 2 · Maxis (+60111)');
    expect(SimCard.fromMap({'label': 'x'}), isNull);
  });

  test('the shared internet\'s events: a state, a line for the log, hosts only', () {
    expect(proxyStateFrom({'state': 'connected'}), ProxyState.connected);
    expect(proxyStateFrom({'state': 'error', 'reason': 'x'}), ProxyState.error);
    expect(proxyStateFrom({'state': 'request', 'host': 'a'}), isNull);
    expect(proxyStateFrom({'state': 'mobile', 'available': true}), isNull);
    expect(proxyStateFrom({}), isNull);
    expect(proxyLogLine({'state': 'request', 'host': 'api.example.com', 'status': 404}),
        'Relayed a request to api.example.com (404)');
    expect(proxyLogLine({'state': 'request', 'host': 'api.example.com', 'error': 'timeout'}),
        'Request to api.example.com failed: timeout');
    expect(proxyLogLine({'state': 'error', 'reason': 'refused'}), contains('refused'));
    expect(proxyLogLine({'state': 'mobile', 'available': false}), contains('down'));
    expect(proxyLogLine({'state': 'connecting'}), isNull);
  });

  test('the version the admin page shows matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec)!.group(1), startsWith('$gatewayVersion+'));
  });
}
