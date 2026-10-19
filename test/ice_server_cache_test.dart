// The ICE servers are fetched ahead of a call and kept while their relay
// credentials last (PERF-70).
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/ice_server_cache.dart';

Map<String, dynamic> _answer({Object? ttl = 21600, String user = 'u1'}) => {
  'iceServers': [
    {
      'urls': ['stun:stun.example.com:3478'],
    },
    {
      'urls': ['turn:turn.example.com:3478'],
      'username': '1700000000:$user',
      'credential': 'secret',
    },
  ],
  'ttl': ?ttl,
  'relay': true,
};

void main() {
  late DateTime now;
  late String? user;
  late int fetches;
  late Object? Function() reply;
  late IceServerCache cache;

  setUp(() {
    now = DateTime.utc(2026, 10, 18, 9);
    user = 'u1';
    fetches = 0;
    reply = _answer;
    cache = IceServerCache(
      () async {
        fetches++;
        final r = reply();
        if (r is Exception) throw r;
        return r;
      },
      user: () => user,
      clock: () => now,
    );
  });

  bool relayed(List<Map<String, dynamic>> servers) => servers.any((s) => s['credential'] == 'secret');

  test('usable until the renew margin before the lifetime ends', () {
    final at = DateTime.utc(2026);
    expect(iceServersUsableUntil(at, 21600), at.add(const Duration(hours: 6) - iceServersRenewBefore));
    // A short lifetime keeps half of it as the margin.
    expect(iceServersUsableUntil(at, 600), at.add(const Duration(minutes: 5)));
    for (final bad in [null, 0, -5, '21600', double.nan, double.infinity]) {
      expect(iceServersUsableUntil(at, bad), isNull, reason: '$bad');
    }
  });

  test('a kept set serves the next calls without asking again', () async {
    final first = await cache.get();
    expect(relayed(first), isTrue);
    now = now.add(const Duration(hours: 5));
    expect(await cache.get(), first);
    expect(fetches, 1);
  });

  test('a prefetch under way is shared with the call that starts meanwhile', () async {
    cache.prefetch();
    cache.prefetch();
    final servers = await cache.get();
    expect(relayed(servers), isTrue);
    expect(fetches, 1);
    // Already kept: nothing more to fetch.
    cache.prefetch();
    await Future<void>.delayed(Duration.zero);
    expect(fetches, 1);
  });

  test('credentials close to expiry are never handed out: fetched again', () async {
    await cache.get();
    now = now.add(const Duration(hours: 6) - iceServersRenewBefore - const Duration(seconds: 1));
    await cache.get();
    expect(fetches, 1);
    now = now.add(const Duration(seconds: 1));
    await cache.get();
    expect(fetches, 2, reason: 'within the renew margin of the 6 h lifetime');
    // Long after expiry: fetched again, never the old set.
    now = now.add(const Duration(days: 1));
    reply = () => _answer(ttl: 600);
    await cache.get();
    expect(fetches, 3);
    now = now.add(const Duration(minutes: 5));
    await cache.get();
    expect(fetches, 4, reason: 'a 10-minute lifetime is kept for 5');
  });

  test('the lifetime runs from when the fetch started, not when it answered', () {
    fakeAsync((clock) {
      final slow = IceServerCache(
        () => Future.delayed(const Duration(seconds: 2), () {
          fetches++;
          return _answer(ttl: 600);
        }),
        clock: () => now,
      );
      slow.prefetch();
      now = now.add(const Duration(minutes: 5) - const Duration(seconds: 1));
      clock.elapse(const Duration(seconds: 2));
      expect(fetches, 1);
      slow.get();
      clock.flushMicrotasks();
      expect(fetches, 1);
      now = now.add(const Duration(seconds: 1));
      slow.get();
      clock.elapse(const Duration(seconds: 2));
      expect(fetches, 2);
    });
  });

  test('an answer with no lifetime is used once, not kept', () async {
    reply = () => _answer(ttl: null);
    expect(relayed(await cache.get()), isTrue);
    await cache.get();
    expect(fetches, 2);
  });

  test('a failed fetch falls back to STUN for this call and is not kept', () async {
    reply = () => Exception('down');
    final servers = await cache.get();
    expect(relayed(servers), isFalse);
    expect(servers.single['urls'], ['stun:stun.l.google.com:19302']);

    // A failed prefetch is quiet; the call then fetches for itself.
    cache.prefetch();
    await Future<void>.delayed(Duration.zero);
    reply = _answer;
    expect(relayed(await cache.get()), isTrue);
    expect(fetches, 3);

    // Something unusable is not kept either.
    final fresh = IceServerCache(() async {
      fetches++;
      return 'oops';
    }, clock: () => now);
    expect(relayed(await fresh.get()), isFalse);
    await fresh.get();
    expect(fetches, 5);
  });

  test('another account signed in gets credentials of its own', () async {
    await cache.get();
    user = 'u2';
    reply = () => _answer(user: 'u2');
    final theirs = await cache.get();
    expect(theirs.last['username'], '1700000000:u2');
    expect(fetches, 2);
    await cache.get();
    expect(fetches, 2);
  });
}
