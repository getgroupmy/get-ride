// A request past its search time no longer counts as on the go, even before
// it is marked expired (lib/src/data/ride_repository.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/config.dart';
import 'package:get_ride/src/data/ride_repository.dart' show isStaleOpenRow;

void main() {
  final now = DateTime.utc(2026, 10, 18, 9);
  String ago(Duration d) => now.subtract(d).toIso8601String();

  test('an open request past its search time is stale; anything else is not', () {
    final past = AppConfig.requestExpiry + const Duration(seconds: 1);
    expect(isStaleOpenRow({'status': 'open', 'created_at': ago(past)}, now), isTrue);
    expect(isStaleOpenRow({'status': 'open', 'created_at': ago(const Duration(minutes: 1))}, now), isFalse);
    expect(isStaleOpenRow({'status': 'accepted', 'created_at': ago(past)}, now), isFalse);
    expect(isStaleOpenRow({'status': 'open'}, now), isFalse);
  });
}
