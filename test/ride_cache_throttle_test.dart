// Keeping a ride on the phone without rewriting the whole cache on every
// realtime update (lib/src/data/ride_cache.dart).
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ride_cache.dart';
import 'package:get_ride/src/data/ride_cache.dart';

class _Store extends RideCacheStore {
  _Store(DateTime Function() now) : super(now: now);
  final written = <Map<String, dynamic>>[];

  @override
  Future<void> save(Map<String, dynamic> row) async => written.add(row);
}

Map<String, dynamic> _ride({String status = 'accepted', double lat = 3.1, String? note, Map<String, dynamic>? meta}) =>
    {
      'id': 'r1',
      'status': status,
      'partner_live_lat': lat,
      'user_live_lat': lat,
      'updated_at': '$lat',
      'note': ?note,
      'metadata': meta ?? {'stops': [1, 2]},
    };

void main() {
  final t0 = DateTime(2026, 10, 18, 9);

  test('only the live columns moving is no change', () {
    expect(sameRideApartFromLive(_ride(), _ride(lat: 3.2)), isTrue);
    expect(sameRideApartFromLive(_ride(), _ride(note: 'x')), isFalse);
    expect(sameRideApartFromLive(_ride(), _ride(meta: {'stops': [1, 2]})), isTrue);
    expect(sameRideApartFromLive(_ride(), _ride(meta: {'stops': [1]})), isFalse);
  });

  test('the save delay: now, never, or when the gap is up', () {
    expect(rideCacheSaveDelay(row: _ride(), now: t0), Duration.zero);
    final at = t0.subtract(const Duration(seconds: 10));
    expect(rideCacheSaveDelay(last: _ride(), lastAt: at, row: _ride(lat: 4), now: t0), isNull);
    expect(rideCacheSaveDelay(last: _ride(), lastAt: at, row: _ride(status: 'arrived'), now: t0), Duration.zero);
    expect(
      rideCacheSaveDelay(last: _ride(), lastAt: at, row: _ride(note: 'x'), now: t0),
      const Duration(seconds: 20),
    );
    expect(
      rideCacheSaveDelay(last: _ride(), lastAt: t0.subtract(rideCacheLiveGap), row: _ride(note: 'x'), now: t0),
      Duration.zero,
    );
  });

  test('saveSeen: first and status changes at once, positions never, other changes once per gap', () {
    fakeAsync((clock) {
      final store = _Store(() => t0.add(clock.elapsed));
      store.saveSeen(_ride());
      expect(store.written, hasLength(1));
      // Positions only.
      for (var i = 0; i < 10; i++) {
        clock.elapse(const Duration(seconds: 2));
        store.saveSeen(_ride(lat: 3.1 + i));
      }
      expect(store.written, hasLength(1));
      // Another change, inside the gap: waits, and the latest one lands.
      store.saveSeen(_ride(note: 'a'));
      store.saveSeen(_ride(note: 'b'));
      expect(store.written, hasLength(1));
      clock.elapse(const Duration(seconds: 10));
      expect(store.written, hasLength(2));
      expect(store.written.last['note'], 'b');
      // A new status is written at once, and drops any wait.
      store.saveSeen(_ride(note: 'c'));
      store.saveSeen(_ride(status: 'arrived', note: 'c'));
      expect(store.written, hasLength(3));
      clock.elapse(rideCacheLiveGap);
      expect(store.written, hasLength(3));
    });
  });
}
