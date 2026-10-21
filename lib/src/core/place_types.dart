// Place types (migration 0264): every Multi-Gate place has a type (Mall,
// Airport, MRT / LRT station, ...) shown next to the place to riders and
// drivers. The keys are Google Places (New) "Table A" type names
// (shopping_mall, train_station, ...), each with a friendly name, a Material
// icon (Google's open-source Apache-2.0 glyphs, the family Google Maps
// draws its categories with: drawn in the app, never Google's marker
// images) and a chip colour after Google Maps' category colours, for light
// and dark. The admin keeps the list (Admin > Place types,
// `public.place_types`), adding types from the Google type list
// ([googlePlaceTypes]). A place keeps its key in `multi_gate.values.placeType`,
// and `placeTypeSet` says whether the admin chose it (false: the guess).
//
// [guessPlaceType] is the server's `place_type_guess` (0264): change both
// together.
import 'package:flutter/material.dart';

/// The fallback type (Google's point_of_interest, "Other"): a place without
/// a type, or with one that is gone or switched off.
const otherPlaceTypeKey = 'point_of_interest';

/// An airport (Airport Areas) is always this type.
const airportPlaceTypeKey = 'airport';

/// The icons the admin picks from, by their Material name (what is stored).
const placeTypeIcons = <String, IconData>{
  'place': Icons.place,
  'location_on': Icons.location_on,
  'local_mall': Icons.local_mall,
  'shopping_bag': Icons.shopping_bag,
  'shopping_cart': Icons.shopping_cart,
  'storefront': Icons.storefront,
  'store': Icons.store,
  'flight': Icons.flight,
  'flight_takeoff': Icons.flight_takeoff,
  'connecting_airports': Icons.connecting_airports,
  'train': Icons.train,
  'subway': Icons.subway,
  'tram': Icons.tram,
  'directions_railway': Icons.directions_railway,
  'directions_bus': Icons.directions_bus,
  'airport_shuttle': Icons.airport_shuttle,
  'local_taxi': Icons.local_taxi,
  'directions_boat': Icons.directions_boat,
  'sailing': Icons.sailing,
  'anchor': Icons.anchor,
  'local_hospital': Icons.local_hospital,
  'medical_services': Icons.medical_services,
  'emergency': Icons.emergency,
  'local_pharmacy': Icons.local_pharmacy,
  'hotel': Icons.hotel,
  'bed': Icons.bed,
  'apartment': Icons.apartment,
  'house': Icons.house,
  'cottage': Icons.cottage,
  'school': Icons.school,
  'menu_book': Icons.menu_book,
  'business': Icons.business,
  'corporate_fare': Icons.corporate_fare,
  'domain': Icons.domain,
  'work': Icons.work,
  'stadium': Icons.stadium,
  'sports_soccer': Icons.sports_soccer,
  'theater_comedy': Icons.theater_comedy,
  'festival': Icons.festival,
  'museum': Icons.museum,
  'attractions': Icons.attractions,
  'mosque': Icons.mosque,
  'church': Icons.church,
  'temple_hindu': Icons.temple_hindu,
  'temple_buddhist': Icons.temple_buddhist,
  'synagogue': Icons.synagogue,
  'account_balance': Icons.account_balance,
  'local_police': Icons.local_police,
  'gavel': Icons.gavel,
  'local_post_office': Icons.local_post_office,
  'restaurant': Icons.restaurant,
  'local_cafe': Icons.local_cafe,
  'fastfood': Icons.fastfood,
  'park': Icons.park,
  'beach_access': Icons.beach_access,
  'pool': Icons.pool,
  'fitness_center': Icons.fitness_center,
  'local_parking': Icons.local_parking,
  'local_gas_station': Icons.local_gas_station,
  'ev_station': Icons.ev_station,
  'factory': Icons.factory,
  'warehouse': Icons.warehouse,
  'castle': Icons.castle,
  'star': Icons.star,
  'groups': Icons.groups,
  'event': Icons.event,
  'local_grocery_store': Icons.local_grocery_store,
  'local_library': Icons.local_library,
  'directions_transit': Icons.directions_transit,
  'car_rental': Icons.car_rental,
  'local_bar': Icons.local_bar,
  'spa': Icons.spa,
  'golf_course': Icons.golf_course,
  'pets': Icons.pets,
};

/// [name]'s icon, the plain pin when it isn't in the set.
IconData placeTypeIcon(String? name) => placeTypeIcons[name] ?? Icons.place;

// ---- Google Maps' category colours ---------------------------------------------------

/// The chip colours, after the category colours Google Maps uses.
const placeColorShopping = '#4b96f3';
const placeColorTransport = '#10bdff';
const placeColorHealth = '#f88181';
const placeColorLodging = '#e94e4e';
const placeColorCivic = '#7b9eb0';
const placeColorPark = '#4db546';
const placeColorAttraction = '#13b5c7';
const placeColorFood = '#ff9e67';

/// A type as the admin keeps it.
@immutable
class PlaceType {
  const PlaceType({
    required this.key,
    required this.name,
    this.icon = 'place',
    this.color = placeColorCivic,
    this.colorDark = placeColorCivic,
    this.sortOrder = 0,
    this.active = true,
  });

  factory PlaceType.fromRow(Map<String, dynamic> r) => PlaceType(
        key: '${r['key'] ?? ''}',
        name: '${r['name'] ?? ''}'.trim(),
        icon: '${r['icon'] ?? 'place'}',
        color: '${r['color'] ?? placeColorCivic}',
        colorDark: '${r['color_dark'] ?? placeColorCivic}',
        sortOrder: r['sort_order'] is num ? (r['sort_order'] as num).toInt() : int.tryParse('${r['sort_order']}') ?? 0,
        active: r['active'] != false,
      );

  /// A Google Places type name ("shopping_mall").
  final String key;
  final String name;

  /// A key of [placeTypeIcons].
  final String icon;

  /// `#RRGGBB`: the icon chip's colour on a light and on a dark screen (the
  /// glyph is white on it).
  final String color;
  final String colorDark;
  final int sortOrder;
  final bool active;

  IconData get iconData => placeTypeIcon(icon);

  /// The chip colour for [b].
  Color colorFor(Brightness b) =>
      parsePlaceTypeColor(b == Brightness.dark ? colorDark : color) ?? const Color(0xFF7B9EB0);

  /// The label's text colour for [b]: the chip colour made dark enough on a
  /// light screen, light enough on a dark one, to read.
  Color labelColorFor(Brightness b) => placeLabelColor(colorFor(b), b);

  /// The faint fill behind the label.
  Color fillFor(Brightness b) => colorFor(b).withValues(alpha: b == Brightness.dark ? 0.24 : 0.16);

  Map<String, dynamic> toRow() => {
        'key': key,
        'name': name.trim(),
        'icon': icon,
        'color': color,
        'color_dark': colorDark,
        'sort_order': sortOrder,
        'active': active,
      };

  PlaceType copyWith({String? name, String? icon, String? color, String? colorDark, int? sortOrder, bool? active}) =>
      PlaceType(
        key: key,
        name: name ?? this.name,
        icon: icon ?? this.icon,
        color: color ?? this.color,
        colorDark: colorDark ?? this.colorDark,
        sortOrder: sortOrder ?? this.sortOrder,
        active: active ?? this.active,
      );

  @override
  bool operator ==(Object other) =>
      other is PlaceType &&
      other.key == key &&
      other.name == name &&
      other.icon == icon &&
      other.color == color &&
      other.colorDark == colorDark &&
      other.sortOrder == sortOrder &&
      other.active == active;

  @override
  int get hashCode => Object.hash(key, name, icon, color, colorDark, sortOrder, active);
}

/// [c] as text that reads on a [b] screen: mixed with black (light) or
/// white (dark).
Color placeLabelColor(Color c, Brightness b) =>
    b == Brightness.dark ? Color.lerp(c, Colors.white, 0.45)! : Color.lerp(c, Colors.black, 0.42)!;

/// The types 0264 starts with: used until the table is read (or when it
/// can't be), so a place always shows something.
const defaultPlaceTypes = <PlaceType>[
  PlaceType(key: 'shopping_mall', name: 'Mall', icon: 'local_mall', color: placeColorShopping, colorDark: placeColorShopping, sortOrder: 10),
  PlaceType(key: 'airport', name: 'Airport', icon: 'flight', color: placeColorTransport, colorDark: placeColorTransport, sortOrder: 20),
  PlaceType(key: 'train_station', name: 'Train station', icon: 'train', color: placeColorTransport, colorDark: placeColorTransport, sortOrder: 30),
  PlaceType(key: 'subway_station', name: 'MRT / LRT station', icon: 'subway', color: placeColorTransport, colorDark: placeColorTransport, sortOrder: 40),
  PlaceType(key: 'bus_station', name: 'Bus terminal', icon: 'directions_bus', color: placeColorTransport, colorDark: placeColorTransport, sortOrder: 50),
  PlaceType(key: 'ferry_terminal', name: 'Ferry terminal', icon: 'directions_boat', color: placeColorTransport, colorDark: placeColorTransport, sortOrder: 60),
  PlaceType(key: 'hospital', name: 'Hospital', icon: 'local_hospital', color: placeColorHealth, colorDark: placeColorHealth, sortOrder: 70),
  PlaceType(key: 'lodging', name: 'Hotel', icon: 'hotel', color: placeColorLodging, colorDark: placeColorLodging, sortOrder: 80),
  PlaceType(key: 'university', name: 'University / School', icon: 'school', color: placeColorCivic, colorDark: placeColorCivic, sortOrder: 90),
  PlaceType(key: 'corporate_office', name: 'Office', icon: 'business', color: placeColorCivic, colorDark: placeColorCivic, sortOrder: 100),
  PlaceType(key: 'stadium', name: 'Stadium', icon: 'stadium', color: placeColorAttraction, colorDark: placeColorAttraction, sortOrder: 110),
  PlaceType(key: 'convention_center', name: 'Convention centre', icon: 'groups', color: placeColorAttraction, colorDark: placeColorAttraction, sortOrder: 120),
  PlaceType(key: 'mosque', name: 'Mosque / Place of worship', icon: 'mosque', color: placeColorCivic, colorDark: placeColorCivic, sortOrder: 130),
  PlaceType(key: 'market', name: 'Market', icon: 'storefront', color: placeColorShopping, colorDark: placeColorShopping, sortOrder: 140),
  PlaceType(key: 'local_government_office', name: 'Government office', icon: 'account_balance', color: placeColorCivic, colorDark: placeColorCivic, sortOrder: 150),
  PlaceType(key: 'tourist_attraction', name: 'Attraction', icon: 'attractions', color: placeColorAttraction, colorDark: placeColorAttraction, sortOrder: 160),
  PlaceType(key: 'park', name: 'Park', icon: 'park', color: placeColorPark, colorDark: placeColorPark, sortOrder: 170),
  PlaceType(key: 'point_of_interest', name: 'Other', icon: 'place', color: placeColorCivic, colorDark: placeColorCivic, sortOrder: 1000),
];

/// Other, as 0264 makes it (used when even Other is missing).
const fallbackOtherPlaceType = PlaceType(key: otherPlaceTypeKey, name: 'Other', sortOrder: 1000);

// ---- The Google type list the admin adds types from ---------------------------------

/// One Google Places (New) "Table A" type: its name, a friendly name, and
/// the icon and colour a new type of it starts with.
typedef GooglePlaceType = ({String key, String name, String icon, String color});

/// Google Places (New) Table A types the admin can add as place types.
const googlePlaceTypes = <GooglePlaceType>[
  // Transport
  (key: 'airport', name: 'Airport', icon: 'flight', color: placeColorTransport),
  (key: 'international_airport', name: 'International airport', icon: 'flight', color: placeColorTransport),
  (key: 'airstrip', name: 'Airstrip', icon: 'flight_takeoff', color: placeColorTransport),
  (key: 'heliport', name: 'Heliport', icon: 'flight_takeoff', color: placeColorTransport),
  (key: 'train_station', name: 'Train station', icon: 'train', color: placeColorTransport),
  (key: 'subway_station', name: 'MRT / LRT station', icon: 'subway', color: placeColorTransport),
  (key: 'light_rail_station', name: 'Light rail station', icon: 'tram', color: placeColorTransport),
  (key: 'transit_station', name: 'Transit station', icon: 'directions_transit', color: placeColorTransport),
  (key: 'transit_depot', name: 'Transit depot', icon: 'directions_transit', color: placeColorTransport),
  (key: 'bus_station', name: 'Bus terminal', icon: 'directions_bus', color: placeColorTransport),
  (key: 'bus_stop', name: 'Bus stop', icon: 'directions_bus', color: placeColorTransport),
  (key: 'ferry_terminal', name: 'Ferry terminal', icon: 'directions_boat', color: placeColorTransport),
  (key: 'taxi_stand', name: 'Taxi stand', icon: 'local_taxi', color: placeColorTransport),
  (key: 'park_and_ride', name: 'Park and ride', icon: 'local_parking', color: placeColorTransport),
  (key: 'parking', name: 'Parking', icon: 'local_parking', color: placeColorTransport),
  (key: 'gas_station', name: 'Petrol station', icon: 'local_gas_station', color: placeColorTransport),
  (key: 'electric_vehicle_charging_station', name: 'EV charging', icon: 'ev_station', color: placeColorTransport),
  (key: 'rest_stop', name: 'Rest stop', icon: 'local_parking', color: placeColorTransport),
  (key: 'car_rental', name: 'Car rental', icon: 'car_rental', color: placeColorTransport),
  // Shopping
  (key: 'shopping_mall', name: 'Mall', icon: 'local_mall', color: placeColorShopping),
  (key: 'department_store', name: 'Department store', icon: 'shopping_bag', color: placeColorShopping),
  (key: 'market', name: 'Market', icon: 'storefront', color: placeColorShopping),
  (key: 'supermarket', name: 'Supermarket', icon: 'local_grocery_store', color: placeColorShopping),
  (key: 'grocery_store', name: 'Grocery store', icon: 'local_grocery_store', color: placeColorShopping),
  (key: 'convenience_store', name: 'Convenience store', icon: 'store', color: placeColorShopping),
  (key: 'store', name: 'Store', icon: 'store', color: placeColorShopping),
  (key: 'wholesaler', name: 'Wholesaler', icon: 'warehouse', color: placeColorShopping),
  // Health
  (key: 'hospital', name: 'Hospital', icon: 'local_hospital', color: placeColorHealth),
  (key: 'medical_lab', name: 'Medical lab', icon: 'medical_services', color: placeColorHealth),
  (key: 'doctor', name: 'Clinic', icon: 'medical_services', color: placeColorHealth),
  (key: 'dental_clinic', name: 'Dental clinic', icon: 'medical_services', color: placeColorHealth),
  (key: 'pharmacy', name: 'Pharmacy', icon: 'local_pharmacy', color: placeColorHealth),
  // Lodging
  (key: 'lodging', name: 'Hotel', icon: 'hotel', color: placeColorLodging),
  (key: 'hotel', name: 'Hotel', icon: 'hotel', color: placeColorLodging),
  (key: 'resort_hotel', name: 'Resort', icon: 'hotel', color: placeColorLodging),
  (key: 'motel', name: 'Motel', icon: 'bed', color: placeColorLodging),
  (key: 'hostel', name: 'Hostel', icon: 'bed', color: placeColorLodging),
  (key: 'guest_house', name: 'Guest house', icon: 'house', color: placeColorLodging),
  (key: 'apartment_building', name: 'Apartments', icon: 'apartment', color: placeColorLodging),
  // Education and work
  (key: 'university', name: 'University / School', icon: 'school', color: placeColorCivic),
  (key: 'school', name: 'School', icon: 'school', color: placeColorCivic),
  (key: 'primary_school', name: 'Primary school', icon: 'school', color: placeColorCivic),
  (key: 'secondary_school', name: 'Secondary school', icon: 'school', color: placeColorCivic),
  (key: 'library', name: 'Library', icon: 'local_library', color: placeColorCivic),
  (key: 'corporate_office', name: 'Office', icon: 'business', color: placeColorCivic),
  (key: 'business_center', name: 'Business centre', icon: 'corporate_fare', color: placeColorCivic),
  // Worship and government
  (key: 'mosque', name: 'Mosque / Place of worship', icon: 'mosque', color: placeColorCivic),
  (key: 'place_of_worship', name: 'Place of worship', icon: 'mosque', color: placeColorCivic),
  (key: 'church', name: 'Church', icon: 'church', color: placeColorCivic),
  (key: 'hindu_temple', name: 'Hindu temple', icon: 'temple_hindu', color: placeColorCivic),
  (key: 'buddhist_temple', name: 'Buddhist temple', icon: 'temple_buddhist', color: placeColorCivic),
  (key: 'synagogue', name: 'Synagogue', icon: 'synagogue', color: placeColorCivic),
  (key: 'local_government_office', name: 'Government office', icon: 'account_balance', color: placeColorCivic),
  (key: 'city_hall', name: 'City hall', icon: 'account_balance', color: placeColorCivic),
  (key: 'courthouse', name: 'Courthouse', icon: 'gavel', color: placeColorCivic),
  (key: 'police', name: 'Police station', icon: 'local_police', color: placeColorCivic),
  (key: 'embassy', name: 'Embassy', icon: 'account_balance', color: placeColorCivic),
  (key: 'post_office', name: 'Post office', icon: 'local_post_office', color: placeColorCivic),
  // Entertainment and recreation
  (key: 'stadium', name: 'Stadium', icon: 'stadium', color: placeColorAttraction),
  (key: 'arena', name: 'Arena', icon: 'stadium', color: placeColorAttraction),
  (key: 'sports_complex', name: 'Sports complex', icon: 'sports_soccer', color: placeColorAttraction),
  (key: 'convention_center', name: 'Convention centre', icon: 'groups', color: placeColorAttraction),
  (key: 'event_venue', name: 'Event venue', icon: 'event', color: placeColorAttraction),
  (key: 'tourist_attraction', name: 'Attraction', icon: 'attractions', color: placeColorAttraction),
  (key: 'amusement_park', name: 'Theme park', icon: 'attractions', color: placeColorAttraction),
  (key: 'museum', name: 'Museum', icon: 'museum', color: placeColorAttraction),
  (key: 'art_gallery', name: 'Art gallery', icon: 'museum', color: placeColorAttraction),
  (key: 'performing_arts_theater', name: 'Theatre', icon: 'theater_comedy', color: placeColorAttraction),
  (key: 'zoo', name: 'Zoo', icon: 'pets', color: placeColorAttraction),
  (key: 'aquarium', name: 'Aquarium', icon: 'attractions', color: placeColorAttraction),
  (key: 'casino', name: 'Casino', icon: 'attractions', color: placeColorAttraction),
  (key: 'night_club', name: 'Night club', icon: 'local_bar', color: placeColorAttraction),
  (key: 'golf_course', name: 'Golf course', icon: 'golf_course', color: placeColorPark),
  (key: 'park', name: 'Park', icon: 'park', color: placeColorPark),
  (key: 'national_park', name: 'National park', icon: 'park', color: placeColorPark),
  (key: 'botanical_garden', name: 'Botanical garden', icon: 'park', color: placeColorPark),
  (key: 'beach', name: 'Beach', icon: 'beach_access', color: placeColorPark),
  (key: 'marina', name: 'Marina', icon: 'sailing', color: placeColorPark),
  // Food
  (key: 'restaurant', name: 'Restaurant', icon: 'restaurant', color: placeColorFood),
  (key: 'food_court', name: 'Food court', icon: 'fastfood', color: placeColorFood),
  (key: 'cafe', name: 'Cafe', icon: 'local_cafe', color: placeColorFood),
  // Other
  (key: 'spa', name: 'Spa', icon: 'spa', color: placeColorAttraction),
  (key: 'gym', name: 'Gym', icon: 'fitness_center', color: placeColorAttraction),
  (key: 'point_of_interest', name: 'Other', icon: 'place', color: placeColorCivic),
];

/// The Google type named [key], or null.
GooglePlaceType? googlePlaceType(String key) => googlePlaceTypes.where((g) => g.key == key).firstOrNull;

/// `#RRGGBB` as a colour; null when it isn't one.
Color? parsePlaceTypeColor(String? s) {
  final h = (s ?? '').trim().replaceFirst('#', '');
  if (!RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(h)) return null;
  return Color(0xFF000000 | int.parse(h, radix: 16));
}

/// [c] as `#rrggbb`.
String placeTypeHex(Color c) {
  String two(double x) => (x * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#${two(c.r)}${two(c.g)}${two(c.b)}';
}

/// The types in the admin's order (sort order, then name).
List<PlaceType> sortPlaceTypes(Iterable<PlaceType> types) => [...types]
  ..sort((a, b) {
    final c = a.sortOrder.compareTo(b.sortOrder);
    return c != 0 ? c : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });

/// The type for [key] among [types]: Other when there is none, it is gone
/// or switched off.
PlaceType placeTypeFor(String? key, List<PlaceType> types) {
  final k = (key ?? '').trim();
  PlaceType? find(String k) => types.where((t) => t.key == k).firstOrNull;
  final hit = k.isEmpty ? null : find(k);
  if (hit != null && hit.active) return hit;
  return find(otherPlaceTypeKey) ??
      defaultPlaceTypes.where((t) => t.key == otherPlaceTypeKey).firstOrNull ??
      fallbackOtherPlaceType;
}

// ---- The guess (0264's place_type_guess) ------------------------------------------------

/// Google Places types that mean one of the starting types (a Google type
/// that is a place type of its own wins over these, see [pickPlaceType]).
const googleTypeAliases = <String, String>{
  'international_airport': 'airport',
  'airstrip': 'airport',
  'light_rail_station': 'subway_station',
  'transit_station': 'train_station',
  'bus_stop': 'bus_station',
  'transit_depot': 'bus_station',
  'department_store': 'shopping_mall',
  'outlet_mall': 'shopping_mall',
  'hotel': 'lodging',
  'resort_hotel': 'lodging',
  'motel': 'lodging',
  'hostel': 'lodging',
  'guest_house': 'lodging',
  'bed_and_breakfast': 'lodging',
  'inn': 'lodging',
  'school': 'university',
  'primary_school': 'university',
  'secondary_school': 'university',
  'doctor': 'hospital',
  'medical_lab': 'hospital',
  'business_center': 'corporate_office',
  'arena': 'stadium',
  'sports_complex': 'stadium',
  'event_venue': 'convention_center',
  'place_of_worship': 'mosque',
  'church': 'mosque',
  'hindu_temple': 'mosque',
  'buddhist_temple': 'mosque',
  'synagogue': 'mosque',
  'city_hall': 'local_government_office',
  'courthouse': 'local_government_office',
  'police': 'local_government_office',
  'embassy': 'local_government_office',
  'post_office': 'local_government_office',
  'museum': 'tourist_attraction',
  'amusement_park': 'tourist_attraction',
  'zoo': 'tourist_attraction',
  'aquarium': 'tourist_attraction',
  'art_gallery': 'tourist_attraction',
  'historical_landmark': 'tourist_attraction',
  'national_park': 'park',
  'botanical_garden': 'park',
  'garden': 'park',
};

/// OpenStreetMap types (Nominatim's `type`), by place type.
const _osmTypes = <String, List<String>>{
  'airport': ['aerodrome', 'airport', 'terminal', 'apron'],
  'ferry_terminal': ['ferry_terminal', 'pier', 'harbour', 'jetty'],
  'bus_station': ['bus_station', 'bus_stop'],
  'subway_station': ['subway_entrance', 'subway', 'light_rail', 'monorail', 'tram_stop'],
  'train_station': ['station', 'halt', 'train_station', 'railway'],
  'hospital': ['hospital', 'clinic', 'doctors'],
  'university': ['university', 'college', 'school', 'kindergarten'],
  'mosque': ['place_of_worship', 'mosque', 'temple', 'church', 'shrine'],
  'market': ['marketplace', 'market'],
  'local_government_office': ['townhall', 'government', 'courthouse', 'police', 'embassy', 'public_building', 'post_office'],
  'lodging': ['hotel', 'motel', 'resort', 'guest_house', 'hostel'],
  'stadium': ['stadium', 'sports_centre', 'arena'],
  'convention_center': ['events_venue', 'conference_centre', 'exhibition_centre'],
  'tourist_attraction': ['attraction', 'museum', 'zoo', 'theme_park', 'aquarium', 'theatre', 'viewpoint'],
  'park': ['park', 'garden', 'nature_reserve'],
  'corporate_office': ['office', 'commercial'],
  'shopping_mall': ['mall', 'department_store', 'shopping_centre'],
};

/// The name rules, in order: the first that matches wins. The name is lower
/// case with everything but letters and digits made spaces, padded with a
/// space: ' klia' is a word starting with klia, ' mrt ' the word mrt, 'mall'
/// mall anywhere (Megamall).
const placeTypeNameRules = <(String, List<String>)>[
  ('airport', [' klia', ' airport', ' lapangan terbang', ' aerodrome', ' lcct ']),
  ('ferry_terminal', [' ferry', ' feri ', ' jetty', ' jeti ']),
  ('bus_station', [' bus ', ' bas ', ' tbs ', ' terminal bersepadu', ' hentian ', ' puduraya']),
  ('subway_station', [' mrt ', ' lrt ', ' monorail']),
  ('train_station', [' sentral', ' ktm ', ' station', ' stesen ', ' erl ', ' ets ']),
  ('hospital', [' hospital', ' medical', ' clinic', ' klinik', ' perubatan']),
  ('university', [' university', ' universiti', ' college', ' school', ' kolej', ' sekolah', ' politeknik', ' campus', ' kampus']),
  ('mosque', [' masjid', ' mosque', ' temple', ' church', ' kuil', ' surau', ' gereja', ' tokong', ' gurdwara']),
  ('market', [' pasar', ' market']),
  ('local_government_office', [
    ' jabatan', ' kementerian', ' majlis', ' dewan bandaraya', ' dbkl ', ' jpj ', ' imigresen', ' immigration',
    ' government', ' city hall', ' mahkamah', ' balai polis', ' police',
  ]),
  ('lodging', [' hotel', ' resort', ' hostel', ' inn ']),
  ('stadium', [' stadium', ' arena']),
  ('convention_center', [' convention', ' exhibition', ' auditorium', ' expo ']),
  ('tourist_attraction', [' museum', ' muzium', ' zoo ', ' aquarium', ' aquaria', ' theme park']),
  // Shopping words before the park rule: "Shopping Park", "Gardens Mall" (0265).
  ('shopping_mall', ['mall', ' shopping', ' outlet']),
  ('park', [' park ', ' tasik ', ' gardens', ' botanical']),
  ('corporate_office', [' tower', ' menara', ' office', ' wisma ']),
  // The usual mall names without "mall" in them (0265).
  ('shopping_mall', [
    ' plaza', ' centre', ' center', ' square', ' galleria', ' klcc ', ' aeon ', ' pavilion', ' pyramid', ' city ',
    ' point ', ' central ', ' junction ', ' parade ', ' complex ', ' hub ', ' walk ', ' mytown ', ' utama ',
    ' vivocity', ' the curve ', ' trx ', ' ion orchard', ' paragon ', ' suntec ', ' bugis', ' funan ', ' jem ',
    ' westgate ', ' nex ',
  ]),
];

/// The type a place's Google main type ([googleType]), OpenStreetMap type
/// ([osmType]) and [name] suggest, in that order, else Other. A Google
/// type that is a starting type, or means one ([googleTypeAliases]), is
/// taken. Pure.
String guessPlaceType(String? name, {String? osmType, String? googleType}) {
  final gt = (googleType ?? '').trim().toLowerCase();
  if (gt.isNotEmpty) {
    if (googleTypeAliases[gt] case final k?) return k;
    if (defaultPlaceTypes.any((t) => t.key == gt) && gt != otherPlaceTypeKey) return gt;
  }
  final o = (osmType ?? '').trim().toLowerCase();
  if (o.isNotEmpty) {
    for (final e in _osmTypes.entries) {
      if (e.value.contains(o)) return e.key;
    }
  }
  final s = ' ${(name ?? '').toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), ' ').trim()} ';
  for (final (key, pats) in placeTypeNameRules) {
    if (pats.any(s.contains)) return key;
  }
  return otherPlaceTypeKey;
}

/// The guess as one of [types] that is on, else Other. A Google main type
/// the admin added as a type of its own is taken as it is.
String pickPlaceType(String? name, List<PlaceType> types, {String? osmType, String? googleType}) {
  final gt = (googleType ?? '').trim().toLowerCase();
  if (gt.isNotEmpty && gt != otherPlaceTypeKey && types.any((t) => t.key == gt && t.active)) return gt;
  final g = guessPlaceType(name, osmType: osmType, googleType: googleType);
  return types.any((t) => t.key == g && t.active) ? g : otherPlaceTypeKey;
}

/// A place's stored type key (`values.placeType`), or null.
String? placeTypeKeyOf(Map<String, dynamic>? values) {
  final k = '${values?['placeType'] ?? ''}'.trim();
  return k.isEmpty ? null : k;
}

/// Whether the admin chose the place's type (`values.placeTypeSet`).
bool placeTypeSetOf(Map<String, dynamic>? values) {
  final v = values?['placeTypeSet'];
  return v == true || (v is String && const {'true', '1', 'yes', 'on'}.contains(v.trim().toLowerCase()));
}

/// The chip colour Google gave the place (`values.iconBackgroundColor`,
/// from Places search), or null.
Color? placeIconColorOf(Map<String, dynamic>? values) => parsePlaceTypeColor('${values?['iconBackgroundColor'] ?? ''}');

/// How many places use each type, from the `multi_gate` place rows'
/// values. A place without a type counts as Other.
Map<String, int> placeTypeCounts(Iterable<Map<String, dynamic>> places) {
  final out = <String, int>{};
  for (final v in places) {
    final k = placeTypeKeyOf(v) ?? otherPlaceTypeKey;
    out[k] = (out[k] ?? 0) + 1;
  }
  return out;
}

/// The line under a place in search: "Mall · 4 gates · address" (the gate
/// count left out without gates, the address without one).
String placeTypeLine(PlaceType type, {int gates = 0, String? address}) => [
      type.name,
      if (gates > 0) '$gates ${gates == 1 ? 'gate' : 'gates'}',
      if ((address ?? '').trim().isNotEmpty) address!.trim(),
    ].join(' · ');
