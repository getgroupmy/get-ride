import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart';
import 'package:latlong2/latlong.dart';

void main() {
  group('boundaries', () {
    test('bboxToRect is NW, NE, SE, SW', () {
      final r = bboxToRect(const BBox(north: 2, south: 1, east: 4, west: 3));
      expect(r, [const LatLng(2, 3), const LatLng(2, 4), const LatLng(1, 4), const LatLng(1, 3)]);
    });

    test('parseBoundary reads the Expo JSON shape and rejects junk', () {
      const raw = '{"coords":[{"latitude":1,"longitude":2},{"latitude":3,"longitude":4},{"latitude":1,"longitude":4}],'
          '"bbox":{"north":3,"south":1,"east":4,"west":2},"source":"osm"}';
      final b = parseBoundary(raw)!;
      expect(b.coords.length, 3);
      expect(b.source, 'osm');
      expect(b.polygons, isNull);
      expect(b.rings.length, 1);
      expect(parseBoundary(''), isNull);
      expect(parseBoundary('not json'), isNull);
      expect(parseBoundary('{"coords":[]}'), isNull);
      expect(parseBoundary(42), isNull);
    });

    test('encode round-trips and uses latitude/longitude keys', () {
      final shape = boundaryFromDraft(const [LatLng(1, 1), LatLng(1, 2), LatLng(2, 2)])!;
      final j = jsonDecode(shape.encode()) as Map<String, dynamic>;
      expect(j.keys, containsAll(['coords', 'polygons', 'bbox', 'source']));
      expect((j['coords'] as List).first, {'latitude': 1.0, 'longitude': 1.0});
      expect(parseBoundary(shape.encode()), shape);
    });

    test('boundaryFromDraft needs 3 points and computes the bbox', () {
      expect(boundaryFromDraft(const [LatLng(0, 0), LatLng(1, 1)]), isNull);
      final s = boundaryFromDraft(const [LatLng(1, 5), LatLng(3, 2), LatLng(-1, 4)])!;
      expect(s.bbox, const BBox(north: 3, south: -1, east: 5, west: 2));
      expect(s.source, 'manual');
      expect(s.polygons!.single.length, 3);
    });

    test('boundaryFromBBoxInput requires all four numbers', () {
      expect(boundaryFromBBoxInput('1', '0', '', '0'), isNull);
      expect(boundaryFromBBoxInput('1', '0', 'x', '0'), isNull);
      final b = boundaryFromBBoxInput('3.2', '2.9', '101.8', '101.5')!;
      expect(b.source, 'bbox');
      expect(b.coords.length, 4);
    });

    test('osmHitToShape handles bbox-only, Polygon and MultiPolygon', () {
      final bboxOnly = osmHitToShape({'boundingbox': ['1', '2', '3', '4']})!;
      expect(bboxOnly.bbox, const BBox(north: 2, south: 1, east: 4, west: 3));
      expect(bboxOnly.coords.length, 4);
      expect(bboxOnly.polygons, isNull);

      final poly = osmHitToShape({
        'boundingbox': ['0', '1', '0', '1'],
        'geojson': {
          'type': 'Polygon',
          'coordinates': [
            [[0, 0], [1, 0], [1, 1], [0, 0]],
          ],
        },
      })!;
      // GeoJSON is [lng, lat].
      expect(poly.coords[1], const LatLng(0, 1));
      expect(poly.polygons!.length, 1);

      final multi = osmHitToShape({
        'boundingbox': ['0', '5', '0', '5'],
        'geojson': {
          'type': 'MultiPolygon',
          'coordinates': [
            [[[0, 0], [1, 0], [0, 1]]],
            [[[2, 2], [3, 2], [3, 3], [2, 3], [2, 2]]],
          ],
        },
      })!;
      expect(multi.polygons!.length, 2);
      expect(multi.coords.length, 5, reason: 'main ring is the largest');
      expect(osmHitToShape({'display_name': 'x'}), isNull);
    });

    test('mergeCandidates drops repeats by osm type/id', () {
      BoundaryCandidate c(String id) => BoundaryCandidate(
            displayName: id,
            osmType: 'relation',
            osmId: id,
            shape: boundaryFromBBoxInput('1', '0', '1', '0')!,
          );
      final merged = mergeCandidates([c('1'), c('2')], [c('2'), c('3')]);
      expect(merged.map((e) => e.osmId), ['1', '2', '3']);
    });

    test('point in polygon', () {
      const square = [LatLng(0, 0), LatLng(0, 10), LatLng(10, 10), LatLng(10, 0)];
      expect(pointInRing(const LatLng(5, 5), square), isTrue);
      expect(pointInRing(const LatLng(11, 5), square), isFalse);
      expect(pointInRing(const LatLng(5, -1), square), isFalse);
      expect(pointInRing(const LatLng(1, 1), const [LatLng(0, 0), LatLng(1, 1)]), isFalse);
      // Concave "C" shape: the notch is outside.
      const c = [LatLng(0, 0), LatLng(0, 10), LatLng(3, 10), LatLng(3, 3), LatLng(7, 3), LatLng(7, 10), LatLng(10, 10), LatLng(10, 0)];
      expect(pointInRing(const LatLng(5, 6), c), isFalse);
      expect(pointInRing(const LatLng(5, 1), c), isTrue);
      final multi = BoundaryShape(
        coords: square,
        polygons: const [square, [LatLng(20, 20), LatLng(20, 30), LatLng(30, 30), LatLng(30, 20)]],
        bbox: const BBox(north: 30, south: 0, east: 30, west: 0),
        source: 'osm',
      );
      expect(boundaryContains(multi, const LatLng(25, 25)), isTrue);
      expect(boundaryContains(multi, const LatLng(15, 15)), isFalse);
    });

    test('boundary value helpers', () {
      final s = boundaryFromBBoxInput('1', '0', '1', '0')!;
      final v = boundaryValues(s, DateTime.utc(2026, 1, 2, 3));
      expect(v['boundarySource'], 'bbox');
      expect(v['boundaryUpdatedAt'], '2026-01-02T03:00:00.000Z');
      expect(withoutBoundary({...v, 'name': 'x'}), {'name': 'x'});
    });
  });

  group('regions', () {
    test('regionLevelOf picks the deepest filled name', () {
      expect(regionLevelOf({'country': 'MY'}), RegionLevel.country);
      expect(regionLevelOf({'country': 'MY', 'state': 'Sel'}), RegionLevel.state);
      expect(regionLevelOf({'country': 'MY', 'state': 'Sel', 'city': ' PJ '}), RegionLevel.city);
      expect(regionLevelOf({'country': 'MY', 'state': 'Sel', 'city': 'PJ', 'suburb': 'SS2'}), RegionLevel.suburb);
    });

    test('regionEntryFromRow rehydrates names and geofence keys', () {
      final e = regionEntryFromRow({
        'id': 'a',
        'country': 'Malaysia',
        'state': 'Selangor',
        'name': 'Petaling Jaya',
        'values': {'timezone': 'Asia/Kuala_Lumpur'},
        'geofence': {'boundary': '{}', 'source': 'osm', 'updatedAt': 't'},
        'position': 3,
      }, RegionLevel.city);
      expect(e.values['city'], 'Petaling Jaya');
      expect(e.values['suburb'], '');
      expect(e.values['boundary'], '{}');
      expect(e.values['boundarySource'], 'osm');
      expect(e.values['boundaryUpdatedAt'], 't');
      expect(e.position, 3);
      expect(e.level, RegionLevel.city);
    });

    test('regionUpsert routes to the level table and promotes the geofence', () {
      expect(regionUpsert('x', {'state': 'S'}), isNull);
      final up = regionUpsert('id1', {
        'country': 'Malaysia',
        'state': 'Selangor',
        'city': '',
        'suburb': '',
        'timezone': 'Asia/Kuala_Lumpur',
        'boundary': '{"a":1}',
        'boundarySource': 'manual',
        'boundaryUpdatedAt': 'now',
      }, position: 2)!;
      expect(up.table, 'states');
      expect(up.onConflict, 'country,name');
      expect(up.row, {
        'id': 'id1',
        'country': 'Malaysia',
        'name': 'Selangor',
        'values': {'timezone': 'Asia/Kuala_Lumpur'},
        'geofence': {'boundary': '{"a":1}', 'source': 'manual', 'updatedAt': 'now'},
        'position': 2,
      });
      final country = regionUpsert('c', {'country': 'Malaysia'})!;
      expect(country.table, 'countries');
      expect(country.onConflict, 'name');
      expect(country.row['geofence'], isNull);
      expect(country.row.containsKey('country'), isFalse);
      final suburb = regionUpsert('s', {'country': 'M', 'state': 'S', 'city': 'C', 'suburb': 'B'})!;
      expect(suburb.table, 'suburbs');
      expect(suburb.onConflict, 'country,state,city,name');
      expect(suburb.row['name'], 'B');
      expect(suburb.row['city'], 'C');
    });

    RegionEntry e(String id, String c, [String s = '', String ci = '', String sb = '', Map<String, dynamic>? extra]) =>
        RegionEntry(id: id, values: {'country': c, 'state': s, 'city': ci, 'suburb': sb, ...?extra});

    test('buildRegionRows drills down and keeps names known only from deeper rows', () {
      final entries = [
        e('1', 'Malaysia', 'Selangor'),
        e('2', 'Malaysia', 'Johor'),
        e('3', 'Singapore'),
        e('4', 'Malaysia', 'Selangor', 'Petaling Jaya', 'SS2', {'lat': 3.1, 'lng': 101.6}),
      ];
      final countries = buildRegionRows(entries);
      expect(countries.map((r) => r.name), ['Malaysia', 'Singapore']);
      expect(countries.first.entry, isNull, reason: 'no country row saved for Malaysia');
      expect(countries.last.entry?.id, '3');

      final states = buildRegionRows(entries, selCountry: 'malaysia');
      expect(states.map((r) => r.name), ['Johor', 'Selangor']);
      expect(states.last.entry?.id, '1');
      expect(states.last.country, 'malaysia');

      final cities = buildRegionRows(entries, selCountry: 'Malaysia', selState: 'Selangor');
      expect(cities.single.name, 'Petaling Jaya');
      expect(cities.single.entry, isNull);

      final suburbs = buildRegionRows(entries, selCountry: 'Malaysia', selState: 'Selangor', selCity: 'Petaling Jaya');
      expect(suburbs.single.entry?.id, '4');
      expect(suburbs.single.query, 'SS2, Petaling Jaya, Selangor, Malaysia');

      expect(buildRegionRows(entries, query: 'sing').single.name, 'Singapore');
    });

    test('validateRegionForm mirrors the Expo messages', () {
      expect(validateRegionForm(RegionLevel.country, country: ' '), 'Please choose or enter a country.');
      expect(validateRegionForm(RegionLevel.country, country: 'MY'), isNull);
      expect(validateRegionForm(RegionLevel.state, country: 'MY'), 'Please enter a state name.');
      expect(validateRegionForm(RegionLevel.city, country: 'MY', state: 'S'), 'State and city names are required.');
      expect(validateRegionForm(RegionLevel.suburb, country: 'MY', state: 'S', city: 'C'),
          'State, city and suburb names are required.');
      expect(validateRegionForm(RegionLevel.suburb, country: 'MY', state: 'S', city: 'C', suburb: 'B'), isNull);
    });

    test('RegionForm.toValues writes country metadata only on country rows', () {
      final country = RegionForm(country: ' Malaysia ', lat: '3.1', lng: 'x', currencyName: 'MYR', timezone: 'Asia/KL',
          services: {'a': true, 'b': false}, biddingEnabled: false);
      final v = country.toValues();
      expect(v['country'], 'Malaysia');
      expect(v['lat'], 3.1);
      expect(v.containsKey('lng'), isFalse);
      expect(v['currencyName'], 'MYR');
      expect(v['timezone'], 'Asia/KL');
      expect(v['services'], '{"a":true}');
      expect(v['biddingEnabled'], false);

      final suburb = RegionForm(country: 'M', state: 'S', city: 'C', suburb: 'B', timezone: 'x').toValues();
      expect(suburb.containsKey('currencyName'), isFalse);
      expect(suburb.containsKey('timezone'), isFalse);
      expect(suburb['services'], '{}');
    });

    test('RegionForm.fromEntry fills country defaults when missing', () {
      final f = RegionForm.fromEntry(e('1', 'Malaysia', '', '', '', {'services': '{"x":true}', 'biddingEnabled': false}));
      expect(f.emergencyNumber, '999');
      expect(f.languageCode, 'ms-MY');
      expect(f.services, {'x': true});
      expect(f.biddingEnabled, isFalse);
      final kept = RegionForm.fromEntry(e('1', 'Malaysia', '', '', '', {'emergencyNumber': '112'}));
      expect(kept.emergencyNumber, '112');
      final state = RegionForm.fromEntry(e('2', 'Malaysia', 'Selangor'));
      expect(state.emergencyNumber, '');
    });

    test('duplicates and boundary values', () {
      final entries = [e('1', 'Malaysia', 'Selangor')];
      expect(findRegionDuplicate(entries, 'malaysia', 'SELANGOR ', '', '')?.id, '1');
      expect(findRegionDuplicate(entries, 'Malaysia', 'Johor', '', ''), isNull);
      final row = buildRegionRows(entries, selCountry: 'Malaysia').single;
      final v = regionBoundaryValues(row, boundaryFromBBoxInput('1', '0', '1', '0')!, DateTime.utc(2026));
      expect(v['state'], 'Selangor');
      expect(v['boundarySource'], 'bbox');
      expect(parseBoundary(v['boundary']), isNotNull);
    });

    test('services map parsing and ordering', () {
      expect(parseServicesMap('{"a":true,"b":false}'), {'a': true, 'b': false});
      expect(parseServicesMap('[1]'), isEmpty);
      expect(parseServicesMap(null), isEmpty);
      final sorted = sortServices([
        (id: 'x', values: {'name': 'X'}),
        (id: 'y', values: {'name': 'Y', 'displayPriority': 2}),
        (id: 'z', values: {'name': 'Z', 'displayPriority': '1'}),
      ]);
      expect(sorted.map((s) => s.id), ['z', 'y', 'x']);
    });

    test('country defaults', () {
      expect(countryDefaults('sg'), (emergencyNumber: '999', languageCode: 'en-SG'));
      expect(countryDefaults('XX'), (emergencyNumber: '', languageCode: 'en-XX'));
      expect(countryDefaultsForName('Atlantis'), isNull);
      expect(countryDefaultsForName('United Arab Emirates')?.languageCode, 'ar-AE');
    });
  });

  group('airports', () {
    test('validation and cleaning', () {
      final f = AirportForm(name: ' KLIA ', code: 'kul', country: 'Malaysia');
      expect(f.validate(), 'Please assign at least one place using the OSM search.');
      expect(AirportForm().validate(), 'Please fill in Airport Name.');
      expect(AirportForm(name: 'a').validate(), 'Please fill in Country.');
      f.placeName = 'KLIA';
      expect(f.validate(), isNull);
      expect(f.toValues()['code'], 'KUL');
      expect(f.toValues()['name'], 'KLIA');
    });

    test('applyPlace fills only empty region fields', () {
      final f = AirportForm(country: 'Malaysia');
      f.applyPlace(const PlaceResult(
          id: 'osm-1', name: 'KLIA', address: 'Sepang', lat: '2.7', lon: '101.7', country: 'MY', state: 'Selangor', city: 'Sepang'));
      expect(f.country, 'Malaysia');
      expect(f.state, 'Selangor');
      expect(f.city, 'Sepang');
      expect(f.placeName, 'KLIA');
      expect(f.lat, '2.7');
    });

    test('editing keeps the stored geofence', () {
      final v = airportSaveValues({'boundary': 'b', 'boundarySource': 'osm', 'name': 'old'},
          AirportForm(name: 'new', country: 'MY', placeName: 'p'));
      expect(v['boundary'], 'b');
      expect(v['name'], 'new');
      expect(airportSaveValues(null, AirportForm(name: 'n')).containsKey('boundary'), isFalse);
    });

    test('filters', () {
      final rows = [
        {'name': 'KLIA', 'code': 'KUL', 'country': 'Malaysia', 'state': 'Selangor', 'city': 'Sepang'},
        {'name': 'Penang', 'code': 'PEN', 'country': 'Malaysia', 'state': 'Penang', 'city': 'Bayan Lepas'},
        {'name': 'Changi', 'code': 'SIN', 'country': 'Singapore', 'state': '', 'city': 'Singapore'},
      ];
      final all = airportFilterOptions(rows);
      expect(all.countries, ['Malaysia', 'Singapore']);
      final my = airportFilterOptions(rows, country: 'Malaysia');
      expect(my.states, ['Penang', 'Selangor']);
      expect(my.cities, ['Bayan Lepas', 'Sepang']);
      expect(airportFilterOptions(rows, country: 'Malaysia', state: 'Penang').cities, ['Bayan Lepas']);
      expect(rows.where((r) => airportMatches(r, query: 'kul')).length, 1);
      expect(rows.where((r) => airportMatches(r, country: 'Malaysia')).length, 2);
      expect(rows.where((r) => airportMatches(r, country: 'Malaysia', city: 'Sepang')).length, 1);
    });
  });

  group('place search', () {
    test('placeFromNominatim picks a primary name and components', () {
      final r = placeFromNominatim({
        'place_id': 9,
        'display_name': 'Kuala Lumpur International Airport, Sepang, Selangor, Malaysia',
        'lat': '2.74',
        'lon': '101.70',
        'type': 'aerodrome',
        'address': {'aeroway': 'KLIA', 'town': 'Sepang', 'state': 'Selangor', 'country': 'Malaysia'},
      }, nameKeys: airportNameKeys);
      expect(r.id, 'osm-9');
      expect(r.name, 'KLIA');
      expect(r.city, 'Sepang');
      expect(r.state, 'Selangor');
      expect(r.country, 'Malaysia');
      final plain = placeFromNominatim({'place_id': 1, 'display_name': 'Mid Valley, KL', 'lat': '3', 'lon': '101'});
      expect(plain.name, 'Mid Valley');
      expect(plain.type, 'place');
    });

    test('dedupePlaces rounds coordinates and drops invalid ones', () {
      PlaceResult p(String id, String lat, String lon) => PlaceResult(id: id, name: id, address: '', lat: lat, lon: lon);
      final out = dedupePlaces([p('a', '3.1416', '101.0'), p('b', '3.1418', '101.0'), p('c', 'x', '1'), p('d', '3.2', '101')],
          digits: 3);
      expect(out.map((e) => e.id), ['a', 'd']);
      expect(dedupePlaces([p('a', '3.14151', '101.0'), p('b', '3.14149', '101.0')], digits: 5).length, 2);
    });

    test('latLngOf parses string coordinates', () {
      expect(latLngOf({'lat': '2.5', 'lon': '101'}), const LatLng(2.5, 101));
      expect(latLngOf({'lat': '', 'lon': '1'}), isNull);
      expect(latLngOf({'lat': 1, 'lng': 2}, lonKey: 'lng'), const LatLng(1, 2));
    });
  });

  group('multi-gate', () {
    test('place form validation and values', () {
      expect(PlaceForm(gates: '2').validate(), 'Please enter a place name.');
      expect(PlaceForm(name: 'KLCC', gates: '0').validate(), 'Number of gates must be at least 1.');
      expect(PlaceForm(name: 'KLCC', gates: 'abc').validate(), 'Number of gates must be at least 1.');
      final f = PlaceForm(name: ' KLCC ', gates: '4x', lat: ' 3.15 ', lon: '101.71', gateRequired: false);
      expect(f.validate(), isNull);
      expect(f.toValues(), {
        'name': 'KLCC',
        'gates': 4,
        'address': '',
        'lat': '3.15',
        'lon': '101.71',
        'gateRequired': false,
        'active': true,
      });
      final fromRow = PlaceForm.fromValues({'name': 'KLCC', 'gates': 4});
      expect(fromRow.gateRequired, isTrue);
      expect(fromRow.active, isTrue);
      expect(fromRow.gates, '4');
      expect(placeIsActive({'active': false}), isFalse);
      expect(PlaceForm.fromResult(const PlaceResult(id: 'i', name: 'n', address: 'a', lat: '1', lon: '2')).gates, '2');
    });

    test('gate mode, surcharges and values', () {
      expect(parseGateMode(null), GateMode.both);
      expect(parseGateMode('drop'), GateMode.drop);
      expect(parseGateMode('weird'), GateMode.both);
      expect(parseSurcharge(''), '');
      expect(parseSurcharge('-1'), '');
      expect(parseSurcharge('abc'), '');
      expect(parseSurcharge(' 2.50 '), '2.5');
      expect(parseSurcharge('3'), '3');

      final g = GateForm(name: ' Gate A ', lat: '2.7', lon: '101', mode: GateMode.pickup, pickupSurcharge: '5', dropSurcharge: '9');
      expect(g.validate(), isNull);
      final v = g.toValues(placeId: 'p1', parentKey: airportAreasKey);
      expect(v, {
        'placeId': 'p1',
        'parentKey': 'airport-areas',
        'name': 'Gate A',
        'lat': '2.7',
        'lon': '101',
        'displayPriority': 1,
        'active': true,
        'mode': 'pickup',
        'pickupSurcharge': '5',
        'dropSurcharge': '',
      });
      expect(GateForm(name: '', lat: '1', lon: '1').validate(), 'Please enter a gate name.');
      expect(GateForm(name: 'a', lat: 'x', lon: '1').validate(), 'Please provide a valid latitude and longitude.');

      expect(gateSurcharge({'mode': 'both', 'pickupSurcharge': '2', 'dropSurcharge': '0'}, pickup: true), 2);
      expect(gateSurcharge({'mode': 'both', 'dropSurcharge': '0'}, pickup: false), isNull);
      expect(gateSurcharge({'mode': 'drop', 'pickupSurcharge': '2'}, pickup: true), isNull);
    });

    test('gate form from stored values and next gate defaults', () {
      final f = GateForm.fromValues({'name': 'G', 'displayPriority': 0, 'active': false, 'mode': 'drop', 'dropSurcharge': '1'});
      expect(f.displayPriority, 1);
      expect(f.active, isFalse);
      expect(f.mode, GateMode.drop);
      expect(f.dropSurcharge, '1');
      expect(f.pickupSurcharge, '');
      expect(GateForm.fromValues({'displayPriority': 3}).displayPriority, 3);
      final n = GateForm.next(2, const LatLng(3, 101.5));
      expect(n.name, 'Gate 3');
      expect(n.displayPriority, 3);
      expect(n.lat, '3');
      expect(n.lon, '101.5');
      expect(placeCenter(null), const LatLng(3.139, 101.6869));
      expect(placeCenter({'lat': '2.5', 'lon': ''}), const LatLng(2.5, 101.6869));
    });

    test('gatesForPlace filters by place and parent, sorted by priority', () {
      final gates = [
        {'id': 'a', 'placeId': 'p', 'displayPriority': 2},
        {'id': 'b', 'placeId': 'p', 'displayPriority': 1},
        {'id': 'c', 'placeId': 'p'},
        {'id': 'd', 'placeId': 'p', 'parentKey': 'airport-areas', 'displayPriority': 1},
        {'id': 'e', 'placeId': 'q', 'displayPriority': 1},
      ];
      final mine = gatesForPlace(gates, (g) => g, 'p', multiGatePlacesKey);
      expect(mine.map((g) => g['id']), ['b', 'a', 'c']);
      expect(gatesForPlace(gates, (g) => g, 'p', airportAreasKey).map((g) => g['id']), ['d']);
    });

    test('reorderGates renumbers only what changed', () {
      final ids = ['a', 'b', 'c'];
      expect(reorderGates(ids, {'a': 1, 'b': 2, 'c': 3}, 'c', -1), {'c': 2, 'b': 3});
      expect(reorderGates(ids, {'a': 1, 'b': 2, 'c': 3}, 'a', -1), isEmpty);
      expect(reorderGates(ids, {'a': 1, 'b': 2, 'c': 3}, 'c', 1), isEmpty);
      expect(reorderGates(ids, {'a': 5, 'b': null, 'c': 3}, 'a', 1), {'b': 1, 'a': 2});
      expect(reorderGates(ids, const {}, 'zz', 1), isEmpty);
    });
  });
}
