// Sign-in answers (migration 0192): tries left after a wrong PIN, the lock,
// the admin's policy, and one message for no connection.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/auth_utils.dart';
import 'package:get_ride/src/widgets/common.dart';

void main() {
  const policy = PinPolicy(maxAttempts: 5, lockMinutes: 15);

  test('pin-login tells how many tries are left', () {
    expect(
      pinLoginOutcome(401, {'error': 'wrong_pin', 'attempts_left': 3}),
      isA<PinLoginWrongPin>().having((o) => o.attemptsLeft, 'attemptsLeft', 3),
    );
    expect(
      pinLoginOutcome(401, {'error': 'wrong_pin'}),
      isA<PinLoginWrongPin>().having((o) => o.attemptsLeft, 'attemptsLeft', isNull),
    );
  });

  test('tries left are counted down from the second wrong PIN', () {
    expect(wrongPinMessage(4, policy), 'Incorrect PIN. Please try again.', reason: 'first wrong PIN');
    expect(wrongPinMessage(3, policy), 'Wrong PIN. 3 tries left.');
    expect(wrongPinMessage(1, policy), 'Wrong PIN. 1 try left.');
    expect(wrongPinMessage(0, policy), contains('sign in with an SMS code'));
    expect(wrongPinMessage(null, policy), 'Incorrect PIN. Please try again.', reason: 'nothing said about the number');
  });

  test('a locked PIN says for how long and offers the SMS code', () {
    expect(signInLockMessage(840), 'PIN locked for 14 minutes, or sign in with an SMS code.');
    expect(signInLockMessage(30), 'PIN locked for 1 minute, or sign in with an SMS code.');
    expect(
      pinLoginOutcome(423, {'error': 'locked', 'retry_after': 840}),
      isA<PinLoginRefused>().having((o) => o.message, 'message', signInLockMessage(840)),
    );
  });

  test('the admin policy reads within its limits', () {
    final p = PinPolicy.fromJson({'maxAttempts': 4, 'lockMinutes': 20});
    expect(p, const PinPolicy(maxAttempts: 4, lockMinutes: 20));
    expect(PinPolicy.fromJson(p.toJson()), p);
    expect(PinPolicy.fromJson({'maxAttempts': 1, 'lockMinutes': 0}), const PinPolicy(maxAttempts: 3, lockMinutes: 1));
    expect(PinPolicy.fromJson(null), PinPolicy.standard);
  });

  test('no network reads the same everywhere', () {
    expect(errorText(const SocketException('Failed host lookup: x.supabase.co')), noConnectionMessage);
    expect(errorText(Exception('ClientException: Connection closed')), noConnectionMessage);
    expect(errorText(StateError('Something else')), 'Something else');
  });
}
