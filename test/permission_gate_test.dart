// The page that holds a rider before the home map until what Admin → App
// Settings → Permissions enforces is done (features/shell/permission_gate.dart),
// and the admin's card for those rules.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/permission_rules_card.dart';
import 'package:get_ride/src/core/app_permissions.dart';
import 'package:get_ride/src/core/permission_ask.dart';
import 'package:get_ride/src/data/permission_probe.dart';
import 'package:get_ride/src/data/permission_rules.dart';
import 'package:get_ride/src/features/permissions/permission_actions.dart';
import 'package:get_ride/src/features/shell/permission_gate.dart';
import 'package:get_ride/src/providers.dart';

class _Probe implements PermissionProbe {
  _Probe({this.service = true, this.loc = PermState.granted, this.notif = PermState.granted, this.locAsk, this.notifAsk});
  bool service;
  PermState loc;
  PermState notif;

  /// What the next ask answers (null: allowed).
  AskResult? locAsk, notifAsk;
  final requested = <AppPermission>[];
  final asked = <AskKind>[];
  var locationSettings = 0, appSettings = 0, notificationSettings = 0;

  @override
  Future<AskResult> ask(AskKind kind) async {
    asked.add(kind);
    if (kind == AskKind.notifications) requested.add(AppPermission.notifications);
    final r = (kind == AskKind.location ? locAsk : notifAsk) ?? const AskResult(AskAnswer.granted);
    if (r.answer == AskAnswer.granted) {
      if (kind == AskKind.location) loc = PermState.granted;
      if (kind == AskKind.notifications) notif = PermState.granted;
    }
    return r;
  }

  @override
  Future<bool> openNotificationSettings() async {
    notificationSettings++;
    return true;
  }

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
  Future<PermState> requestLocationAlways() async => loc;
  @override
  Future<void> request(AppPermission p) async {
    requested.add(p);
    if (p == AppPermission.notifications) notif = PermState.granted;
  }

  @override
  Future<bool> openAppSettings() async {
    appSettings++;
    return true;
  }
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
      // Android's "All the time" is off unless the admin turns it on.
      expect(on('partner-location-always-android'), isFalse);
      expect(on('partner-notifications'), isTrue);
      expect(on('show-card'), isFalse);
      expect(find.textContaining('\nBypassed'), findsNWidgets(2));
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

  group('asking again', () {
    const canAsk = AskResult(AskAnswer.denied);
    const won = AskResult(AskAnswer.blocked, prompted: false);

    Future<void> resume(WidgetTester tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
    }

    for (final dark in [false, true]) {
      final theme = dark ? ThemeData.dark() : ThemeData.light();
      final mode = dark ? 'dark' : 'light';

      for (final kind in AskKind.values) {
        final location = kind == AskKind.location;
        final block = location ? 'locationNotAsked' : 'notificationsNotAsked';
        _Probe probe0({AskResult? ask}) => location
            ? _Probe(loc: PermState.notAsked, locAsk: ask)
            : _Probe(notif: PermState.notAsked, notifAsk: ask);

        testWidgets('${kind.name}: refused but askable, tapping asks again ($mode)', (tester) async {
          final probe = probe0(ask: canAsk);
          await pump(tester, probe, theme: theme);
          await tester.tap(find.byKey(ValueKey('permission-fix-$block')));
          await tester.pumpAndSettle();
          expect(probe.asked, [kind]);
          // The phone asked; no explanation over it.
          expect(find.byKey(const ValueKey('permission-settings')), findsNothing);
          // Asked once more, allowed this time: through to the map.
          if (location) {
            probe.locAsk = null;
          } else {
            probe.notifAsk = null;
          }
          await tester.tap(find.byKey(ValueKey('permission-fix-$block')));
          await tester.pumpAndSettle();
          expect(probe.asked, [kind, kind]);
          expect(find.byKey(const ValueKey('permissions-required')), findsNothing);
          expect(find.text('Home map'), findsOneWidget);
        });

        testWidgets('${kind.name}: refused for good, explained, Settings, back allowed ($mode)', (tester) async {
          final probe = probe0(ask: won);
          await pump(tester, probe, theme: theme);
          await tester.tap(find.byKey(ValueKey('permission-fix-$block')));
          await tester.pumpAndSettle();
          expect(probe.asked, [kind]);
          expect(find.byKey(const ValueKey('permission-settings')), findsOneWidget);
          expect(
            find.text(location ? 'Location is turned off for GET.ride' : 'Notifications are turned off for GET.ride'),
            findsOneWidget,
          );
          expect(find.textContaining('Open Settings >'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('permission-settings-open')));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('permission-settings')), findsNothing);
          if (location) {
            expect(probe.appSettings, 1);
            expect(probe.notificationSettings, 0);
          } else {
            expect(probe.notificationSettings, 1);
            expect(probe.appSettings, 0);
          }
          // Still held until it is switched on there.
          await resume(tester);
          expect(find.byKey(const ValueKey('permissions-required')), findsOneWidget);
          // Allowed in Settings: back in the app, through without "Check again".
          if (location) {
            probe.loc = PermState.limited;
          } else {
            probe.notif = PermState.granted;
          }
          await resume(tester);
          expect(find.byKey(const ValueKey('permissions-required')), findsNothing);
          expect(find.text('Home map'), findsOneWidget);
        });

        testWidgets('${kind.name}: known refused, the button says Open settings with a hint ($mode)', (tester) async {
          final probe = location
              ? _Probe(loc: PermState.denied, locAsk: won)
              : _Probe(notif: PermState.denied, notifAsk: won);
          final off = location ? 'locationOff' : 'notificationsOff';
          await pump(tester, probe, theme: theme);
          expect(
            find.descendant(of: find.byKey(ValueKey('permission-fix-$off')), matching: find.text('Open settings')),
            findsOneWidget,
          );
          expect(find.byKey(ValueKey('permission-hint-$off')), findsOneWidget);
          await tester.tap(find.byKey(ValueKey('permission-fix-$off')));
          await tester.pumpAndSettle();
          // Asked first all the same, then straight to Settings.
          expect(probe.asked, [kind]);
          expect(find.byKey(const ValueKey('permission-settings')), findsNothing);
          expect(location ? probe.appSettings : probe.notificationSettings, 1);
        });
      }

      testWidgets('Not now leaves the explanation without opening Settings ($mode)', (tester) async {
        final probe = _Probe(loc: PermState.notAsked, locAsk: won);
        await pump(tester, probe, theme: theme);
        await tester.tap(find.byKey(const ValueKey('permission-fix-locationNotAsked')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('permission-settings-cancel')));
        await tester.pumpAndSettle();
        expect(probe.appSettings, 0);
        expect(find.byKey(const ValueKey('permissions-required')), findsOneWidget);
      });
    }

    Future<PermissionFix?> askFrom(WidgetTester tester, _Probe probe, AskKind kind, {bool web = false}) async {
      PermissionFix? fix;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => fix = await askPermission(context, probe, kind, web: web),
              child: const Text('Locate'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Locate'));
      await tester.pumpAndSettle();
      return fix;
    }

    testWidgets("the phone's Location switched off: says so, opens its Location settings", (tester) async {
      final probe = _Probe(locAsk: const AskResult(AskAnswer.serviceOff, prompted: false));
      await askFrom(tester, probe, AskKind.location);
      expect(find.text('Location is off on this phone'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('permission-settings-open')));
      await tester.pumpAndSettle();
      expect(probe.locationSettings, 1);
      expect(probe.appSettings, 0);
    });

    testWidgets('refused just now in the phone\'s own question: no explanation on top', (tester) async {
      final probe = _Probe(locAsk: const AskResult(AskAnswer.blocked));
      expect(await askFrom(tester, probe, AskKind.location), PermissionFix.asked);
      expect(find.byKey(const ValueKey('permission-settings')), findsNothing);
    });

    testWidgets('the browser: where to allow it, no Settings button', (tester) async {
      final probe = _Probe(locAsk: won);
      await askFrom(tester, probe, AskKind.location, web: true);
      expect(find.byKey(const ValueKey('permission-settings')), findsOneWidget);
      expect(find.textContaining('lock icon'), findsOneWidget);
      expect(find.byKey(const ValueKey('permission-settings-open')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('permission-settings-ok')));
      await tester.pumpAndSettle();
      expect(probe.appSettings, 0);
    });

    test('a refusal answered at once is the phone\'s: refused for good', () {
      expect(refusal(forever: false, took: const Duration(milliseconds: 40)).answer, AskAnswer.blocked);
      expect(refusal(forever: false, took: const Duration(seconds: 2)).answer, AskAnswer.denied);
      expect(refusal(forever: true, took: const Duration(seconds: 2)), const AskResult(AskAnswer.blocked));
      expect(askBlockedMessage(AskKind.location), contains('Permissions > Location'));
      expect(askBlockedMessage(AskKind.notifications, ios: true), contains('Allow Notifications'));
      expect(askBlockedMessage(AskKind.location, web: true), contains('lock icon'));
    });
  });
}
