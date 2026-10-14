import 'package:flutter_test/flutter_test.dart';
import 'package:getride_gateway/src/engine.dart';
import 'package:getride_gateway/src/keeper.dart';
import 'package:getride_gateway/src/permissions.dart';
import 'package:getride_gateway/src/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

void main() {
  late FakeBackend server;
  late FakeSms phone;
  late GatewayEngine engine;
  late GatewaySettings settings;
  late FakePermissions permissions;
  var signedIn = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await GatewaySettings.load();
    server = FakeBackend();
    phone = FakeSms();
    permissions = FakePermissions({GatewayPermission.sms: true});
    signedIn = true;
    engine = GatewayEngine(backend: server, platform: phone, config: settings.config, schedule: false);
  });

  GatewayKeeper keeper() => GatewayKeeper(
    engine: engine,
    settings: settings,
    platform: phone,
    permissions: permissions,
    signedIn: () => signedIn,
  );

  test('left on: back online with no screen, and again when the service is restarted', () async {
    settings.wantOnline = true;
    final k = keeper();
    phone.onResume(k.resume);
    await k.resume();
    expect(engine.state, GatewayState.online);
    expect(phone.serviceRunning, isTrue);

    // Stopped by a refusal, then the watchdog restarts the service.
    await engine.stop(reason: 'Signed out elsewhere');
    await phone.resume!();
    expect(engine.running, isTrue);
  });

  test('a second resume while running changes nothing', () async {
    settings.wantOnline = true;
    final k = keeper();
    await k.resume();
    final beats = server.heartbeats;
    await k.resume();
    expect(server.heartbeats, beats);
    expect(engine.state, GatewayState.online);
  });

  for (final (name, setup) in <(String, void Function())>[
    ('turned off', () => settings.wantOnline = false),
    ('signed out', () => signedIn = false),
    ('no SMS permission', () => permissions.state[GatewayPermission.sms] = false),
  ]) {
    test('$name: stays off and takes the service down', () async {
      settings.wantOnline = true;
      setup();
      phone.serviceRunning = true; // started by Android or the watchdog
      await keeper().resume();
      expect(engine.running, isFalse);
      expect(phone.serviceRunning, isFalse);
    });
  }
}
