// Place types (migration 0264): the guess from a place's name and
// OpenStreetMap type (the same examples as supabase/tests/place_types_0264.sql,
// so the app and the server guess alike), Other for a missing type, the
// keys, colours and lines the pages show. Pure.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/place_types.dart';

void main() {
  group('guessPlaceType', () {
    const examples = {
      'KLCC': 'shopping_mall',
      'Mid Valley Megamall': 'shopping_mall',
      'Plaza Low Yat': 'shopping_mall',
      'Times Square': 'shopping_mall',
      'Lrtx Plaza': 'shopping_mall',
      'Sunway Pyramid': 'point_of_interest',
      'Pavilion KL': 'point_of_interest',
      '': 'point_of_interest',
      'Supermarket Giant': 'point_of_interest',
      'KLIA Terminal 1': 'airport',
      'klia2': 'airport',
      'Senai International Airport': 'airport',
      'KL Sentral': 'train_station',
      'KTM Rawang': 'train_station',
      'Stesen Keretapi Ipoh': 'train_station',
      'MRT Bukit Bintang': 'subway_station',
      'LRT Station Ampang': 'subway_station',
      'Terminal Bersepadu Selatan': 'bus_station',
      'Bus terminal Larkin': 'bus_station',
      'Hospital Kuala Lumpur': 'hospital',
      'Sunway Medical Centre': 'hospital',
      'Klinik Kesihatan': 'hospital',
      'Hilton Hotel': 'lodging',
      'Genting Resort': 'lodging',
      'Universiti Malaya': 'university',
      "Taylor's College": 'university',
      'Kolej Komuniti': 'university',
      'Menara KL': 'corporate_office',
      'Petronas Tower 3': 'corporate_office',
      'Stadium Bukit Jalil': 'stadium',
      'Axiata Arena': 'stadium',
      'KL Convention Centre': 'convention_center',
      'Terminal Feri Kuah': 'ferry_terminal',
      'Jetty Point': 'ferry_terminal',
      'Masjid Negara': 'mosque',
      'Sri Mahamariamman Temple': 'mosque',
      'Kuil Batu Caves': 'mosque',
      'Pasar Seni': 'market',
      'Central Market': 'market',
      'Jabatan Imigresen Putrajaya': 'local_government_office',
      'Muzium Negara': 'tourist_attraction',
      'Zoo Negara': 'tourist_attraction',
      'KLCC Park': 'park',
      'Taman Tasik Perdana': 'park',
    };
    for (final e in examples.entries) {
      test('"${e.key}" is ${e.value}', () => expect(guessPlaceType(e.key), e.value));
    }

    test("Google's main type first, then OpenStreetMap's, then the name", () {
      expect(guessPlaceType('Somewhere', osmType: 'aerodrome'), 'airport');
      expect(guessPlaceType('Plaza 264', osmType: 'hospital'), 'hospital');
      expect(guessPlaceType('Plaza 264', osmType: 'yes'), 'shopping_mall');
      expect(guessPlaceType(null, osmType: 'BUS_STATION'), 'bus_station');
      expect(guessPlaceType('Plaza 264', osmType: 'hospital', googleType: 'lodging'), 'lodging');
      expect(guessPlaceType('Hotel 264', googleType: 'light_rail_station'), 'subway_station');
      expect(guessPlaceType('Hotel 264', googleType: 'car_wash'), 'lodging', reason: 'no place type: the name');
      expect(guessPlaceType('X', googleType: 'point_of_interest'), 'point_of_interest');
    });

    test('a Google type the admin added as a type of its own is taken', () {
      final types = [...defaultPlaceTypes, const PlaceType(key: 'car_rental', name: 'Car rental')];
      expect(pickPlaceType('Hotel 264', types, googleType: 'car_rental'), 'car_rental');
      expect(pickPlaceType('Hotel 264', defaultPlaceTypes, googleType: 'car_rental'), 'lodging');
    });

    test('whole words where it matters, not inside others', () {
      expect(guessPlaceType('Supermarket Giant'), 'point_of_interest', reason: '"market" starts a word only');
      expect(guessPlaceType('IOI City Mall'), 'shopping_mall');
    });

    test('the guess is a type that is on, else Other', () {
      final types = [for (final t in defaultPlaceTypes) t.key == 'market' ? t.copyWith(active: false) : t];
      expect(pickPlaceType('Pasar Seni', types), 'point_of_interest');
      expect(pickPlaceType('KL Sentral', types), 'train_station');
      expect(pickPlaceType('KL Sentral', const []), 'point_of_interest');
    });

    test('every type the guess names is a starting type', () {
      final keys = {for (final t in defaultPlaceTypes) t.key};
      for (final (key, _) in placeTypeNameRules) {
        expect(keys, contains(key));
      }
      for (final k in googleTypeAliases.values) {
        expect(keys, contains(k));
      }
    });
  });

  group('a place with no type, or one that is gone', () {
    test('shows Other', () {
      expect(placeTypeFor(null, defaultPlaceTypes).key, 'point_of_interest');
      expect(placeTypeFor(null, defaultPlaceTypes).name, 'Other');
      expect(placeTypeFor('', defaultPlaceTypes).key, 'point_of_interest');
      expect(placeTypeFor('spaceport', defaultPlaceTypes).key, 'point_of_interest');
      expect(placeTypeFor('shopping_mall', const []).key, 'point_of_interest', reason: 'even before the types are read');
      expect(placeTypeFor('shopping_mall', const []).iconData, Icons.place);
    });

    test('a switched-off type shows Other', () {
      final types = [for (final t in defaultPlaceTypes) t.key == 'lodging' ? t.copyWith(active: false) : t];
      expect(placeTypeFor('lodging', types).key, 'point_of_interest');
      expect(placeTypeFor('shopping_mall', types).name, 'Mall');
    });

    test("a place's stored type and whether the admin set it", () {
      expect(placeTypeKeyOf({'placeType': ' mall '}), 'mall');
      expect(placeTypeKeyOf({'placeType': ''}), isNull);
      expect(placeTypeKeyOf(null), isNull);
      expect(placeTypeSetOf({'placeTypeSet': true}), isTrue);
      expect(placeTypeSetOf({'placeTypeSet': 'true'}), isTrue);
      expect(placeTypeSetOf({'placeTypeSet': false}), isFalse);
      expect(placeTypeSetOf(const {}), isFalse);
    });

    test('counts per type, a place without one as Other', () {
      expect(
        placeTypeCounts([
          {'placeType': 'shopping_mall'},
          {'placeType': 'shopping_mall'},
          {'placeType': 'train_station'},
          {'name': 'Old place'},
        ]),
        {'shopping_mall': 2, 'train_station': 1, 'point_of_interest': 1},
      );
    });
  });

  test('the starting types have an icon from the set and both colours', () {
    expect(defaultPlaceTypes.map((t) => t.key), [
      'shopping_mall', 'airport', 'train_station', 'subway_station', 'bus_station', 'ferry_terminal', 'hospital',
      'lodging', 'university', 'corporate_office', 'stadium', 'convention_center', 'mosque', 'market',
      'local_government_office', 'tourist_attraction', 'park', 'point_of_interest',
    ]);
    for (final t in defaultPlaceTypes) {
      expect(placeTypeIcons, contains(t.icon), reason: t.key);
      expect(parsePlaceTypeColor(t.color), isNotNull, reason: t.key);
      expect(parsePlaceTypeColor(t.colorDark), isNotNull, reason: t.key);
    }
    expect(placeTypeIcon('no_such_icon'), Icons.place);
  });

  test('colours read and written as #rrggbb', () {
    expect(parsePlaceTypeColor('#C2410C'), const Color(0xFFC2410C));
    expect(parsePlaceTypeColor('c2410c'), const Color(0xFFC2410C));
    expect(parsePlaceTypeColor('red'), isNull);
    expect(parsePlaceTypeColor('#c2410'), isNull);
    expect(placeTypeHex(const Color(0xFFC2410C)), '#c2410c');
  });

  test('the Google type list: Table A names, one each, every icon drawn by the app', () {
    final keys = <String>{};
    for (final g in googlePlaceTypes) {
      expect(keys.add(g.key), isTrue, reason: '${g.key} twice');
      expect(RegExp(r'^[a-z][a-z0-9_]{0,39}$').hasMatch(g.key), isTrue, reason: g.key);
      expect(placeTypeIcons, contains(g.icon), reason: g.key);
      expect(parsePlaceTypeColor(g.color), isNotNull, reason: g.key);
    }
    for (final t in defaultPlaceTypes) {
      expect(keys, contains(t.key), reason: 'a starting type is a Google type');
    }
    expect(googlePlaceType('shopping_mall')?.name, 'Mall');
    expect(googlePlaceType('nope'), isNull);
  });

  test("Google Maps' category colours, and a label that reads on both", () {
    expect(placeTypeFor('shopping_mall', defaultPlaceTypes).color, placeColorShopping);
    expect(placeTypeFor('airport', defaultPlaceTypes).color, placeColorTransport);
    expect(placeTypeFor('hospital', defaultPlaceTypes).color, placeColorHealth);
    expect(placeTypeFor('lodging', defaultPlaceTypes).color, placeColorLodging);
    expect(placeTypeFor('park', defaultPlaceTypes).color, placeColorPark);
    expect(placeTypeFor('tourist_attraction', defaultPlaceTypes).color, placeColorAttraction);
    expect(placeIconColorOf({'iconBackgroundColor': '#4B96F3'}), const Color(0xFF4B96F3));
    expect(placeIconColorOf({'iconBackgroundColor': 'blue'}), isNull);
    double contrast(Color a, Color b) {
      final x = a.computeLuminance(), y = b.computeLuminance();
      return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
    }
    for (final t in defaultPlaceTypes) {
      expect(contrast(t.labelColorFor(Brightness.light), Colors.white), greaterThan(4.5), reason: t.key);
      expect(contrast(t.labelColorFor(Brightness.dark), const Color(0xFF121212)), greaterThan(4.5), reason: t.key);
    }
  });

  test('sorted by order, then name', () {
    final sorted = sortPlaceTypes(const [
      PlaceType(key: 'b', name: 'Beta', sortOrder: 10),
      PlaceType(key: 'z', name: 'Zed', sortOrder: 5),
      PlaceType(key: 'a', name: 'alpha', sortOrder: 10),
    ]);
    expect(sorted.map((t) => t.key), ['z', 'a', 'b']);
  });

  test('the line under a place: type, gates, address', () {
    const mall = PlaceType(key: 'mall', name: 'Mall');
    expect(placeTypeLine(mall, gates: 4, address: 'Jalan Ampang'), 'Mall · 4 gates · Jalan Ampang');
    expect(placeTypeLine(mall, gates: 1), 'Mall · 1 gate');
    expect(placeTypeLine(mall, address: ' '), 'Mall');
  });

  test('a row read and written', () {
    final t = PlaceType.fromRow({
      'key': 'shopping_mall',
      'name': ' Mall ',
      'icon': 'local_mall',
      'color': '#c2410c',
      'color_dark': '#fdba74',
      'sort_order': '10',
      'active': true,
    });
    expect(t.name, 'Mall');
    expect(t.sortOrder, 10);
    expect(t.toRow(), {
      'key': 'shopping_mall',
      'name': 'Mall',
      'icon': 'local_mall',
      'color': '#c2410c',
      'color_dark': '#fdba74',
      'sort_order': 10,
      'active': true,
    });
  });
}
