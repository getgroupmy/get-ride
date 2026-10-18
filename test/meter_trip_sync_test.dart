import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/meter_trip.dart';
import 'package:get_ride/src/data/meter_trip_sync.dart';
import 'package:get_ride/src/data/meter_trips_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

MeterTrip _trip(String id, int endedAt) => MeterTrip.fromJson({
      'id': id,
      'startedAt': endedAt - 600000,
      'endedAt': endedAt,
      'distanceM': 5200,
      'fare': 12.4,
      'total': 15.4,
      'airportSurcharge': 3,
    })!;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('pending: the hires not yet sent, oldest first', () {
    final roll = [_trip('c', 3), _trip('b', 2), _trip('a', 1)]; // newest first, as the roll keeps them
    expect(pendingMeterTrips(roll, {'b'}).map((t) => t.id), ['a', 'c']);
    expect(pendingMeterTrips(roll, {'a', 'b', 'c'}), isEmpty);
  });

  test('sends what is waiting once; with no signal it waits for the next try', () async {
    final store = MeterTripsStore();
    await store.save(_trip('a', 1000));
    await store.save(_trip('b', 2000));
    final sent = <String>[];
    var online = false;
    final sync = MeterTripSync(store, (trip) async {
      if (!online) throw Exception('no signal');
      sent.add(trip['id'] as String);
    });

    final first = await sync.sendPending();
    expect(first.stop, MeterSyncStop.offline);
    expect(first.sent, 0);

    online = true;
    final second = await sync.sendPending();
    expect(second.sent, 2);
    expect(sent, ['a', 'b'], reason: 'oldest first');
    expect(sent.first, 'a');

    await store.save(_trip('c', 3000));
    await sync.sendPending();
    expect(sent, ['a', 'b', 'c'], reason: 'a hire is sent once');
  });

  test('the payload carries what the server reads', () {
    final j = _trip('a', 1000).toJson();
    for (final k in ['id', 'startedAt', 'endedAt', 'distanceM', 'fare', 'total', 'extra', 'airportSurcharge',
      'cardSurcharge', 'pickup', 'dropoff', 'currency']) {
      expect(j.containsKey(k), isTrue, reason: k);
    }
  });

  test('not a partner: stops; a hire the server refuses as impossible is not retried', () async {
    final store = MeterTripsStore();
    await store.save(_trip('bad', 1000));
    await store.save(_trip('ok', 2000));
    final tries = <String>[];
    var partner = false;
    final sync = MeterTripSync(store, (trip) async {
      tries.add(trip['id'] as String);
      if (!partner) throw const PostgrestException(message: 'METER_TRIP_NOT_PARTNER', code: '42501');
      if (trip['id'] == 'bad') throw const PostgrestException(message: 'METER_TRIP_INVALID', code: '22023');
    });
    expect((await sync.sendPending()).stop, MeterSyncStop.notPartner);
    expect(tries, ['bad']);

    partner = true;
    final r = await sync.sendPending();
    expect(r.sent, 1);
    expect(r.stop, MeterSyncStop.done);
    tries.clear();
    await sync.sendPending();
    expect(tries, isEmpty, reason: 'neither is tried again');
  });
}
