// Settings → Permissions and the driver's location check before going
// online (core/app_permissions.dart, permissions_card.dart,
// online_gate.dart).
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/app_permissions.dart';
import 'package:get_ride/src/data/permission_probe.dart';
import 'package:get_ride/src/data/permission_rules.dart';
import 'package:get_ride/src/features/partner/online_gate.dart';
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
}

void main() {
  group('rules', () {
    test('every platform lists what it uses', () {
      expect(permissionsFor(TargetPlatform.android), contains(AppPermission.fullScreenCalls));
      expect(permissionsFor(TargetPlatform.iOS), isNot(contains(AppPermission.fullScreenCalls)));
      expect(permissionsFor(TargetPlatform.iOS).first, AppPermission.notifications);
      expect(permissionsFor(TargetPlatform.android, web: true), [AppPermission.notifications, AppPermission.location]);
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
      // Never asked: the phone's question; refused: its Settings.
      await tester.tap(find.byKey(const ValueKey('permission-microphone')));
      await tester.pumpAndSettle();
      expect(probe.requested, [AppPermission.microphone]);
      await tester.tap(find.byKey(const ValueKey('permission-notifications')));
      await tester.pumpAndSettle();
      expect(probe.settingsOpened, 1);
    });
  }
}
