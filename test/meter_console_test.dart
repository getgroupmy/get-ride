// What the Meter Digital console decides before a hire opens:
// lib/src/core/meter_console.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/meter_console.dart';
import 'package:get_ride/src/core/vehicle_assignment.dart';

AssignableVehicle _car(String id, AssignableStatus status, {String plate = 'WXY 1'}) =>
    AssignableVehicle(vehicle: {'id': id, 'plate': plate}, role: VehicleRole.driver, status: status);

MeterStartGate _gate({
  bool gps = true,
  bool obd = true,
  bool linked = false,
  bool connecting = false,
  bool saved = false,
  bool fix = true,
  String? error,
  String? problem,
}) => evaluateMeterStart(
  gpsAllowed: gps,
  obdAllowed: obd,
  obdLinked: linked,
  obdConnecting: connecting,
  readerSaved: saved,
  hasFix: fix,
  obdError: error,
  locationProblem: problem,
);

void main() {
  group('which car', () {
    test('a car this driver holds binds silently', () {
      final held = _car('v1', AssignableStatus.inUseByYou);
      final r = resolveMeterVehicleLaunch([_car('v0', AssignableStatus.available), held]);
      expect(r.action, MeterVehicleAction.bind);
      expect(r.vehicle, same(held));
    });

    test('nothing held: ask, even with only one car to pick', () {
      expect(resolveMeterVehicleLaunch([_car('v0', AssignableStatus.available)]).action, MeterVehicleAction.ask);
    });

    test('a held car since locked does not bind; the picker says why', () {
      expect(resolveMeterVehicleLaunch([_car('v1', AssignableStatus.contactAdmin)]).action, MeterVehicleAction.ask);
    });

    test('an unreadable fleet is not known, not empty', () {
      expect(resolveMeterVehicleLaunch(null).action, MeterVehicleAction.unknown);
      expect(resolveMeterVehicleLaunch(const []).action, MeterVehicleAction.none);
    });

    test('the bound car wins the plate, then the permit, then the partner', () {
      expect(resolveMeterPlate(bound: 'A 1', permit: 'B 2', partner: 'C 3'), 'A 1');
      expect(resolveMeterPlate(bound: ' ', permit: 'B 2', partner: 'C 3'), 'B 2');
      expect(resolveMeterPlate(permit: '—', partner: 'C 3'), 'C 3');
      expect(resolveMeterPlate(), isNull);
    });
  });

  test('who is driving: permit, then account; never a placeholder', () {
    final d = resolveMeterDriver(
      permitName: '—',
      partnerName: 'Aina',
      profileName: 'Aina Profile',
      permitNumber: 'TX-1',
      profilePhoto: 'https://x/a.png',
      permitPlate: '-',
    );
    expect(d.name, 'Aina');
    expect(d.licence, 'TX-1');
    expect(d.photoUrl, 'https://x/a.png');
    expect(d.permitPlate, isNull);
    expect(resolveMeterDriver(permitName: 'Siti', partnerName: 'Aina').name, 'Siti');
    expect(resolveMeterDriver().name, isNull);
  });

  group('whether START opens a fare', () {
    test('a GPS-only card opens on the first fix, never on a reader', () {
      expect(_gate(obd: false, linked: true, fix: false).waiting, isTrue);
      expect(_gate(obd: false, linked: true, fix: false).opensOn, MeterStartSource.gps);
      expect(_gate(obd: false).canStart, isTrue);
      final off = _gate(obd: false, problem: 'Location is turned off on this device.');
      expect(off.canStart, isFalse);
      expect(off.waiting, isFalse);
      expect(off.title, 'Location is off');
    });

    test('a linked reader opens the hire on the vehicle', () {
      final g = _gate(linked: true, saved: true, fix: false);
      expect(g.canStart, isTrue);
      expect(g.opensOn, MeterStartSource.vehicle);
    });

    test('a card that bills on both, with no reader saved, opens on GPS', () {
      expect(_gate().canStart, isTrue);
      expect(_gate().opensOn, MeterStartSource.gps);
      expect(_gate(fix: false).waiting, isTrue);
    });

    test('a saved reader holds the press while it links, with GPS as the way out', () {
      final linking = _gate(saved: true, connecting: true);
      expect(linking.canStart, isFalse);
      expect(linking.waiting, isTrue);
      expect(linking.gpsFallback, isTrue);
      final down = _gate(saved: true, error: 'timed out');
      expect(down.waiting, isFalse);
      expect(down.message, contains('timed out'));
      expect(_gate(saved: true, fix: false).gpsFallback, isFalse, reason: 'no fix to fall back on');
    });

    test('an OBD-only card has nothing to fall back on', () {
      final g = _gate(gps: false);
      expect(g.canStart, isFalse);
      expect(g.gpsFallback, isFalse);
      expect(g.message, contains('add one in the reader settings'));
      expect(_gate(gps: false, saved: true).message, contains('retry the reader'));
    });
  });
}
