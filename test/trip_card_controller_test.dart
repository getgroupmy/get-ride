// The trip card controller (lib/src/data/trip_card_controller.dart) with a
// fake phone: it starts the card for the signed-in person's trip, moves it
// on (at once for a new stage, at most every 15 s within one), keeps the
// done card the admin's minutes, ends it on a cancel, and follows the
// admin's switches.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/trip_card.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/trip_card_controller.dart';
import 'package:get_ride/src/data/trip_card_platform.dart';
import 'package:get_ride/src/providers.dart';

class _FakePlatform implements TripCardPlatform {
  _FakePlatform({this.supported = true, this.accepts = true});

  @override
  final bool supported;

  /// What start answers (false: an iPhone without the extension yet).
  bool accepts;

  final calls = <(String, Map<String, Object?>)>[];

  List<String> get methods => [for (final c in calls) c.$1];
  Map<String, Object?> get last => calls.last.$2;

  @override
  Future<bool> start(Map<String, Object?> card) async {
    calls.add(('start', card));
    return accepts;
  }

  @override
  Future<bool> update(Map<String, Object?> card) async {
    calls.add(('update', card));
    return true;
  }

  @override
  Future<void> end(String rideId) async => calls.add(('end', {'rideId': rideId}));
}

class _FakeSource implements TripCardSource {
  RideRequest? rider;
  RideRequest? driver;
  final rows = StreamController<RideRequest>.broadcast();

  @override
  Future<RideRequest?> riderRide() async => rider;

  @override
  Future<RideRequest?> driverTrip() async => driver;

  @override
  Stream<RideRequest> watch(String rideId) => rows.stream;
}

class _Settings extends Notifier<TripCardSettings?> {
  @override
  TripCardSettings? build() => const TripCardSettings();

  void set(TripCardSettings? s) => state = s;
}

final _settings = NotifierProvider<_Settings, TripCardSettings?>(_Settings.new);

RideRequest _ride(String status, {Map<String, dynamic> extra = const {}, double liveLat = 3.0950}) => RideRequest({
  'id': 'ride-1',
  'status': status,
  'rider_id': 'rider',
  'rider_name': 'Aina',
  'partner_id': status == 'open' ? null : 'driver',
  'partner_name': 'Ali',
  'partner_plate': 'WXY 4821',
  'pickup_lat': 3.1180,
  'pickup_lng': 101.6770,
  'drop_lat': 3.1579,
  'drop_lng': 101.7116,
  'distance_km': 7.5,
  'duration_min': 18,
  'partner_accept_lat': 3.0910,
  'partner_accept_lng': 101.6770,
  'partner_live_lat': liveLat,
  'partner_live_lng': 101.6770,
  ...extra,
});

class _Rig {
  _Rig({String? user = 'rider', TripCardPlatform? platform}) : platform = platform ?? _FakePlatform() {
    container = ProviderContainer(
      overrides: [
        tripCardPlatformProvider.overrideWithValue(this.platform),
        tripCardSourceProvider.overrideWithValue(source),
        tripCardSettingsProvider.overrideWith((ref) => ref.watch(_settings)),
        tripCardColorsProvider.overrideWithValue((light: const TripCardColors(), dark: const TripCardColors())),
        tripCardClockProvider.overrideWithValue(() => now),
        currentUserIdProvider.overrideWithValue(user),
      ],
    );
  }

  final TripCardPlatform platform;
  final source = _FakeSource();
  late final ProviderContainer container;
  DateTime now = DateTime(2026, 10, 22, 15, 48);

  _FakePlatform get fake => platform as _FakePlatform;

  void start(FakeAsync async) {
    container.listen(tripCardControllerProvider, (_, _) {});
    async.flushMicrotasks();
  }

  void row(FakeAsync async, RideRequest r) {
    source.rows.add(r);
    async.flushMicrotasks();
  }

  void elapse(FakeAsync async, Duration d) {
    now = now.add(d);
    async.elapse(d);
  }

  TripCard? get card => container.read(tripCardControllerProvider);
}

void main() {
  test("starts the rider's card for the ride on the go, and follows it live", () {
    fakeAsync((async) {
      final rig = _Rig();
      rig.source.rider = _ride('accepted');
      rig.start(async);
      expect(rig.fake.methods, ['start']);
      expect(rig.fake.last['stage'], 'toPickup');
      expect(rig.fake.last['plate'], 'WXY 4821');
      expect(rig.card?.headline, startsWith('Ali is'));

      // The driver moves: the card's state follows, the phone waits 15 s.
      rig.elapse(async, const Duration(seconds: 5));
      rig.row(async, _ride('accepted', liveLat: 3.1050));
      expect(rig.fake.methods, ['start']);
      final moved = rig.card!.progress;
      expect(moved, greaterThan(0.05));

      // The latest move goes out once 15 s have passed.
      rig.elapse(async, const Duration(seconds: 10));
      expect(rig.fake.methods, ['start', 'update']);
      expect(rig.fake.last['progress'], moved);

      // A new stage goes at once.
      rig.elapse(async, const Duration(seconds: 1));
      rig.row(async, _ride('arrived'));
      expect(rig.fake.methods, ['start', 'update', 'update']);
      expect(rig.fake.last['stage'], 'arrived');
      rig.container.dispose();
    });
  });

  test('the bar never goes back within a stage', () {
    fakeAsync((async) {
      final rig = _Rig();
      rig.source.rider = _ride('accepted', liveLat: 3.1100);
      rig.start(async);
      final ahead = rig.card!.progress;
      rig.row(async, _ride('accepted', liveLat: 3.0950));
      expect(rig.card!.progress, ahead);
      rig.container.dispose();
    });
  });

  test('a cancelled ride takes the card down at once', () {
    fakeAsync((async) {
      final rig = _Rig();
      rig.source.rider = _ride('accepted');
      rig.start(async);
      rig.row(async, _ride('cancelled'));
      expect(rig.fake.methods, ['start', 'end']);
      expect(rig.card, isNull);
      // Nothing more for that ride.
      rig.row(async, _ride('accepted'));
      expect(rig.fake.methods, ['start', 'end']);
      rig.container.dispose();
    });
  });

  test("the done card stays the admin's minutes, then goes", () {
    fakeAsync((async) {
      final rig = _Rig();
      rig.source.rider = _ride('on_trip');
      rig.start(async);
      rig.row(async, _ride('completed', extra: {'completed_at': rig.now.toUtc().toIso8601String()}));
      expect(rig.fake.methods, ['start', 'update']);
      expect(rig.fake.last['stage'], 'done');
      expect(rig.fake.last['ongoing'], isFalse);
      expect(rig.fake.last['clearAfterMs'], 5 * 60 * 1000);
      expect(rig.fake.last['footTitle'], 'How was your ride?');
      rig.elapse(async, const Duration(minutes: 4, seconds: 59));
      expect(rig.fake.methods.last, 'update');
      rig.elapse(async, const Duration(seconds: 1));
      expect(rig.fake.methods.last, 'end');
      expect(rig.card, isNull);
      rig.container.dispose();
    });
  });

  test('0 minutes clears the card as soon as the trip ends', () {
    fakeAsync((async) {
      final rig = _Rig();
      rig.container.read(_settings.notifier).set(const TripCardSettings(doneMinutes: 0));
      rig.source.rider = _ride('on_trip');
      rig.start(async);
      rig.row(async, _ride('completed', extra: {'completed_at': rig.now.toUtc().toIso8601String()}));
      expect(rig.fake.methods, ['start', 'end']);
      rig.container.dispose();
    });
  });

  test('a trip that ended longer ago than the minutes shows nothing', () {
    fakeAsync((async) {
      final rig = _Rig();
      final ended = rig.now.subtract(const Duration(minutes: 30)).toUtc().toIso8601String();
      rig.source.rider = _ride('completed', extra: {'completed_at': ended});
      rig.start(async);
      expect(rig.fake.calls, isEmpty);
      rig.container.dispose();
    });
  });

  test("a service switched off shows no card, and takes one down; on again brings it back", () {
    fakeAsync((async) {
      final rig = _Rig();
      rig.container.read(_settings.notifier).set(const TripCardSettings(courier: false));
      rig.source.rider = _ride('accepted', extra: {'parcel_size': 'S', 'cargo_description': 'Documents'});
      rig.start(async);
      expect(rig.fake.calls, isEmpty);
      rig.container.read(_settings.notifier).set(const TripCardSettings());
      async.elapse(Duration.zero);
      expect(rig.fake.methods, ['start']);
      expect(rig.fake.last['service'], 'courier');
      rig.container.read(_settings.notifier).set(const TripCardSettings(courier: false));
      async.elapse(Duration.zero);
      expect(rig.fake.methods, ['start', 'end']);
      rig.container.dispose();
    });
  });

  test('nothing until the admin settings are read', () {
    fakeAsync((async) {
      final rig = _Rig();
      rig.container.read(_settings.notifier).set(null);
      rig.source.rider = _ride('accepted');
      rig.start(async);
      expect(rig.fake.calls, isEmpty);
      rig.container.read(_settings.notifier).set(const TripCardSettings());
      async.elapse(Duration.zero);
      expect(rig.fake.methods, ['start']);
      rig.container.dispose();
    });
  });

  test("the driver's own card, unless the admin switched it off", () {
    fakeAsync((async) {
      final rig = _Rig(user: 'driver');
      rig.source.driver = _ride('accepted');
      rig.start(async);
      expect(rig.fake.last['role'], 'driver');
      expect(rig.card!.headline, startsWith('Pick up Aina'));
      expect(rig.fake.last['openUri'], 'getride://trip/ride-1?as=driver');
      rig.container.read(_settings.notifier).set(const TripCardSettings(driver: false));
      async.elapse(Duration.zero);
      expect(rig.fake.methods, ['start', 'end']);
      rig.container.dispose();
    });
  });

  test('a phone that cannot show it (web, desktop) is never asked', () {
    fakeAsync((async) {
      final rig = _Rig(platform: _FakePlatform(supported: false));
      rig.source.rider = _ride('accepted');
      rig.start(async);
      rig.container.read(tripCardControllerProvider.notifier).follow('ride-1', ride: _ride('accepted'));
      async.flushMicrotasks();
      expect(rig.fake.calls, isEmpty);
      expect(rig.card, isNull);
      rig.container.dispose();
    });
  });

  test('a phone that says no (an iPhone without the card yet) is asked again only at the update pace', () {
    fakeAsync((async) {
      final rig = _Rig(platform: _FakePlatform(accepts: false));
      rig.source.rider = _ride('accepted');
      rig.start(async);
      rig.row(async, _ride('accepted', liveLat: 3.1000));
      rig.row(async, _ride('accepted', liveLat: 3.1010));
      expect(rig.fake.methods, ['start']);
      rig.elapse(async, const Duration(seconds: 15));
      expect(rig.fake.methods, ['start', 'start']);
      rig.container.dispose();
    });
  });

  test('a demo ride and an old trip from the history leave the live card alone', () {
    fakeAsync((async) {
      final rig = _Rig();
      rig.source.rider = _ride('on_trip');
      rig.start(async);
      final controller = rig.container.read(tripCardControllerProvider.notifier);
      controller.follow('demo-1');
      controller.follow('old', ride: RideRequest({..._ride('completed').raw, 'id': 'old'}));
      async.flushMicrotasks();
      expect(rig.fake.methods, ['start']);
      expect(controller.rideId, 'ride-1');
      rig.container.dispose();
    });
  });

  test('signed out: the card goes', () {
    fakeAsync((async) {
      final rig = _Rig(user: null);
      rig.source.rider = _ride('accepted');
      rig.start(async);
      expect(rig.fake.calls, isEmpty);
      rig.container.dispose();
    });
  });
}
