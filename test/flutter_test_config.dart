// Runs before every test file: the plugin channels a widget test reaches
// without meaning to answer at once, as a phone that has allowed everything
// would. A channel with no answer never replies in a widget test, which
// would hang whatever awaits it (the driver's go-online check reads the
// location permission). Tests that care override permissionProbeProvider.
// Only where a test has started the widget binding: starting it here would
// block the real HTTP some plain tests make.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/date_order.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // Dates in the Malaysian order (day first) unless a test picks a country:
  // the test machine's locale is en-US.
  deviceDateCountry = () => 'MY';
  setUp(() {
    setProfileDateCountry(null);
    final WidgetsBinding binding;
    try {
      binding = WidgetsBinding.instance;
    } catch (_) {
      return;
    }
    if (binding is! TestWidgetsFlutterBinding) return;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Future<Object?> geolocator(MethodCall call) async => switch (call.method) {
      'isLocationServiceEnabled' => true,
      // LocationPermission.always.
      'checkPermission' || 'requestPermission' => 3,
      _ => null,
    };
    for (final name in ['flutter.baseflow.com/geolocator', 'flutter.baseflow.com/geolocator_android']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), geolocator);
    }
    // And its position updates: a phone that has allowed location starts them
    // when asked (the rider's home map follows them, as the driver's does) and
    // then has no new fix to give. Unanswered, the request to start them was
    // reported as an error by any test that waits on real time (a screenshot).
    for (final name in [
      'flutter.baseflow.com/geolocator_updates',
      'flutter.baseflow.com/geolocator_updates_android',
      'flutter.baseflow.com/geolocator_updates_apple',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async => null);
    }
    messenger.setMockMethodCallHandler(const MethodChannel('get_ride/permissions'), (call) async => null);
  });
  await testMain();
}
