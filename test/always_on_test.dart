import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/always_on.dart';

void main() {
  test('Flutter locations answer to the admin page names', () {
    expect(alwaysOnRoutesFor('/'), {'index'});
    expect(alwaysOnRoutesFor('/drive'), {'partner-ehailing'});
    expect(alwaysOnRoutesFor('/drive/permit'), {'partner-teksi'});
    expect(alwaysOnRoutesFor('/drive/trip/abc'), {'ride-running'});
    expect(alwaysOnRoutesFor('/ride/abc'), {'ride-tracking', 'ride-confirm'});
    expect(alwaysOnRoutesFor('/meter'), {'meter-digital'});
    expect(alwaysOnRoutesFor('/meter/'), {'meter-digital'});
    expect(alwaysOnRoutesFor('/meter/vehicle'), {'vehicle-information'});
    expect(alwaysOnRoutesFor('/meter/reader'), {'obd2-reader'});
    expect(alwaysOnRoutesFor('/wallet/scan?x=1'), {'wallet-scan'});
    expect(alwaysOnRoutesFor('/wallet/receive'), {'wallet-show-code'});
    expect(alwaysOnRoutesFor('/account/edit'), {'account'});
  });

  test('keepAwakeAt matches the admin set', () {
    const defaults = ['partner-teksi', 'partner-ehailing', 'meter-digital'];
    expect(keepAwakeAt('/meter', defaults), isTrue);
    expect(keepAwakeAt('/drive', defaults), isTrue);
    expect(keepAwakeAt('/drive/permit', defaults), isTrue);
    expect(keepAwakeAt('/', defaults), isFalse);
    expect(keepAwakeAt('/ride/r1', ['/ride-confirm']), isTrue);
    expect(keepAwakeAt('/meter', const []), isFalse, reason: 'an empty set is respected');
  });

  test('the controller holds the lock only on Always ON pages, toggling on change', () async {
    final calls = <bool>[];
    var routes = ['meter-digital', 'partner-teksi'];
    final c = AlwaysOnController(setAwake: (on) async => calls.add(on), loadRoutes: () async => routes);
    await c.reload();
    expect(calls, isEmpty, reason: 'home is not an Always ON page');

    await c.navigated('/meter');
    await c.navigated('/drive/permit');
    expect(calls, [true], reason: 'moving between two Always ON pages keeps the one lock');

    await c.navigated('/account');
    expect(calls, [true, false]);

    await c.navigated('/meter');
    routes = [];
    await c.reload();
    expect(calls, [true, false, true, false], reason: 'the admin turned the page off');

    routes = ['meter-digital'];
    await c.reload();
    await c.dispose();
    expect(calls, [true, false, true, false, true, false], reason: 'released on dispose');
    expect(c.held, isFalse);
  });

  test('a failing wakelock never breaks navigation', () async {
    final c = AlwaysOnController(
      setAwake: (_) async => throw Exception('no plugin'),
      loadRoutes: () async => ['meter-digital'],
    );
    await c.reload();
    await c.navigated('/meter');
    expect(c.held, isTrue);
  });
}
