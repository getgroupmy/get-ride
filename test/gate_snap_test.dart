import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart';
import 'package:get_ride/src/admin/screens/geo/multi_gate_screens.dart' show placeToolLabels;
import 'package:get_ride/src/core/airport_areas.dart';
import 'package:get_ride/src/core/airport_queue.dart';
import 'package:get_ride/src/core/gate_snap.dart';
import 'package:latlong2/latlong.dart';

String _box(double n, double s, double e, double w) =>
    '{"coords":[{"latitude":$n,"longitude":$w},{"latitude":$n,"longitude":$e},{"latitude":$s,"longitude":$e},'
    '{"latitude":$s,"longitude":$w}],"bbox":{"north":$n,"south":$s,"east":$e,"west":$w}}';

AirportArea _area(String id, String box, {AreaKind kind = AreaKind.place, double? size}) =>
    AirportArea.fromEntry(id, {'name': id, 'boundary': box}, kind: kind, sizeM2: size)!;

AirportDoor _door(String id, String area, double? lat, double? lng, {DoorKind kind = DoorKind.pick, String group = ''}) =>
    AirportDoor(id: id, airportId: area, name: 'Gate $id', kind: kind, lat: lat, lng: lng, group: group);

void main() {
  // A mall 3.10..3.12 / 101.60..101.62 inside a big complex 3.0..3.2 /
  // 101.5..101.7; an airport 2.70..2.80 / 101.70..101.80 overlapping a hotel
  // 2.75..2.85 / 101.75..101.85; a park with a boundary and no gates.
  final mall = _area('mall', _box(3.12, 3.10, 101.62, 101.60), size: 4e6);
  final complex = _area('complex', _box(3.2, 3.0, 101.7, 101.5), size: 5e8);
  final airport = _area('airport', _box(2.80, 2.70, 101.80, 101.70), kind: AreaKind.airport);
  final hotel = _area('hotel', _box(2.85, 2.75, 101.85, 101.75), size: 1e7);
  final park = _area('park', _box(4.1, 4.0, 102.1, 102.0), size: 1e6);
  final areas = [complex, hotel, mall, park, airport];
  final doors = [
    _door('m1', 'mall', 3.101, 101.601),
    _door('m2', 'mall', 3.119, 101.619),
    _door('m3', 'mall', 3.110, 101.610, kind: DoorKind.drop),
    _door('m4', 'mall', null, null),
    _door('c1', 'complex', 3.05, 101.55),
    _door('a1', 'airport', 2.71, 101.71),
    _door('h1', 'hotel', 2.84, 101.84),
  ];

  group('snap to the nearest gate', () {
    test('inside: the nearest pickup gate of the area, straight line', () {
      final snap = snapToGate(areas: areas, doors: doors, p: const LatLng(3.117, 101.617))!;
      expect(snap.area.id, 'mall');
      expect(snap.door.id, 'm2');
      // Only pickup gates; one without a point is listed but never snapped to.
      expect(snap.gates.map((g) => g.id), ['m1', 'm2', 'm4']);
      expect(snapToGate(areas: areas, doors: doors, p: const LatLng(3.102, 101.603))!.door.id, 'm1');
    });

    test('a drop-off snaps among the drop-off gates', () {
      final snap = snapToGate(areas: areas, doors: doors, p: const LatLng(3.101, 101.601), side: AirportSide.drop)!;
      expect(snap.door.id, 'm3');
    });

    test('outside every boundary: no snap, the pin stays', () {
      expect(snapToGate(areas: areas, doors: doors, p: const LatLng(5, 103)), isNull);
    });

    test('overlaps: the smallest place, and an airport before a place', () {
      expect(snapToGate(areas: areas, doors: doors, p: const LatLng(3.11, 101.61))!.area.id, 'mall');
      expect(snapToGate(areas: areas, doors: doors, p: const LatLng(3.15, 101.65))!.door.id, 'c1');
      final both = snapToGate(areas: areas, doors: doors, p: const LatLng(2.78, 101.78))!;
      expect(both.area.id, 'airport');
      expect(both.door.id, 'a1');
      expect(snapToGate(areas: areas, doors: doors, p: const LatLng(2.83, 101.83))!.area.id, 'hotel');
    });

    test('a place with a boundary and no gates: no snap', () {
      expect(gateAreaAt(areas, const LatLng(4.05, 102.05))?.id, 'park');
      expect(snapToGate(areas: areas, doors: doors, p: const LatLng(4.05, 102.05)), isNull);
    });

    test('areas by precedence: airports first, then places smallest up', () {
      expect(areasByPrecedence(areas).map((a) => a.id), ['airport', 'park', 'mall', 'hotel', 'complex']);
    });
  });

  test('gate letters', () {
    expect([for (final i in [0, 1, 25, 26, 27]) gateLetter(i)], ['A', 'B', 'Z', 'AA', 'AB']);
  });

  test('gate groups: one wheel without groups, groups in order with the rest under Other', () {
    final plain = [_door('x', 'a', 1, 1), _door('y', 'a', 1, 1, group: 'T1')];
    expect(gateGroups(plain).single.gates.length, 2);
    final grouped = [
      _door('k1', 'a', 1, 1, group: 'KLIA'),
      _door('k2', 'a', 1, 1, group: 'klia2'),
      _door('k3', 'a', 1, 1, group: 'KLIA'),
      _door('k4', 'a', 1, 1),
    ];
    final g = gateGroups(grouped);
    expect(g.map((x) => x.name), ['KLIA', 'klia2', 'Other']);
    expect(g.first.gates.map((d) => d.id), ['k1', 'k3']);
    expect(gateIndex(g, 'k3'), (0, 1));
    expect(gateIndex(g, 'k2'), (1, 0));
    expect(gateIndex(g, 'nope'), (0, 0));
  });

  group('place settings (0258)', () {
    test('a place starts with every tool off; an old row reads as an airport', () {
      const p = AirportSettings.place('p');
      expect([p.doorsRequired, p.guideOn, p.faresOn, p.placeChargeOn, p.restrictPickups], everyElement(isFalse));
      final old = AirportSettings.fromRow({'airport_id': 'a'});
      expect(old.guideOn && old.faresOn, isTrue);
      final row = AirportSettings.fromRow({'airport_id': 'a', 'guide_on': false, 'fares_on': false});
      expect(row.toRow()['guide_on'], false);
      expect(row.toRow()['fares_on'], false);
    });

    test('the one charge switch sets both ends, one label', () {
      var s = withPlaceCharge(const AirportSettings.place('p'), on: true, label: 'Mall entry fee', pickAmount: 2);
      expect(s.placeChargeOn, isTrue);
      expect(s.pickFee.applied, 2);
      expect(s.dropFee.applied, 0);
      expect(s.dropFee.name, 'Mall entry fee');
      s = withPlaceCharge(s, on: false);
      expect(s.pickFee.on || s.dropFee.on, isFalse);
      expect(s.pickFee.amount, 2);
    });

    test('the place card lists the tools that are on', () {
      final values = {'areaOn': true, 'boundary': _box(1, 0, 1, 0)};
      expect(placeAreaOn(values), isTrue);
      expect(placeAreaOn({'areaOn': true}), isFalse);
      expect(placeAreaOn({...values, 'areaOn': 'false'}), isFalse);
      final s = withPlaceCharge(const AirportSettings.place('p'), on: true, pickAmount: 1)
          .copyWith(pickDoorRequired: true, dropDoorRequired: true, restrictPickups: true);
      expect(placeToolLabels(values, s), ['Boundary', 'Doors required', 'Charge', 'Queue']);
      expect(placeToolLabels({}, s), isEmpty);
    });

    test('a gate keeps its group', () {
      final f = GateForm(name: 'Door 3', lat: '2.7', lon: '101.7', group: ' klia2 ');
      expect(f.toValues(placeId: 'p', parentKey: multiGatePlacesKey)['group'], 'klia2');
      expect(AirportDoor.fromGate('g', {'group': 'klia2'}).group, 'klia2');
      expect(GateForm(name: 'x', lat: '1', lon: '1').toValues(placeId: 'p', parentKey: 'k').containsKey('group'), isFalse);
    });
  });

  test("the driver's queue card says place for a place's queue", () {
    final place = DriverAirportState.fromJson({'state': 'queued', 'kind': 'place', 'airport': 'Mall', 'total': 2});
    expect(place.title, 'In the place queue');
    final offer = DriverAirportState.fromJson({'state': 'offer', 'kind': 'place'});
    expect(offer.title, 'Queue order');
    expect(offer.message, 'Pickup at the place');
    expect(DriverAirportState.fromJson({'state': 'offer'}).title, 'Airport order');
  });
}
