// After signing in, the home page waits for the phone's location to be on
// (features/shell/location_service_gate.dart).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/app_permissions.dart';
import 'package:get_ride/src/data/permission_probe.dart';
import 'package:get_ride/src/features/shell/location_service_gate.dart';

class _Probe implements PermissionProbe {
  _Probe(this.on);
  bool on;
  var opened = 0;
  @override
  Future<(bool, PermState)> location() async => (on, PermState.granted);
  @override
  Future<bool> openLocationSettings() async {
    opened++;
    return true;
  }

  @override
  Future<PermState> notifications() async => PermState.granted;
  @override
  Future<Map<AppPermission, PermState>> statuses() async => const {};
  @override
  Future<PermState> requestLocation() async => PermState.granted;
  @override
  Future<void> request(AppPermission p) async {}
  @override
  Future<bool> openAppSettings() async => true;
}

void main() {
  for (final dark in [false, true]) {
    testWidgets('location off after sign-in holds the home page (${dark ? 'dark' : 'light'})', (tester) async {
      final probe = _Probe(false);
      final signIns = StreamController<void>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [permissionProbeProvider.overrideWithValue(probe)],
          child: MaterialApp(
            theme: dark ? ThemeData.dark() : ThemeData.light(),
            home: LocationServiceGate(signIns: signIns.stream, child: const Text('Home')),
          ),
        ),
      );
      // Nothing before a sign-in (a restored session at launch).
      expect(find.byKey(const ValueKey('location-service-off')), findsNothing);
      signIns.add(null);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('location-service-off')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('location-service-open')));
      expect(probe.opened, 1);
      // Back with it on: through to the home page.
      probe.on = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('location-service-off')), findsNothing);
      expect(find.text('Home'), findsOneWidget);
      await signIns.close();
    });
  }

  testWidgets('location on: straight through', (tester) async {
    final signIns = StreamController<void>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [permissionProbeProvider.overrideWithValue(_Probe(true))],
        child: MaterialApp(
          home: LocationServiceGate(signIns: signIns.stream, child: const Text('Home')),
        ),
      ),
    );
    signIns.add(null);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('location-service-off')), findsNothing);
    await signIns.close();
  });
}
