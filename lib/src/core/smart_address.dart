// Smart address (Admin → Settings → Maps, migration 0207): how place search
// results are shown and checked.
//
//   A  clean two-line results: the place's name, and under it only its area
//      ("Sepang, Selangor"), with an icon for what it is
//   B  places first: the rider's saved and recent places that match on top,
//      then named places, then plain street addresses
//   C  a picked street address is checked and completed by Google's Address
//      Validation ("✓ Address confirmed by Google")
//
// 'all' is A, B and C together; 'normal' is none of them.
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../data/geo_service.dart';
import 'saved_places.dart';

/// Admin → Settings → Maps' smart address choice.
@immutable
class SmartAddress {
  const SmartAddress(this.option);

  /// 'normal', 'a', 'b', 'c' or 'all'.
  final String option;

  bool get clean => option == 'a' || option == 'all';
  bool get placesFirst => option == 'b' || option == 'all';
  bool get check => option == 'c' || option == 'all';
}

const _countries = {
  'malaysia',
  'singapore',
  'indonesia',
  'thailand',
  'brunei',
  'philippines',
  'vietnam',
  'myanmar',
  'cambodia',
};

/// Whether [label] is only "lat, lng" (what a place reads as before its
/// address has been looked up).
bool isCoordinateLabel(String label) => RegExp(r'^\s*-?\d+(\.\d+)?\s*,\s*-?\d+(\.\d+)?\s*$').hasMatch(label);

/// [p]'s address as area parts, nearest the place first: without its name,
/// house number, street, postcode or country, and no part twice.
List<String> _areaParts(Place p) {
  final name = p.name.trim().toLowerCase();
  final parts = <String>[];
  final all = p.address.split(',');
  for (var i = 0; i < all.length; i++) {
    final part = all[i].trim().replaceFirst(RegExp(r'^\d{4,6}\s+'), '').replaceFirst(RegExp(r'\s+\d{4,6}$'), '');
    final l = part.toLowerCase();
    if (part.isEmpty || l == name || _countries.contains(l) || RegExp(r'^[\d\s/-]+$').hasMatch(part)) continue;
    // A street ("Jalan Ampang", "12 Jalan …"), but never the last part.
    if (i < all.length - 1 && _streetWords.hasMatch(part)) continue;
    if (parts.any((x) => x.toLowerCase() == l)) continue;
    parts.add(part);
  }
  return parts;
}

String _plain(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

/// Option A's second line, area then city: [p]'s address without its name,
/// house number, street, postcode or country ("Kuala Lumpur International
/// Airport (KLIA), 64000 Sepang, Selangor, Malaysia" → "Sepang, Selangor";
/// "KLCC, 156, Jalan Ampang, Kampung Sungai Baru, 50450 Kuala Lumpur,
/// Wilayah Persekutuan Kuala Lumpur, Malaysia" → "Kampung Sungai Baru, Kuala
/// Lumpur"). A state that only repeats the city goes; with more than city
/// and state, the area nearest the place (not one the name already holds)
/// stands before the city. The address as it is when nothing is left. With
/// [homeRegion] (the rider's own state, e.g. "Selangor") a trailing state
/// that is the same is dropped too, where something is left before it.
String shortArea(Place p, {String? homeRegion}) {
  final parts = _areaParts(p);
  if (parts.isEmpty) return p.address;
  var stateGone = false;
  // "Kuala Lumpur, Wilayah Persekutuan Kuala Lumpur": the state says the city again.
  if (parts.length > 1) {
    final last = _plain(parts.last), city = _plain(parts[parts.length - 2]);
    if (city.isNotEmpty && (last == city || ' $last '.contains(' $city '))) {
      parts.removeLast();
      stateGone = true;
    }
  }
  final home = (homeRegion ?? '').trim().toLowerCase();
  if (!stateGone && home.isNotEmpty && parts.length > 1 && parts.last.toLowerCase() == home) {
    parts.removeLast();
    stateGone = true;
  }
  if (parts.length <= 2 && !(stateGone && parts.length == 2)) return parts.join(', ');
  final cityAt = stateGone ? parts.length - 1 : parts.length - 2;
  final name = _plain(p.name);
  String? area;
  for (var i = 0; i < cityAt; i++) {
    final a = _plain(parts[i]);
    if (a.isNotEmpty && !' $name '.contains(' $a ')) {
      area = parts[i];
      break;
    }
  }
  if (area == null) return parts.sublist(parts.length - 2).join(', ');
  return '$area, ${parts[cityAt]}';
}

/// The line under a place's [name]: its [address], or null when that only
/// says the name again (the same words, or words the name already holds:
/// "KLCC - Petronas Twin Towers" over "KLCC - Petronas Twin Towers").
String? placeSubtitle(String name, String address) {
  String plain(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  final a = plain(address), n = plain(name);
  if (a.isEmpty || n.contains(a)) return null;
  return address;
}

/// The state (or other last area part) of [p]: "Selangor" for "…, 64000
/// Sepang, Selangor, Malaysia"; null when there is none.
String? areaRegion(Place? p) {
  if (p == null) return null;
  final parts = _areaParts(p);
  return parts.length < 2 ? null : parts.last;
}

/// The line under a place in the route sheet (search results and recents
/// alike): with smart address A ([clean]) its area then city, else its
/// address; never one that only says the name again (null then).
String? placeAreaLine(Place p, {required bool clean, String? homeRegion}) =>
    placeSubtitle(p.name, clean ? shortArea(p, homeRegion: homeRegion) : p.address);

const _addressTypes = {
  'street_address',
  'route',
  'premise',
  'subpremise',
  'street_number',
  'postal_code',
  'plus_code',
  'intersection',
};

final _streetWords = RegExp(
  r'^(\d|no\.?\s|lot\s|jalan\b|jln\.?\s|lorong\b|lrg\.?\s|persiaran\b|lebuh\b|lebuhraya\b|street\b|road\b)',
  caseSensitive: false,
);

/// A plain street address rather than a named place: by Google's types
/// where it gave them, else by how the name reads ("12 Jalan …", "Jalan …").
bool isStreetAddress(Place p) {
  if (p.types.isNotEmpty) {
    if (p.types.any(_addressTypes.contains)) return true;
    return false;
  }
  return _streetWords.hasMatch(p.name.trim());
}

/// What a result is, as an icon (option A).
IconData placeIcon(Place p) {
  final t = p.types.toSet();
  bool any(List<String> xs) => xs.any(t.contains);
  if (any(['airport'])) return Icons.flight;
  if (any(['train_station', 'subway_station', 'light_rail_station', 'transit_station'])) return Icons.train;
  if (any(['bus_station', 'bus_stop'])) return Icons.directions_bus;
  if (any(['shopping_mall', 'department_store'])) return Icons.local_mall_outlined;
  if (any(['lodging', 'hotel'])) return Icons.hotel_outlined;
  if (any(['hospital', 'doctor', 'pharmacy'])) return Icons.local_hospital_outlined;
  if (any(['university', 'school', 'secondary_school', 'primary_school'])) return Icons.school_outlined;
  if (any(['restaurant', 'cafe', 'food'])) return Icons.restaurant_outlined;
  if (any(['place_of_worship', 'mosque', 'church', 'hindu_temple'])) return Icons.account_balance_outlined;
  if (any(['park', 'tourist_attraction'])) return Icons.park_outlined;
  if (isStreetAddress(p)) return Icons.home_outlined;
  return Icons.place_outlined;
}

/// One row of option B's list.
@immutable
class SmartRow {
  const SmartRow.saved(SavedPlace this.saved) : place = null, recent = false;
  const SmartRow.place(Place this.place, {this.recent = false}) : saved = null;

  final SavedPlace? saved;
  final Place? place;

  /// One of the rider's recent places.
  final bool recent;
}

/// Option B's results: the rider's [saved] and [recent] places that match
/// [query] (every word in their name or address), then the named places
/// among [results], then the street addresses ([addresses]). Recent places
/// already saved, and results already shown above, are left out.
({List<SmartRow> top, List<Place> addresses}) placesFirst(
  String query,
  List<Place> results, {
  List<SavedPlace> saved = const [],
  List<Place> recent = const [],
}) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.length >= 2).toList();
  bool matches(String text) => words.isNotEmpty && words.every(text.toLowerCase().contains);
  bool near(LatLng a, LatLng b) => const Distance().as(LengthUnit.Meter, a, b) < 100;

  final savedHits = [
    for (final s in saved)
      if (matches('${s.title} ${s.name} ${s.address}')) s,
  ];
  final recentNames = <String>{};
  final recentHits = [
    for (final r in recent)
      // One row per place name: "Recent: KLCC" twice says nothing more.
      if (matches('${r.name} ${r.address}') &&
          !savedHits.any((s) => near(s.point, r.point)) &&
          recentNames.add(r.name.trim().toLowerCase()))
        r,
  ];
  bool shown(Place p) =>
      !p.pending && (savedHits.any((s) => near(s.point, p.point)) || recentHits.any((r) => near(r.point, p.point)));
  final rest = [
    for (final p in results)
      if (!shown(p)) p,
  ];
  return (
    top: [
      for (final s in savedHits.take(3)) SmartRow.saved(s),
      for (final r in recentHits.take(3)) SmartRow.place(r, recent: true),
      for (final p in rest)
        if (!isStreetAddress(p)) SmartRow.place(p),
    ],
    addresses: [
      for (final p in rest)
        if (isStreetAddress(p)) p,
    ],
  );
}
