import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getride_gateway/src/app.dart';
import 'package:getride_gateway/src/core.dart';
import 'package:getride_gateway/src/engine.dart';
import 'package:getride_gateway/src/home_screen.dart';
import 'package:getride_gateway/src/permissions.dart';
import 'package:getride_gateway/src/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

void main() {
  late FakeBackend server;
  late FakeSms phone;
  late GatewayEngine engine;
  late GatewaySettings settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await GatewaySettings.load();
    server = FakeBackend();
    phone = FakeSms()
      ..simList = const [
        SimCard(subscriptionId: 1, label: 'Maxis', number: '+60111', slot: 0),
        SimCard(subscriptionId: 2, label: 'Celcom', slot: 1),
      ];
    engine = GatewayEngine(backend: server, platform: phone, config: settings.config, schedule: false);
  });

  Future<FakePermissions> pump(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    bool sms = false,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    final permissions = FakePermissions({GatewayPermission.sms: sms, GatewayPermission.phone: true});
    await tester.pumpWidget(
      MaterialApp(
        theme: gatewayTheme(brightness),
        home: HomeScreen(
          engine: engine,
          settings: settings,
          platform: phone,
          permissions: permissions,
          account: '+60123456789',
          onSignOut: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    return permissions;
  }

  for (final b in Brightness.values) {
    testWidgets('turning the gateway on asks for SMS first, then goes online (${b.name})', (tester) async {
      final permissions = await pump(tester, brightness: b);
      expect(find.text('Offline'), findsOneWidget);
      expect(find.byKey(const ValueKey('permission-sms')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('gateway-switch')));
      await tester.pumpAndSettle();
      expect(permissions.requested, contains(GatewayPermission.sms));
      expect(find.text('Online'), findsOneWidget);
      expect(settings.wantOnline, isTrue);
      expect(server.heartbeats, [settings.deviceId]);
      await engine.stop();
    });
  }

  testWidgets('without the SMS permission the gateway stays off', (tester) async {
    final permissions = await pump(tester);
    permissions.grantOnRequest = false;
    await tester.tap(find.byKey(const ValueKey('gateway-switch')));
    await tester.pumpAndSettle();
    // Android said no: offered the app's settings instead.
    expect(find.text('Open settings'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(engine.running, isFalse);
    expect(settings.wantOnline, isFalse);
  });

  testWidgets('a dual-SIM phone picks the sending SIM, which fills its number', (tester) async {
    await pump(tester, sms: true);
    await tester.tap(find.byKey(const ValueKey('sim-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SIM 1 · Maxis (+60111)').last);
    await tester.pumpAndSettle();
    expect(settings.subscriptionId, 1);
    expect(settings.simNumber, '+60111');
  });

  testWidgets('a gateway left on comes back on when the app opens', (tester) async {
    settings.wantOnline = true;
    await pump(tester, sms: true);
    expect(engine.state, GatewayState.online);
    await engine.stop();
  });

  testWidgets('a refusal is shown on the status card', (tester) async {
    server.failWith = Exception('GATEWAY_NEEDS_ADMIN');
    await pump(tester, sms: true);
    await tester.tap(find.byKey(const ValueKey('gateway-switch')));
    await tester.pumpAndSettle();
    expect(find.text('Offline'), findsOneWidget);
    expect(find.textContaining('not an admin'), findsWidgets);
  });
}
