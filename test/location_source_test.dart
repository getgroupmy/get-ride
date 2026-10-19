// PERF-4: the home screen shows the rider and the pickup on the last known
// (or a quick) fix at once, then the accurate one (data/location_source.dart).
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get_ride/src/data/location_source.dart';
import 'package:latlong2/latlong.dart';

const _last = LatLng(3.1000, 101.6000);
const _rough = LatLng(3.1010, 101.6010);
const _fine = LatLng(3.1003, 101.6004);

/// A phone whose fixes come when the test says.
class FakeLocation implements LocationSource {
  FakeLocation({this.on = true, this.permission = LocationPermission.whileInUse, this.granted, this.last});

  bool on;
  LocationPermission permission;

  /// What asking for permission answers; null leaves it as it was.
  LocationPermission? granted;
  LatLng? last;
  int asked = 0;
  final fine = Completer<LatLng>();
  final rough = Completer<LatLng>();
  final accuracies = <LocationAccuracy>[];

  @override
  Future<bool> serviceEnabled() async => on;

  @override
  Future<LocationPermission> checkPermission() async => permission;

  @override
  Future<LocationPermission> requestPermission() async {
    asked++;
    return permission = granted ?? permission;
  }

  @override
  Future<LatLng?> lastKnown() async => last;

  @override
  Future<LatLng> current(LocationAccuracy accuracy) {
    accuracies.add(accuracy);
    return accuracy == LocationAccuracy.high ? fine.future : rough.future;
  }
}

void main() {
  test('the last known fix at once, then the accurate one', () async {
    final src = FakeLocation(last: _last);
    final got = <LatLng>[];
    final done = Completer<void>();
    locateFastThenFine(src, isWeb: false).listen(got.add, onDone: done.complete);
    await pumpEventQueue();
    expect(got, [_last], reason: 'before any GPS fix');
    expect(src.accuracies, [LocationAccuracy.high], reason: 'the accurate fix asked for at once, no rough one needed');
    src.fine.complete(_fine);
    await done.future;
    expect(got, [_last, _fine]);
  });

  test('no last known fix: a quick low-accuracy one first', () async {
    final src = FakeLocation();
    final got = <LatLng>[];
    final done = Completer<void>();
    locateFastThenFine(src, isWeb: false).listen(got.add, onDone: done.complete);
    await pumpEventQueue();
    expect(src.accuracies, containsAll([LocationAccuracy.high, LocationAccuracy.low]));
    src.rough.complete(_rough);
    await pumpEventQueue();
    expect(got, [_rough]);
    src.fine.complete(_fine);
    await done.future;
    expect(got, [_rough, _fine]);
  });

  test('the web has no last known fix', () async {
    final src = FakeLocation(last: _last);
    final got = <LatLng>[];
    locateFastThenFine(src, isWeb: true).listen(got.add);
    await pumpEventQueue();
    expect(got, isEmpty);
    src.rough.complete(_rough);
    await pumpEventQueue();
    expect(got, [_rough]);
  });

  test('an accurate fix that comes first is the only one', () async {
    final src = FakeLocation();
    final got = <LatLng>[];
    final done = Completer<void>();
    locateFastThenFine(src, isWeb: false).listen(got.add, onDone: done.complete);
    src.fine.complete(_fine);
    await pumpEventQueue();
    src.rough.complete(_rough);
    await done.future;
    expect(got, [_fine]);
  });

  test('the same point twice is given once', () async {
    final src = FakeLocation(last: _fine);
    final got = <LatLng>[];
    final done = Completer<void>();
    locateFastThenFine(src, isWeb: false).listen(got.add, onDone: done.complete);
    await pumpEventQueue();
    src.fine.complete(_fine);
    await done.future;
    expect(got, [_fine]);
  });

  test('no accurate fix in time keeps the quick one', () {
    fakeAsync((async) {
      final src = FakeLocation(last: _last);
      final got = <LatLng>[];
      var done = false;
      locateFastThenFine(src, isWeb: false).listen(got.add, onDone: () => done = true);
      async.flushMicrotasks();
      expect(got, [_last]);
      async.elapse(fineFixTimeout);
      expect(done, isTrue);
      expect(got, [_last]);
    });
  });

  test('location off: nothing, and nothing asked', () async {
    final src = FakeLocation(on: false, last: _last);
    expect(await locateFastThenFine(src, isWeb: false).toList(), isEmpty);
    expect(src.asked, 0);
    expect(src.accuracies, isEmpty);
  });

  test('permission asked when not yet refused; refused gives nothing', () async {
    final yes = FakeLocation(permission: LocationPermission.denied, granted: LocationPermission.whileInUse, last: _last);
    final got = <LatLng>[];
    locateFastThenFine(yes, isWeb: false).listen(got.add);
    await pumpEventQueue();
    expect(yes.asked, 1);
    expect(got, [_last]);

    final no = FakeLocation(permission: LocationPermission.denied, last: _last);
    expect(await locateFastThenFine(no, isWeb: false).toList(), isEmpty);
    expect(no.asked, 1);

    final never = FakeLocation(permission: LocationPermission.deniedForever, last: _last);
    expect(await locateFastThenFine(never, isWeb: false).toList(), isEmpty);
    expect(never.asked, 0, reason: 'a refusal for good is not asked again');
  });
}
