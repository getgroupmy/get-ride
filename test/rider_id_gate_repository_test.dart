import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/rider_id_gate_repository.dart';

void main() {
  group('parseRiderVerify', () {
    test('verified', () {
      final r = parseRiderVerify({'verified': true, 'pending': false});
      expect([r.verified, r.pending], [true, false]);
    });

    test('verified true forces pending false even if the reply disagrees', () {
      final r = parseRiderVerify({'verified': true, 'pending': true});
      expect([r.verified, r.pending], [true, false]);
    });

    test('pending (not verified)', () {
      final r = parseRiderVerify({'verified': false, 'pending': true});
      expect([r.verified, r.pending], [false, true]);
    });

    test('a malformed reply is treated as not-verified, pending', () {
      for (final bad in [null, 'x', 42, <String, dynamic>{}]) {
        final r = parseRiderVerify(bad);
        expect([r.verified, r.pending], [false, true], reason: '$bad');
      }
    });
  });
}
