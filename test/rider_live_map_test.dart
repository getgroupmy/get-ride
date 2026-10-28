// Rider live map (migration 0322): the pure logic the home map draws with,
// the twin of the server's (supabase/tests/rider_live_map_0322.sql).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/rider_live_map.dart';
import 'package:latlong2/latlong.dart';

double _m(LatLng a, LatLng b) => const Distance().as(LengthUnit.Meter, a, b);

void main() {
  group('the hexagon grid', () {
    test('a centre is in its own cell, anywhere', () {
      for (final (q, r) in [(0, 0), (5, -3), (-7, 2), (31722, 1144), (-40000, 9000)]) {
        final c = hexCentre(q, r, 350, 3);
        expect(hexOf(c.latitude, c.longitude, 350, 3), (q: q, r: r));
      }
    });

    test('the same cell and centre as the server', () {
      // rider_live_map_hex_of(3.11801, 101.675, 350, 3) and its centre, from the SQL test's data.
      expect(hexOf(3.11801, 101.6750, 350, 3), (q: 31722, r: 1144));
      final c = hexCentre(31722, 1144, 350, 3);
      expect(c.latitude, closeTo(3.117702, 0.000001));
      expect(c.longitude, closeTo(101.675020, 0.000001));
    });

    test('neighbours are one hexagon across apart and share two corners', () {
      final a = hexCentre(100, 20, 350, 3), b = hexCentre(101, 20, 350, 3), c = hexCentre(100, 21, 350, 3);
      expect(_m(a, b), closeTo(350, 3));
      expect(_m(a, c), closeTo(350, 3));
      final ca = hexCorners(100, 20, 350, 3), cb = hexCorners(101, 20, 350, 3);
      final shared = ca.where((p) => cb.any((x) => _m(p, x) < 0.01)).length;
      expect(shared, 2);
    });

    test('six corners, flat sides 350 m apart, a point inside its own cell only', () {
      final corners = hexCorners(10, -4, 350, 3);
      expect(corners, hasLength(6));
      final centre = hexCentre(10, -4, 350, 3);
      expect(insideRing(centre, corners), isTrue);
      expect(insideRing(hexCentre(11, -4, 350, 3), corners), isFalse);
      // Corner to centre: 350 / sqrt(3).
      for (final p in corners) {
        expect(_m(centre, p), closeTo(202, 2));
      }
    });

    test('a bigger hexagon, a cell holds more', () {
      final p = hexOf(3.12, 101.68, 1000, 3);
      final c = hexCentre(p.q, p.r, 1000, 3);
      expect(_m(c, const LatLng(3.12, 101.68)), lessThan(1000 / 1.7));
    });
  });

  group('busy levels and colours', () {
    test('below the minimum nothing; then 0 to 4', () {
      expect(busyLevel(4, 5), isNull);
      expect(busyLevel(5, 5), 0);
      expect(busyLevel(8, 5), 1);
      expect(busyLevel(14, 5), 2);
      expect(busyLevel(24, 5), 3);
      expect(busyLevel(25, 5), 4);
      expect(busyLevel(1, 0), 0, reason: 'a minimum of at least one');
    });

    test('the scale runs pale yellow to deep red', () {
      expect(rampAt(defaultBusyColours, 0), defaultBusyColours.first);
      expect(rampAt(defaultBusyColours, 1), defaultBusyColours.last);
      expect(levelColour(defaultBusyColours, 4), defaultBusyColours.last);
      expect(rampAt(const [], 0), defaultBusyColours.first, reason: 'a broken scale falls back to the approved one');
    });

    test('colours as #RRGGBB', () {
      expect(hexColour('#FFEDA0'), const Color(0xFFFFEDA0));
      expect(hexColour('red'), isNull);
      expect(colourHex(const Color(0xFF99000D)), '#99000D');
    });

    test('a cell reads without counts, and its words', () {
      final cell = BusyCell.fromJson({
        'q': 1, 'r': 2, 'lat': 3.1, 'lng': 101.6, 'level': 3, 'area': 'Mid Valley', 'fare': 1.4, 'wait': 6, 'next': 'down',
        'tip': {'m': 600, 'dir': 'north', 'fare': 1.1}, 'count': 99,
      })!;
      expect(cell.title, 'Mid Valley area');
      expect(busyLabel(cell.level), 'Very busy');
      expect(cell.fareLine, 'about 1.4x usual');
      expect(cell.waitLine, 'about 6 min');
      expect(cell.nextLine, 'Getting quieter');
      expect(cell.tip!.line, 'Quieter 600 m north: about 1.1x');
      expect(BusyTip(metres: 1500, direction: 'east').line, 'Quieter 1.5 km east');
    });

    test('a tap finds the shown cell under it', () {
      final c = hexCentre(31722, 1144, 350, 3);
      final areas = BusyAreas.fromJson({
        'on': true, 'hexM': 350, 'latRef': 3,
        'cells': [{'q': 31722, 'r': 1144, 'lat': c.latitude, 'lng': c.longitude, 'level': 0}],
      });
      expect(areas.cellAt(c)?.q, 31722);
      expect(areas.cellAt(hexCentre(31723, 1144, 350, 3)), isNull);
      expect(areas.fillOf(areas.cells.first, dark: false).a, closeTo(0.55, 0.01));
    });

    test('updated words', () {
      final now = DateTime(2026, 10, 28, 12);
      expect(updatedAgo(now.subtract(const Duration(seconds: 5)), now), 'updated just now');
      expect(updatedAgo(now.subtract(const Duration(seconds: 40)), now), 'updated 40 s ago');
      expect(updatedAgo(now.subtract(const Duration(seconds: 70)), now), 'updated 1 min ago');
    });
  });

  group('privacy: what reaches the map', () {
    test('a car is a dot and its kind: anything else is dropped', () {
      final car = LiveCar.fromJson({
        'lat': 3.12, 'lng': 101.68, 'kind': 'bike', 'heading': 40,
        'name': 'Siti', 'plate': 'WXY 1234', 'photo': 'x.jpg', 'rating': 4.9, 'id': 'abc',
      })!;
      expect(car.kind, 'bike');
      expect(car.colourIndex, 1);
      expect(LiveCar.fromJson({'lat': 3.1, 'lng': 101.6, 'kind': 'limousine'})!.kind, 'car');
      expect(LiveCar.fromJson({'lat': 3.1}), isNull);
    });

    test('a person reads only what the server sent; no plate field exists', () {
      final p = LivePerson.fromJson({
        'id': 'm1', 'name': 'Aisha', 'status': 'on_trip', 'to': 'KLCC', 'eta': 12, 'lat': 3.1, 'lng': 101.6,
        'driver': 'Siti', 'car': 'Perodua Bezza', 'plate': 'WXY 1234',
        'trail': [[3.1, 101.6], [3.11, 101.61], 'junk'],
      })!;
      expect(p.mapLabel, 'Aisha · on a ride');
      expect(p.tripLine, 'Ride to KLCC');
      expect(p.etaLine, 'ETA 12 min');
      expect(p.trail, hasLength(2));
      expect(p.initial, 'A');
      final lp = LivePeople.fromJson({'on': true, 'people': [{'id': 'a', 'name': 'A', 'lat': 1, 'lng': 2}, {'id': 'b', 'name': 'B'}]});
      expect(lp.onMap.map((x) => x.id), ['a']);
      expect(lp.offMap.map((x) => x.id), ['b']);
    });

    test('a company trip and its chip', () {
      final t = LivePerson.fromJson({'id': 'r', 'name': 'Lim', 'company': 'Acme', 'status': 'on_trip', 'to': 'Jalan Ampang'})!;
      expect(t.mapLabel, 'Lim · to Jalan Ampang');
      expect(const CompanyTripNote(company: true, name: 'Acme', shown: true, who: 'admins').whoLine,
          'Travel admins at Acme can see this trip on their map until drop-off.');
      expect(const CompanyTripNote(company: true, name: 'Acme', shown: true, who: 'staff').whoLine,
          'Everyone at Acme can see this trip on their map until drop-off.');
      expect(const CompanyTripNote(company: true, name: 'Acme').whoLine, contains('Nobody at Acme'));
    });
  });

  group('config and the rider\'s choices', () {
    test('the button only with an overlay to use; cars as the rider and region say', () {
      expect(LiveMapConfig.off.hasOverlays, isFalse);
      final c = LiveMapConfig.fromJson({
        'cars': {'on': true, 'mayHide': true, 'every': 10},
        'busy': {'on': true, 'every': 60},
        'people': {'on': false},
        'team': {'on': true, 'every': 20},
      });
      expect(c.overlays, {LiveOverlay.busy, LiveOverlay.team});
      expect(c.everyFor(LiveOverlay.team), 20);
      expect(c.showCars(riderHides: false), isTrue);
      expect(c.showCars(riderHides: true), isFalse);
      final locked = LiveMapConfig.fromJson({'cars': {'on': true, 'mayHide': false}});
      expect(locked.showCars(riderHides: true), isTrue, reason: 'the admin may not let riders hide them');
      expect(activeOverlays({LiveOverlay.busy, LiveOverlay.people}, c), {LiveOverlay.busy});
    });

    test('overlays kept as text', () {
      expect(encodeOverlays({LiveOverlay.team, LiveOverlay.busy}), 'busy,team');
      expect(decodeOverlays('busy,nothing,team'), {LiveOverlay.busy, LiveOverlay.team});
      expect(decodeOverlays(null), isEmpty);
    });
  });

  group('rules by region', () {
    const def = LiveMapRule(values: {'busy_on': false, 'busy_min': 5, 'busy_hex_m': 350, 'cars_on': false});
    const my = LiveMapRule(id: 'my', country: 'Malaysia', values: {'busy_on': true});
    const kl = LiveMapRule(id: 'kl', country: 'Malaysia', state: 'Kuala Lumpur', city: 'Kuala Lumpur', values: {'busy_min': 3});
    const sg = LiveMapRule(id: 'sg', country: 'Singapore', values: {'cars_on': true});

    test('most specific wins; a region sets only what it sets', () {
      final at = mergedRules([kl, sg, def, my], country: 'malaysia', state: 'Kuala Lumpur', city: 'Kuala Lumpur');
      expect(at['busy_on'], isTrue);
      expect(at['busy_min'], 3);
      expect(at['busy_hex_m'], 350);
      expect(at['cars_on'], isFalse);
      expect(mergedRules([def, my, kl], country: 'Malaysia')['busy_min'], 5);
      expect(mergedRules([def, my, kl, sg], country: 'Thailand'), def.values);
    });

    test('what a region follows from above', () {
      expect(inheritedFor([def, my, kl], kl), {'busy_on': true, 'busy_min': 5, 'busy_hex_m': 350, 'cars_on': false});
      expect(kl.label, 'Kuala Lumpur');
      expect(def.label, 'Default');
      expect(kl.rank, 3);
    });

    test('a row sends every value, null where it follows', () {
      final row = kl.toRow();
      expect(row['busy_min'], 3);
      expect(row.containsKey('busy_on'), isTrue);
      expect(row['busy_on'], isNull);
      expect(ruleKeys.where((k) => k.endsWith('_on')), hasLength(4));
    });

    test('the steppers keep within the server\'s limits', () {
      for (final n in [...carsNumbers, ...busyNumbers, ...peopleNumbers, ...teamNumbers]) {
        expect(n.up(n.max), n.max);
        expect(n.down(n.min), n.min);
      }
      final offset = carsNumbers.firstWhere((n) => n.key == 'cars_offset_m');
      expect((offset.min, offset.max), (0, 1000));
      expect(peopleNumbers.first.show(0), 'None');
      expect(busyNumbers[1].show(5), '5 bookings');
    });
  });
}
