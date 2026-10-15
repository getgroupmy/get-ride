// The page that holds a rider before the home map until what Admin → App
// Settings → Permissions enforces is done (features/shell/permission_gate.dart),
// and the admin's card for those rules.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/permission_rules_card.dart';
import 'package:get_ride/src/core/app_permissions.dart';
import 'package:get_ride/src/data/permission_probe.dart';
import 'package:get_ride/src/data/permission_rules.dart';
import 'package:get_ride/src/features/shell/permission_gate.dart';
import 'package:get_ride/src/providers.dart';

class _Probe implements PermissionProbe {
  _Probe({this.service = true, this.loc = PermState.granted, this.notif = PermState.granted});
  bool service;
  PermState loc;
  PermState notif;
  final requested = <AppPermission>[];
  var locationSettings = 0;

  @override
  Future<(bool, PermState)> location() async => (service, loc);
  @override
  Future<PermState> notifications() async => notif;
  @override
  Future<bool> openLocationSettings() async {
    locationSettings++;
    return true;
  }

  @override
  Future<PermState> requestLocation() async => loc;
  @override
  Future<void> request(AppPermission p) async {
    requested.add(p);
    if (p == AppPermission.notifications) notif = PermState.granted;
  }

  @override
  Future<bool> openAppSettings() async => true;
  @override
  Future<Map<AppPermission, PermState>> statuses() async => const {};
}

void main() {
  Future<void> pump(
    WidgetTester tester,
    _Probe probe, {
    String location = '/',
    String? user = 'me',
    PermissionRules rules = PermissionRules.defaults,
    ThemeData? theme,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          permissionProbeProvider.overrideWithValue(probe),
          permissionRulesProvider.overrideWith((_) async => rules),
          currentUserIdProvider.overrideWithValue(user),
        ],
        child: MaterialApp(
          theme: theme,
          home: PermissionGate(enabled: true, location: () => location, child: const Text('Home map')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final dark in [false, true]) {
    testWidgets('a signed-in rider waits until location and notifications are on (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      final probe = _Probe(service: false, notif: PermState.notAsked);
      await pump(tester, probe, theme: dark ? ThemeData.dark() : ThemeData.light());
      expect(find.byKey(const ValueKey('permissions-required')), findsOneWidget);
      expect(find.byKey(const ValueKey('permission-block-serviceOff')), findsOneWidget);
      expect(find.byKey(const ValueKey('permission-block-notificationsNotAsked')), findsOneWidget);

      // Notifications: the phone's question, asked from here.
      await tester.tap(find.byKey(const ValueKey('permission-fix-notificationsNotAsked')));
      await tester.pumpAndSettle();
      expect(probe.requested, [AppPermission.notifications]);
      expect(find.byKey(const ValueKey('permission-block-notificationsNotAsked')), findsNothing);

      // Location: the phone's settings; back with it on, through to the map.
      await tester.ensureVisible(find.byKey(const ValueKey('permission-fix-serviceOff')));
      await tester.tap(find.byKey(const ValueKey('permission-fix-serviceOff')));
      await tester.pumpAndSettle();
      expect(probe.locationSettings, 1);
      probe.service = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('permissions-required')), findsNothing);
      expect(find.text('Home map'), findsOneWidget);
    });
  }

  testWidgets('nothing holds anyone up when all is on, signed out, or off the rider screens', (tester) async {
    await pump(tester, _Probe());
    expect(find.byKey(const ValueKey('permissions-required')), findsNothing);
    await pump(tester, _Probe(service: false), user: null);
    expect(find.byKey(const ValueKey('permissions-required')), findsNothing);
    await pump(tester, _Probe(service: false), location: '/admin/users');
    expect(find.byKey(const ValueKey('permissions-required')), findsNothing);
    await pump(tester, _Probe(service: false), location: '/drive');
    expect(find.byKey(const ValueKey('permissions-required')), findsNothing);
  });

  testWidgets('a check the admin bypassed holds nobody up', (tester) async {
    const rules = PermissionRules(user: PermissionChecks(notifications: false));
    await pump(tester, _Probe(notif: PermState.denied), rules: rules);
    expect(find.byKey(const ValueKey('permissions-required')), findsNothing);
    await pump(
      tester,
      _Probe(notif: PermState.denied, loc: PermState.denied),
      rules: rules,
    );
    expect(find.byKey(const ValueKey('permission-block-locationOff')), findsOneWidget);
    expect(find.byKey(const ValueKey('permission-block-notificationsOff')), findsNothing);
  });

  for (final dark in [false, true]) {
    testWidgets("the admin's card shows each rule by audience (${dark ? 'dark' : 'light'})", (tester) async {
      const rules = PermissionRules(user: PermissionChecks(notifications: false), showPermissionsCard: false);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [permissionRulesProvider.overrideWith((_) async => rules)],
          child: MaterialApp(
            theme: dark ? ThemeData.dark() : ThemeData.light(),
            home: const Scaffold(body: SingleChildScrollView(child: PermissionRulesCard(canEdit: true))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      bool on(String key) => tester.widget<SwitchListTile>(find.byKey(ValueKey('permission-rule-$key'))).value;
      expect(on('user-location-service'), isTrue);
      expect(on('user-notifications'), isFalse);
      expect(on('partner-location-always'), isTrue);
      expect(on('partner-notifications'), isTrue);
      expect(on('show-card'), isFalse);
      expect(find.textContaining('\nBypassed'), findsOneWidget);
      expect(find.text('Hidden'), findsOneWidget);
    });
  }

  testWidgets('without edit access the switches are read-only', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [permissionRulesProvider.overrideWith((_) async => PermissionRules.defaults)],
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: PermissionRulesCard(canEdit: false))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byKey(const ValueKey('permission-rule-user-location'))).onChanged,
      isNull,
    );
  });
}
