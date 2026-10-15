// Settings → Permissions and the driver's location check before going
// online (core/app_permissions.dart, permissions_card.dart,
// online_gate.dart).
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/app_permissions.dart';
import 'package:get_ride/src/data/permission_probe.dart';
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

    test('going online needs location on, Always on an iPhone, and notifications', () {
      OnlineBlock? block(
        PermState s, {
        PermState n = PermState.granted,
        bool on = true,
        TargetPlatform p = TargetPlatform.iOS,
        bool web = false,
      }) => onlineBlock(serviceOn: on, location: s, notifications: n, platform: p, web: web);
      expect(block(PermState.granted), isNull);
      expect(block(PermState.limited), OnlineBlock.notAlways);
      expect(block(PermState.granted, on: false), OnlineBlock.serviceOff);
      expect(block(PermState.notAsked), OnlineBlock.locationNotAsked);
      expect(block(PermState.denied), OnlineBlock.locationOff);
      expect(block(PermState.unknown), isNull);
      // Location first, then notifications.
      expect(block(PermState.limited, n: PermState.denied), OnlineBlock.notAlways);
      expect(block(PermState.granted, n: PermState.denied), OnlineBlock.notificationsOff);
      expect(block(PermState.granted, n: PermState.notAsked), OnlineBlock.notificationsNotAsked);
      expect(block(PermState.granted, n: PermState.unknown), isNull);
      // Android's foreground service keeps an online driver's location.
      expect(block(PermState.limited, p: TargetPlatform.android), isNull);
      expect(block(PermState.limited, p: TargetPlatform.android, n: PermState.denied), OnlineBlock.notificationsOff);
      expect(block(PermState.denied, web: true), isNull);
      expect(OnlineBlock.notificationsOff.settingsPath, contains('Notifications'));
      expect(OnlineBlock.notAlways.isLocation, isTrue);
      expect(OnlineBlock.notificationsOff.isLocation, isFalse);
    });
  });

  group('go-online gate', () {
    Future<bool?> run(WidgetTester tester, FakeProbe probe, {bool tapFix = true}) async {
      bool? result;
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [permissionProbeProvider.overrideWithValue(probe)],
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
