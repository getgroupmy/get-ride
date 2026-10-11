// The rides kept on the phone for when there is no connection
// (lib/src/core/ride_cache.dart) and the strip shown over them.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/ride_cache.dart';
import 'package:get_ride/src/widgets/offline_ride_banner.dart';

Map<String, dynamic> row(String id, {String status = 'accepted', String rider = 'u1', String? created}) => {
  'id': id,
  'rider_id': rider,
  'partner_id': 'd1',
  'status': status,
  'created_at': created ?? '2026-10-11T08:00:00Z',
};

void main() {
  final now = DateTime.utc(2026, 10, 11, 9);

  test('a ride survives being stored and read back', () {
    final cache = withCachedRide({}, row('r1'), now);
    final back = decodeRideCache(encodeRideCache(cache), now);
    expect(back.keys, ['r1']);
    expect(back['r1']!.row['status'], 'accepted');
    expect(back['r1']!.savedAt.isAtSameMomentAs(now), isTrue);
  });

  test('broken entries, a mismatched id and anything too old are not shown', () {
    expect(decodeRideCache(null, now), isEmpty);
    expect(decodeRideCache('nonsense', now), isEmpty);
    expect(decodeRideCache('[1, 2]', now), isEmpty);
    final stored = encodeRideCache({
      'r1': CachedRide(row('r1'), now.subtract(const Duration(hours: 1))),
      'r2': CachedRide(row('r2'), now.subtract(rideCacheMaxAge)),
      'r3': CachedRide(row('other'), now),
    });
    expect(decodeRideCache(stored, now).keys, ['r1']);
  });

  test('only the newest rides are kept, and a newer copy replaces the older', () {
    var cache = <String, CachedRide>{};
    for (var i = 0; i < rideCacheMaxRides + 3; i++) {
      cache = withCachedRide(cache, row('r$i'), now.add(Duration(minutes: i)));
    }
    expect(cache.length, rideCacheMaxRides);
    expect(cache.containsKey('r0'), isFalse);
    expect(cache.containsKey('r${rideCacheMaxRides + 2}'), isTrue);

    cache = withCachedRide(cache, row('r5', status: 'on_trip'), now.add(const Duration(hours: 1)));
    expect(cache['r5']!.row['status'], 'on_trip');
    expect(withCachedRide(cache, {'status': 'x'}, now), same(cache), reason: 'a row with no id is not kept');
  });

  test('the rides in progress are this account\'s, in a live status, newest first', () {
    final cache = {
      'old': CachedRide(row('old', created: '2026-10-11T07:00:00Z'), now),
      'new': CachedRide(row('new', status: 'on_trip', created: '2026-10-11T08:30:00Z'), now),
      'done': CachedRide(row('done', status: 'completed'), now),
      'theirs': CachedRide(row('theirs', rider: 'u2'), now),
    };
    final found = cachedRidesInProgress(cache, uid: 'u1', column: 'rider_id', statuses: ['accepted', 'on_trip']);
    expect(found.map((c) => c.row['id']), ['new', 'old']);
    expect(cachedRidesInProgress(cache, uid: 'd1', column: 'partner_id', statuses: ['arrived']), isEmpty);
  });

  for (final brightness in Brightness.values) {
    testWidgets('the no-connection strip says when the ride was last seen (${brightness.name})', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(brightness),
          home: Scaffold(body: OfflineRideBanner(cachedAt: DateTime(2026, 10, 11, 8, 5))),
        ),
      );
      expect(find.textContaining('No connection'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
