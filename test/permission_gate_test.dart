// The page that holds a rider before the home map until what Admin → App
// Settings → Permissions enforces is done (features/shell/permission_gate.dart),
// and the admin's card for those rules.

import 'dart:convert';

import 'package:flutter/foundation.dart' show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/permission_rules_card.dart';
import 'package:get_ride/src/core/app_permissions.dart';
import 'package:get_ride/src/core/permission_ask.dart';
import 'package:get_ride/src/data/models.dart' show Partner;
import 'package:get_ride/src/data/permission_probe.dart';
import 'package:get_ride/src/data/permission_rules.dart';
import 'package:get_ride/src/features/permissions/permission_actions.dart';
import 'package:get_ride/src/features/shell/permission_gate.dart';
import 'package:get_ride/src/providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Probe implements PermissionProbe {
  _Probe({
    this.service = true,
    this.loc = PermState.granted,
    this.notif = PermState.granted,
    this.locAsk,
    this.notifAsk,
    this.precise,
    this.preciseAsk,
  });
  bool service;
  PermState loc;
  PermState notif;

  /// Whether the location allowed is the precise one (null: can't say), and
  /// what asking for it answers (null: precise from then on).
  bool? precise;
  AskResult? preciseAsk;
  var preciseAsked = 0;

  @override
  Future<bool?> locationPrecise() async => precise;

  @override
  Future<AskResult> askLocationPrecise() async {
    preciseAsked++;
    final r = preciseAsk ?? const AskResult(AskAnswer.granted);
    if (r.answer == AskAnswer.granted) precise = true;
    return r;
  }

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
    Partner? partner,
    ThemeData? theme,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          permissionProbeProvider.overrideWithValue(probe),
          permissionRulesProvider.overrideWith((_) async => rules),
          currentUserIdProvider.overrideWithValue(user),
          partnerProvider.overrideWith((_) => partner),
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

  group('a partner is held to location "Always" in every mode', () {
    final activePartner = Partner({'id': 'p1', 'partner_types': const ['eHailing']});

    // "Always" is an iPhone setting (Android's "All the time" is off by
    // default), so these run as iOS; reset inside the body as the framework
    // requires.
    Future<void> onIos(Future<void> Function() body) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    testWidgets('on a drive screen (where a rider is never gated), with its own copy', (tester) async {
      await onIos(() async {
        await pump(tester, _Probe(loc: PermState.limited), location: '/drive', partner: activePartner);
        expect(find.byKey(const ValueKey('permissions-required')), findsOneWidget);
        expect(find.byKey(const ValueKey('permission-block-notAlways')), findsOneWidget);
        expect(find.text('Turn on location to continue'), findsOneWidget);
        // A non-partner on the same drive route is not gated.
        await pump(tester, _Probe(loc: PermState.limited), location: '/drive');
        expect(find.byKey(const ValueKey('permissions-required')), findsNothing);
      });
    });

    testWidgets('while riding as a passenger too (where whileInUse is fine for a rider)', (tester) async {
      await onIos(() async {
        await pump(tester, _Probe(loc: PermState.limited), location: '/', partner: activePartner);
        expect(find.byKey(const ValueKey('permission-block-notAlways')), findsOneWidget);
        // The same whileInUse state does not hold a plain rider at home.
        await pump(tester, _Probe(loc: PermState.limited), location: '/');
        expect(find.byKey(const ValueKey('permissions-required')), findsNothing);
      });
    });

    testWidgets('with "Always" granted the partner goes through', (tester) async {
      await onIos(() async {
        await pump(tester, _Probe(loc: PermState.granted), location: '/drive', partner: activePartner);
        expect(find.byKey(const ValueKey('permissions-required')), findsNothing);
        expect(find.text('Home map'), findsOneWidget);
      });
    });

    testWidgets('a stub partner row (no types, no documents) is treated as a rider', (tester) async {
      await onIos(() async {
        await pump(tester, _Probe(loc: PermState.limited), location: '/drive', partner: Partner({'id': 'p1'}));
        expect(find.byKey(const ValueKey('permissions-required')), findsNothing);
      });
    });
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

  group('precise location, when the admin has switched it on', () {
    const rules = PermissionRules(user: PermissionChecks(locationPrecise: true));

    Future<void> on(TargetPlatform platform, Future<void> Function() body) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    for (final dark in [false, true]) {
      testWidgets('Android, approximate only: told why, asked by the phone, and through (${dark ? 'dark' : 'light'})', (
        tester,
      ) async {
        await on(TargetPlatform.android, () async {
          final probe = _Probe(precise: false);
          await pump(tester, probe, rules: rules, theme: dark ? ThemeData.dark() : ThemeData.light());
          expect(find.byKey(const ValueKey('permissions-required')), findsOneWidget);
          expect(find.byKey(const ValueKey('permission-block-notPrecise')), findsOneWidget);
          expect(find.text('Precise location'), findsOneWidget);
          expect(find.textContaining('only allowed your approximate location'), findsOneWidget);
          expect(find.textContaining('Use precise location'), findsOneWidget, reason: 'where it is in Settings');
          expect(find.widgetWithText(FilledButton, 'Allow precise location'), findsOneWidget);
          expect(find.text('Home map'), findsOneWidget, reason: 'under the page');
          await tester.tap(find.byKey(const ValueKey('permission-fix-notPrecise')));
          await tester.pumpAndSettle();
          expect(probe.preciseAsked, 1);
          expect(probe.appSettings, 0, reason: "the phone's own question was enough");
          expect(find.byKey(const ValueKey('permissions-required')), findsNothing);
        });
      });
    }

    testWidgets("Android, told to keep it approximate in the phone's question: still held, and nothing opened on top", (
      tester,
    ) async {
      await on(TargetPlatform.android, () async {
        final probe = _Probe(precise: false, preciseAsk: const AskResult(AskAnswer.denied));
        await pump(tester, probe, rules: rules);
        await tester.tap(find.byKey(const ValueKey('permission-fix-notPrecise')));
        await tester.pumpAndSettle();
        expect(probe.preciseAsked, 1);
        expect(probe.appSettings, 0);
        expect(find.byKey(const ValueKey('permission-block-notPrecise')), findsOneWidget);
      });
    });

    testWidgets('Android will not ask any more: its Settings; back with it precise, through', (tester) async {
      await on(TargetPlatform.android, () async {
        final probe = _Probe(precise: false, preciseAsk: const AskResult(AskAnswer.blocked, prompted: false));
        await pump(tester, probe, rules: rules);
        await tester.tap(find.byKey(const ValueKey('permission-fix-notPrecise')));
        await tester.pumpAndSettle();
        expect(probe.appSettings, 1);
        expect(find.byKey(const ValueKey('permission-block-notPrecise')), findsOneWidget);
        // "Use precise location" switched on there.
        probe.precise = true;
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('permissions-required')), findsNothing);
      });
    });

    testWidgets('an iPhone with Precise Location off: the button opens its Settings', (tester) async {
      await on(TargetPlatform.iOS, () async {
        final probe = _Probe(precise: false, preciseAsk: const AskResult(AskAnswer.blocked, prompted: false));
        await pump(tester, probe, rules: rules);
        expect(find.byKey(const ValueKey('permission-block-notPrecise')), findsOneWidget);
        expect(find.text('Settings > GET.ride > Location > Precise Location'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Open settings'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('permission-fix-notPrecise')));
        await tester.pumpAndSettle();
        expect(probe.appSettings, 1);
      });
    });

    testWidgets('precise already, or a phone that cannot say: nothing in the way', (tester) async {
      await on(TargetPlatform.android, () async {
        await pump(tester, _Probe(precise: true), rules: rules);
        expect(find.byKey(const ValueKey('permissions-required')), findsNothing);
        await pump(tester, _Probe(), rules: rules);
        expect(find.byKey(const ValueKey('permissions-required')), findsNothing);
      });
    });

    testWidgets('location not allowed at all is said first: precise is not asked on top of it', (tester) async {
      await on(TargetPlatform.android, () async {
        await pump(tester, _Probe(loc: PermState.denied, precise: false), rules: rules);
        expect(find.byKey(const ValueKey('permission-block-locationOff')), findsOneWidget);
        expect(find.byKey(const ValueKey('permission-block-notPrecise')), findsNothing);
      });
    });

    testWidgets('a partner is held to the partners\' switch, a rider to the users\'', (tester) async {
      await on(TargetPlatform.android, () async {
        final partner = Partner({'id': 'p1', 'partner_types': const ['eHailing']});
        const partnersOnly = PermissionRules(partner: PermissionChecks(locationPrecise: true));
        await pump(tester, _Probe(precise: false), rules: partnersOnly, location: '/drive', partner: partner);
        expect(find.byKey(const ValueKey('permission-block-notPrecise')), findsOneWidget);
        await pump(tester, _Probe(precise: false), rules: partnersOnly);
        expect(find.byKey(const ValueKey('permissions-required')), findsNothing, reason: 'the users\' switch is off');
        // And the other way about.
        await pump(tester, _Probe(precise: false), rules: rules, location: '/drive', partner: partner);
        expect(find.byKey(const ValueKey('permissions-required')), findsNothing, reason: 'the partners\' switch is off');
      });
    });
  });

  testWidgets('approximate location holds nobody up unless the admin has switched precise location on', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pump(tester, _Probe(precise: false));
    expect(find.byKey(const ValueKey('permissions-required')), findsNothing);
    expect(find.text('Home map'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
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
      // Precise location too: one switch for users, one for partners.
      expect(on('user-location-precise'), isFalse);
      expect(on('partner-location-precise'), isFalse);
      expect(on('show-card'), isFalse);
      expect(find.textContaining('\nBypassed'), findsNWidgets(4));
      expect(find.text('Hidden'), findsOneWidget);
    });
  }

  testWidgets("the admin's card shows each audience its own precise-location switch", (tester) async {
    Future<(bool, bool)> shown(PermissionRules rules) async {
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [permissionRulesProvider.overrideWith((_) async => rules)],
          child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: PermissionRulesCard(canEdit: true))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      bool on(String key) => tester.widget<SwitchListTile>(find.byKey(ValueKey('permission-rule-$key'))).value;
      return (on('user-location-precise'), on('partner-location-precise'));
    }

    expect(await shown(const PermissionRules(user: PermissionChecks(locationPrecise: true))), (true, false));
    expect(await shown(const PermissionRules(partner: PermissionChecks(locationPrecise: true))), (false, true));
    expect(find.textContaining('partners are asked for the precise one before going online'), findsOneWidget);
    expect(find.textContaining('users are asked for the precise one before the home map'), findsOneWidget);
  });

  testWidgets("the admin's card: precise location is switched on for users and for partners separately", (tester) async {
    // A server that keeps what it is sent, as set_permission_rules does.
    final saved = <Map<String, dynamic>>[];
    var rules = const PermissionRules(partner: PermissionChecks(locationAlways: true));
    final db = SupabaseClient(
      'http://localhost',
      'anon',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((r) async {
        expect(r.url.path, endsWith('/rpc/set_permission_rules'));
        final sent = (jsonDecode(r.body) as Map<String, dynamic>)['p_rules'] as Map<String, dynamic>;
        saved.add(sent);
        rules = PermissionRules.fromJson(sent);
        return http.Response(jsonEncode(sent), 200, headers: {'content-type': 'application/json'}, request: r);
      }),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          supabaseProvider.overrideWithValue(db),
          permissionRulesProvider.overrideWith((_) async => rules),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: PermissionRulesCard(canEdit: true))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Precise location'), findsNWidgets(2));
    expect(find.textContaining('up to a few kilometres out'), findsNWidgets(2));

    Future<void> flip(String key) async {
      final tile = find.byKey(ValueKey('permission-rule-$key'));
      await tester.ensureVisible(tile);
      // The switch itself: the tile is taller than the screen is wide.
      await tester.runAsync(() async {
        tester.widget<SwitchListTile>(tile).onChanged!(true);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      if (find.text('OK').evaluate().isNotEmpty) {
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
      }
    }

    await flip('user-location-precise');
    expect(saved.single['user'], containsPair('locationPrecise', true));
    expect(saved.single['partner'], containsPair('locationPrecise', false));
    expect(saved.single['partner'], containsPair('locationAlways', true), reason: 'the others as they were');
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('permission-rule-user-location-precise'))).value, isTrue);
    await flip('partner-location-precise');
    expect(saved.last['partner'], containsPair('locationPrecise', true));
    expect(saved.last['user'], containsPair('locationPrecise', true));
  });

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

  group('gatePermissionChecks (pure)', () {
    const rules = PermissionRules();
    test('signed out: nothing is gated', () {
      expect(
        gatePermissionChecks(signedIn: false, isPartner: true, riderArea: true, rules: rules),
        isNull,
      );
    });
    test('a partner is held to the partner rules on every screen', () {
      for (final riderArea in [true, false]) {
        final checks = gatePermissionChecks(signedIn: true, isPartner: true, riderArea: riderArea, rules: rules);
        expect(checks, isNotNull);
        expect(checks!.locationAlways, isTrue, reason: 'partner keeps "Always" in both modes');
      }
    });
    test('a non-partner is gated only on the rider screens, without "Always"', () {
      final rider = gatePermissionChecks(signedIn: true, isPartner: false, riderArea: true, rules: rules);
      expect(rider, isNotNull);
      expect(rider!.locationAlways, isFalse);
      expect(
        gatePermissionChecks(signedIn: true, isPartner: false, riderArea: false, rules: rules),
        isNull,
        reason: 'a rider off their screens (e.g. a drive route) is not gated',
      );
    });
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
