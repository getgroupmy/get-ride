// Settings → Permissions and the driver's location check before going
// online (core/app_permissions.dart, permissions_card.dart,
// online_gate.dart).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/app_permissions.dart';
import 'package:get_ride/src/core/permission_ask.dart';
import 'package:get_ride/src/data/permission_probe.dart';
import 'package:get_ride/src/data/permission_rules.dart';
import 'package:get_ride/src/features/partner/online_gate.dart';
import 'package:get_ride/src/features/permissions/permission_actions.dart';
import 'package:get_ride/src/features/settings/permissions_card.dart';

class FakeProbe implements PermissionProbe {
  FakeProbe({
    this.service = true,
    this.loc = PermState.limited,
    this.afterAsk,
    this.notif = PermState.granted,
    this.notifAfterAsk,
    this.statusMap = const {},
    this.afterAlwaysAsk,
    this.precise,
    this.preciseAsk,
  });
  bool service;
  PermState loc;
  PermState? afterAsk;
  PermState notif;
  PermState? notifAfterAsk;
  Map<AppPermission, PermState> statusMap;
  final requested = <AppPermission>[];
  var settingsOpened = 0, locationSettingsOpened = 0;

  @override
  Future<Map<AppPermission, PermState>> statuses() async => statusMap;
  @override
  Future<(bool, PermState)> location() async => (service, loc);
  @override
  Future<PermState> requestLocation() async {
    loc = afterAsk ?? loc;
    return loc;
  }

  /// What "Allow all the time" leaves location at (Android).
  PermState? afterAlwaysAsk;
  var alwaysAsked = 0;

  @override
  Future<PermState> requestLocationAlways() async {
    alwaysAsked++;
    loc = afterAlwaysAsk ?? loc;
    return loc;
  }

  /// Whether the location allowed is the precise one (null: can't say), and
  /// what asking for it answers (null: precise from then on).
  bool? precise;
  AskResult? preciseAsk;
  var preciseChecked = 0, preciseAsked = 0;

  @override
  Future<bool?> locationPrecise() async {
    preciseChecked++;
    return precise;
  }

  @override
  Future<AskResult> askLocationPrecise() async {
    preciseAsked++;
    final r = preciseAsk ?? const AskResult(AskAnswer.granted);
    if (r.answer == AskAnswer.granted) precise = true;
    return r;
  }

  @override
  Future<PermState> notifications() async => notif;
  @override
  Future<void> request(AppPermission p) async {
    requested.add(p);
    if (p == AppPermission.notifications) notif = notifAfterAsk ?? notif;
  }

  @override
  Future<bool> openAppSettings() async {
    settingsOpened++;
    return false;
  }

  @override
  Future<bool> openLocationSettings() async {
    locationSettingsOpened++;
    return false;
  }

  @override
  Future<bool> openNotificationSettings() async {
    settingsOpened++;
    return false;
  }

  /// A refusal here is the phone's own: no question shown.
  @override
  Future<AskResult> ask(AskKind kind) async {
    if (kind == AskKind.notifications) await request(AppPermission.notifications);
    if (kind == AskKind.location) {
      if (!service) return const AskResult(AskAnswer.serviceOff, prompted: false);
      await requestLocation();
    }
    return switch (kind == AskKind.location ? loc : notif) {
      PermState.granted || PermState.limited => const AskResult(AskAnswer.granted),
      PermState.notAsked => const AskResult(AskAnswer.denied),
      PermState.denied => const AskResult(AskAnswer.blocked, prompted: false),
      PermState.unknown => const AskResult(AskAnswer.unsupported, prompted: false),
    };
  }
}

void main() {
  group('rules', () {
    test('every platform lists what it uses', () {
      expect(permissionsFor(TargetPlatform.android), contains(AppPermission.fullScreenCalls));
      expect(permissionsFor(TargetPlatform.iOS), isNot(contains(AppPermission.fullScreenCalls)));
      expect(permissionsFor(TargetPlatform.iOS).first, AppPermission.notifications);
      expect(permissionsFor(TargetPlatform.android, web: true), [AppPermission.location]);
    });

    test('native answers read as states', () {
      expect(permStateOf('always'), PermState.granted);
      expect(permStateOf('whileInUse'), PermState.limited);
      expect(permStateOf('undetermined'), PermState.notAsked);
      expect(permStateOf('denied'), PermState.denied);
      expect(permStateOf(null), PermState.unknown);
      expect(permStateLabel(AppPermission.location, PermState.granted), 'Always');
      expect(permStateLabel(AppPermission.camera, PermState.granted), 'Allowed');
      expect(permStateLabel(AppPermission.location, PermState.limited), 'While using the app');
    });

    test('what holds someone up, by the rules', () {
      const partner = PermissionChecks(locationAlways: true);
      List<PermissionBlock> blocks(
        PermState s, {
        PermissionChecks checks = partner,
        PermState n = PermState.granted,
        bool on = true,
        TargetPlatform p = TargetPlatform.iOS,
        bool web = false,
      }) => permissionBlocks(checks: checks, serviceOn: on, location: s, notifications: n, platform: p, web: web);
      expect(blocks(PermState.granted), isEmpty);
      expect(blocks(PermState.limited), [PermissionBlock.notAlways]);
      expect(blocks(PermState.granted, on: false), [PermissionBlock.serviceOff]);
      expect(blocks(PermState.notAsked), [PermissionBlock.locationNotAsked]);
      expect(blocks(PermState.denied), [PermissionBlock.locationOff]);
      expect(blocks(PermState.unknown), isEmpty);
      // Everything outstanding, location first.
      expect(blocks(PermState.limited, n: PermState.denied, on: false), [
        PermissionBlock.serviceOff,
        PermissionBlock.notAlways,
        PermissionBlock.notificationsOff,
      ]);
      expect(blocks(PermState.granted, n: PermState.notAsked), [PermissionBlock.notificationsNotAsked]);
      expect(blocks(PermState.granted, n: PermState.unknown), isEmpty);
      // Android's foreground service keeps an online driver's location.
      expect(blocks(PermState.limited, p: TargetPlatform.android), isEmpty);
      // Unless the admin holds Android partners to "All the time" too, which
      // asks nothing more of an iPhone.
      final allTheTime = partner.copyWith(locationAlwaysAndroid: true);
      expect(blocks(PermState.limited, checks: allTheTime, p: TargetPlatform.android), [
        PermissionBlock.notAllTheTime,
      ]);
      expect(blocks(PermState.granted, checks: allTheTime, p: TargetPlatform.android), isEmpty);
      expect(blocks(PermState.limited, checks: allTheTime.copyWith(locationAlways: false)), isEmpty);
      expect(PermissionBlock.notAllTheTime.settingsPath, contains('Allow all the time'));
      expect(PermissionBlock.notAllTheTime.message, contains('background'));
      expect(blocks(PermState.denied, web: true), isEmpty);
      // A rider is never asked for Always.
      expect(blocks(PermState.limited, checks: const PermissionChecks()), isEmpty);
      // Bypassed checks hold nobody up.
      const none = PermissionChecks(locationService: false, location: false, notifications: false);
      expect(blocks(PermState.denied, checks: none, on: false, n: PermState.denied), isEmpty);
      expect(none.any, isFalse);
      expect(blocks(PermState.limited, checks: none.copyWith(locationAlways: true)), [PermissionBlock.notAlways]);
      expect(PermissionBlock.notificationsOff.settingsPath, contains('Notifications'));
      expect(PermissionBlock.notAlways.isLocation, isTrue);
      expect(PermissionBlock.notAllTheTime.isLocation, isTrue);
      expect(PermissionBlock.notificationsOff.isLocation, isFalse);
    });

    test('precise location: held to it only with the switch on, and only by a phone that says it is approximate', () {
      const on = PermissionChecks(locationPrecise: true);
      List<PermissionBlock> blocks(
        PermState s,
        bool? precise, {
        PermissionChecks checks = on,
        PermState n = PermState.granted,
        bool service = true,
        TargetPlatform p = TargetPlatform.android,
        bool web = false,
      }) => permissionBlocks(
        checks: checks,
        serviceOn: service,
        location: s,
        notifications: n,
        platform: p,
        precise: precise,
        web: web,
      );
      // Allowed, but only roughly where the phone is.
      expect(blocks(PermState.granted, false), [PermissionBlock.notPrecise]);
      expect(blocks(PermState.limited, false), [PermissionBlock.notPrecise], reason: 'while using the app counts as allowed');
      expect(blocks(PermState.limited, false, p: TargetPlatform.iOS), [PermissionBlock.notPrecise]);
      // Precise, or a phone that can't say which: through.
      expect(blocks(PermState.granted, true), isEmpty);
      expect(blocks(PermState.granted, null), isEmpty);
      // Off unless the admin turns it on.
      expect(const PermissionChecks().locationPrecise, isFalse);
      expect(blocks(PermState.granted, false, checks: const PermissionChecks()), isEmpty);
      // Location not allowed at all is the other check's to say: one thing at a time.
      expect(blocks(PermState.notAsked, false), [PermissionBlock.locationNotAsked]);
      expect(blocks(PermState.denied, false), [PermissionBlock.locationOff]);
      expect(blocks(PermState.unknown, false), isEmpty);
      // With everything else outstanding it comes with the location checks, before notifications.
      expect(blocks(PermState.granted, false, service: false, n: PermState.denied), [
        PermissionBlock.serviceOff,
        PermissionBlock.notPrecise,
        PermissionBlock.notificationsOff,
      ]);
      // A partner held to "Always" as well is told both.
      expect(blocks(PermState.limited, false, checks: on.copyWith(locationAlways: true), p: TargetPlatform.iOS), [
        PermissionBlock.notAlways,
        PermissionBlock.notPrecise,
      ]);
      // It stands on its own: with location itself bypassed it still asks, of someone who has allowed it.
      const alone = PermissionChecks(locationService: false, location: false, notifications: false, locationPrecise: true);
      expect(alone.any, isTrue);
      expect(blocks(PermState.granted, false, checks: alone), [PermissionBlock.notPrecise]);
      expect(blocks(PermState.denied, false, checks: alone), isEmpty);
      // Nothing is asked of the web.
      expect(blocks(PermState.granted, false, web: true), isEmpty);
      // A passenger is held to it like anyone: it is not "Always".
      expect(riderChecks(on).locationPrecise, isTrue);

      expect(PermissionBlock.notPrecise.isLocation, isTrue);
      expect(PermissionBlock.notificationsNotAsked.isLocation, isFalse);
      expect(PermissionBlock.notPrecise.needsSettings, isFalse, reason: 'Android can ask');
      expect(PermissionBlock.notPrecise.message, contains('approximate'));
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(PermissionBlock.notPrecise.settingsPath, 'Settings > GET.ride > Location > Precise Location');
      expect(permissionBlockAction(PermissionBlock.notPrecise), 'Open settings', reason: 'an iPhone has no question for it');
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(PermissionBlock.notPrecise.settingsPath, contains('Use precise location'));
      expect(permissionBlockAction(PermissionBlock.notPrecise), 'Allow precise location');
      debugDefaultTargetPlatformOverride = null;
      expect(permissionBlockHint(PermissionBlock.notPrecise), isNull);
    });

    test("precise location in the admin's rules: off for both until switched on, one switch each", () {
      expect(PermissionRules.fromJson(null).user.locationPrecise, isFalse);
      expect(PermissionRules.fromJson(null).partner.locationPrecise, isFalse);
      expect(PermissionRules.fromJson(const {'user': {}, 'partner': {}}).partner.locationPrecise, isFalse);
      final r = PermissionRules.fromJson({
        'user': {'locationPrecise': true},
        'partner': {'locationPrecise': 'off'},
      });
      expect(r.user.locationPrecise, isTrue);
      expect(r.partner.locationPrecise, isFalse);
      expect(r.user.location, isTrue, reason: 'the others as they were');
      // Sent back for both, beside the others.
      expect(r.toJson()['user'], containsPair('locationPrecise', true));
      expect(r.toJson()['partner'], containsPair('locationPrecise', false));
      expect(PermissionRules.fromJson(r.toJson()).toJson(), r.toJson());
      expect(PermissionRules.defaults.toJson()['user'], containsPair('locationPrecise', false));
      // An older server sends no such key: off.
      expect(
        PermissionRules.fromJson({
          'user': {'locationService': true, 'location': true, 'notifications': true},
        }).user.locationPrecise,
        isFalse,
      );
    });

    test("the admin's rules read as the server sends them, everything enforced otherwise", () {
      expect(PermissionRules.fromJson(null).user.notifications, isTrue);
      expect(PermissionRules.fromJson(null).partner.locationAlways, isTrue);
      expect(PermissionRules.fromJson(null).user.locationAlways, isFalse);
      expect(PermissionRules.fromJson(null).partner.locationAlwaysAndroid, isFalse);
      expect(
        PermissionRules.fromJson({
          'partner': {'locationAlwaysAndroid': true},
        }).partner.locationAlwaysAndroid,
        isTrue,
      );
      expect(PermissionRules.defaults.toJson()['partner'], containsPair('locationAlwaysAndroid', false));
      final r = PermissionRules.fromJson({
        'user': {'notifications': false, 'location': 'off'},
        'partner': {'locationAlways': false},
        'showPermissionsCard': false,
      });
      expect(r.user.notifications, isFalse);
      expect(r.user.location, isFalse);
      expect(r.user.locationService, isTrue);
      expect(r.partner.locationAlways, isFalse);
      expect(r.partner.notifications, isTrue);
      expect(r.showPermissionsCard, isFalse);
      expect(PermissionRules.fromJson(r.toJson()).toJson(), r.toJson());
      expect(r.toJson()['user'], isNot(contains('locationAlways')));
    });
  });

  group('go-online gate', () {
    Future<bool?> run(
      WidgetTester tester,
      FakeProbe probe, {
      bool tapFix = true,
      PermissionRules rules = PermissionRules.defaults,
      TargetPlatform platform = TargetPlatform.iOS,
    }) async {
      bool? result;
      debugDefaultTargetPlatformOverride = platform;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            permissionProbeProvider.overrideWithValue(probe),
            permissionRulesProvider.overrideWith((_) async => rules),
          ],
          child: MaterialApp(
            theme: ThemeData.dark(),
            home: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () async => result = await ensureOnlineReady(context, ref),
                child: const Text('Go online'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Go online'));
      await tester.pumpAndSettle();
      if (find.byKey(const ValueKey('online-block')).evaluate().isNotEmpty) {
        await tester.tap(tapFix ? find.byKey(const ValueKey('online-block-fix')) : find.text('Not now'));
        await tester.pumpAndSettle();
      }
      debugDefaultTargetPlatformOverride = null;
      return result;
    }

    testWidgets('Always already: straight through', (tester) async {
      expect(await run(tester, FakeProbe(loc: PermState.granted)), isTrue);
    });

    testWidgets('While using: asked to change to Always, then online', (tester) async {
      final probe = FakeProbe(afterAsk: PermState.granted);
      expect(await run(tester, probe), isTrue);
      expect(probe.settingsOpened, 0);
    });

    testWidgets('every partner check bypassed by the admin: straight through', (tester) async {
      const off = PermissionChecks(locationService: false, location: false, notifications: false);
      final probe = FakeProbe(service: false, loc: PermState.denied, notif: PermState.denied);
      expect(await run(tester, probe, rules: const PermissionRules(partner: off)), isTrue);
      expect(find.byKey(const ValueKey('online-block')), findsNothing);
    });

    testWidgets('Not now keeps them offline', (tester) async {
      expect(await run(tester, FakeProbe(), tapFix: false), isFalse);
    });

    testWidgets('still While using: Settings, and offline when it does not open', (tester) async {
      final probe = FakeProbe();
      expect(await run(tester, probe), isFalse);
      expect(probe.settingsOpened, 1);
    });

    testWidgets('location switched off: the Location settings', (tester) async {
      final probe = FakeProbe(service: false, loc: PermState.granted);
      expect(await run(tester, probe), isFalse);
      expect(probe.locationSettingsOpened, 1);
    });
    group('Android, with "All the time" switched on', () {
      const rules = PermissionRules(partner: PermissionChecks(locationAlwaysAndroid: true));

      testWidgets('While using: Android asked for all the time, then online', (tester) async {
        final probe = FakeProbe(afterAlwaysAsk: PermState.granted);
        expect(await run(tester, probe, rules: rules, platform: TargetPlatform.android), isTrue);
        expect(probe.alwaysAsked, 1);
        expect(probe.settingsOpened, 0);
      });

      testWidgets('still While using: Settings, and offline meanwhile', (tester) async {
        final probe = FakeProbe();
        expect(await run(tester, probe, rules: rules, platform: TargetPlatform.android), isFalse);
        expect(probe.settingsOpened, 1);
      });

      testWidgets('switched off: While using is enough on Android', (tester) async {
        final probe = FakeProbe();
        expect(await run(tester, probe, platform: TargetPlatform.android), isTrue);
        expect(probe.alwaysAsked, 0);
      });
    });

    group('with "Precise location" switched on', () {
      const rules = PermissionRules(partner: PermissionChecks(locationPrecise: true));

      testWidgets('approximate on Android: the phone asks, precise is allowed, then online', (tester) async {
        final probe = FakeProbe(loc: PermState.granted, precise: false);
        expect(await run(tester, probe, rules: rules, platform: TargetPlatform.android), isTrue);
        expect(probe.preciseAsked, 1);
        expect(probe.settingsOpened, 0);
      });

      testWidgets('what the driver is told, and the button', (tester) async {
        final probe = FakeProbe(loc: PermState.granted, precise: false, preciseAsk: const AskResult(AskAnswer.denied));
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              permissionProbeProvider.overrideWithValue(probe),
              permissionRulesProvider.overrideWith((_) async => rules),
            ],
            child: MaterialApp(
              home: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () => unawaited(ensureOnlineReady(context, ref)),
                  child: const Text('Go online'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Go online'));
        await tester.pumpAndSettle();
        expect(find.text('Precise location'), findsOneWidget);
        expect(find.textContaining('To go online: GET.ride is only allowed your approximate location'), findsOneWidget);
        expect(find.textContaining('Use precise location'), findsOneWidget, reason: 'where it is in Settings');
        expect(find.widgetWithText(FilledButton, 'Allow precise location'), findsOneWidget);
        // Told to keep it approximate in the phone's own question: nothing is
        // opened on top of that answer, and they are still offline, asked again.
        await tester.tap(find.byKey(const ValueKey('online-block-fix')));
        await tester.pumpAndSettle();
        expect(probe.preciseAsked, 1);
        expect(probe.settingsOpened, 0);
        expect(find.byKey(const ValueKey('online-block')), findsOneWidget);
        await tester.tap(find.text('Not now'));
        await tester.pumpAndSettle();
        debugDefaultTargetPlatformOverride = null;
      });

      testWidgets('Android will not ask any more: Settings, and offline meanwhile', (tester) async {
        final probe = FakeProbe(
          loc: PermState.granted,
          precise: false,
          preciseAsk: const AskResult(AskAnswer.blocked, prompted: false),
        );
        expect(await run(tester, probe, rules: rules, platform: TargetPlatform.android), isFalse);
        expect(probe.preciseAsked, 1);
        expect(probe.settingsOpened, 1);
      });

      testWidgets('an iPhone with Precise Location off: its Settings', (tester) async {
        final probe = FakeProbe(
          loc: PermState.granted,
          precise: false,
          preciseAsk: const AskResult(AskAnswer.blocked, prompted: false),
        );
        expect(await run(tester, probe, rules: rules), isFalse);
        expect(probe.settingsOpened, 1);
      });

      testWidgets('precise already, or a phone that cannot say: straight through', (tester) async {
        final precise = FakeProbe(loc: PermState.granted, precise: true);
        expect(await run(tester, precise, rules: rules, platform: TargetPlatform.android), isTrue);
        expect(precise.preciseAsked, 0);
        final unknown = FakeProbe(loc: PermState.granted);
        expect(await run(tester, unknown, rules: rules, platform: TargetPlatform.android), isTrue);
        expect(unknown.preciseAsked, 0);
      });

      testWidgets('switched off, as it is unless the admin turns it on: approximate is not even looked at', (tester) async {
        final probe = FakeProbe(loc: PermState.granted, precise: false);
        expect(await run(tester, probe, platform: TargetPlatform.android), isTrue);
        expect(probe.preciseChecked, 0);
        expect(probe.preciseAsked, 0);
      });
    });

    testWidgets('notifications off: asked, then online once allowed', (tester) async {
      final probe = FakeProbe(loc: PermState.granted, notif: PermState.notAsked, notifAfterAsk: PermState.granted);
      expect(await run(tester, probe), isTrue);
      expect(probe.requested, [AppPermission.notifications]);
    });

    testWidgets('notifications refused: Settings, offline meanwhile', (tester) async {
      final probe = FakeProbe(loc: PermState.granted, notif: PermState.denied);
      expect(await run(tester, probe), isFalse);
      expect(find.text('Turn on notifications'), findsNothing);
      expect(probe.settingsOpened, 1);
    });
  });

  for (final dark in [false, true]) {
    testWidgets('the card lists each permission and its state (${dark ? 'dark' : 'light'})', (tester) async {
      final probe = FakeProbe(
        notif: PermState.denied,
        statusMap: {
          AppPermission.notifications: PermState.denied,
          AppPermission.location: PermState.limited,
          AppPermission.microphone: PermState.notAsked,
          AppPermission.camera: PermState.granted,
        },
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [permissionProbeProvider.overrideWithValue(probe)],
          child: MaterialApp(
            theme: dark ? ThemeData.dark() : ThemeData.light(),
            home: const Scaffold(body: SingleChildScrollView(child: PermissionsCard())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);
      expect(find.text('While using the app'), findsOneWidget);
      expect(find.text('Allowed'), findsOneWidget);
      expect(find.byKey(const ValueKey('permissions-open-settings')), findsOneWidget);
      // Never asked: the phone's question; refused (the phone answers at
      // once, without asking): its Settings.
      await tester.tap(find.byKey(const ValueKey('permission-microphone')));
      await tester.pumpAndSettle();
      expect(probe.requested, [AppPermission.microphone]);
      await tester.tap(find.byKey(const ValueKey('permission-notifications')));
      await tester.pumpAndSettle();
      expect(probe.settingsOpened, 1);
    });
  }
}
