/// Saved places (inDrive's "Saved" tab on Enter your route): Home, Work and
/// any number of others, each with a name, the address, the point and the
/// entrance to wait at. Pure.
library;

import 'package:latlong2/latlong.dart';

enum SavedPlaceKind { home, work, other }

class SavedPlace {
  const SavedPlace({
    this.id,
    required this.kind,
    required this.name,
    required this.address,
    required this.point,
    this.entrance = '',
  });

  /// Null until stored.
  final String? id;
  final SavedPlaceKind kind;
  final String name;
  final String address;
  final LatLng point;

  /// Where to wait at the place ("Gate B", "Lobby"); empty for none.
  final String entrance;

  /// What the list shows: Home and Work by their kind, the rest by name.
  String get title => switch (kind) {
    SavedPlaceKind.home => 'Home',
    SavedPlaceKind.work => 'Work',
    SavedPlaceKind.other => name,
  };

  SavedPlace copyWith({String? name, String? address, LatLng? point, String? entrance}) => SavedPlace(
    id: id,
    kind: kind,
    name: name ?? this.name,
    address: address ?? this.address,
    point: point ?? this.point,
    entrance: entrance ?? this.entrance,
  );

  /// A stored row; null when it is unusable.
  static SavedPlace? fromRow(Map<String, dynamic> r) {
    final lat = r['lat'], lng = r['lng'];
    if (lat is! num || lng is! num) return null;
    final kind = SavedPlaceKind.values.where((k) => k.name == r['kind']).firstOrNull ?? SavedPlaceKind.other;
    final name = '${r['name'] ?? ''}'.trim();
    return SavedPlace(
      id: r['id'] as String?,
      kind: kind,
      name: name.isEmpty ? (kind == SavedPlaceKind.other ? 'Saved place' : kind.name) : name,
      address: '${r['address'] ?? ''}',
      point: LatLng(lat.toDouble(), lng.toDouble()),
      entrance: '${r['entrance'] ?? ''}'.trim(),
    );
  }

  Map<String, dynamic> toRow() => {
    'kind': kind.name,
    // Home and Work are stored by their kind's name when none is given.
    'name': name.trim().isNotEmpty ? name.trim() : (kind == SavedPlaceKind.other ? 'Saved place' : title),
    'address': address.trim(),
    'lat': point.latitude,
    'lng': point.longitude,
    'entrance': entrance.trim(),
  };
}

/// The Saved tab as inDrive lays it out: Home (or None to add it), Work (or
/// None), then the other places, oldest first as they are stored.
({SavedPlace? home, SavedPlace? work, List<SavedPlace> others}) arrangeSavedPlaces(List<SavedPlace> all) => (
  home: all.where((p) => p.kind == SavedPlaceKind.home).firstOrNull,
  work: all.where((p) => p.kind == SavedPlaceKind.work).firstOrNull,
  others: [
    for (final p in all)
      if (p.kind == SavedPlaceKind.other) p,
  ],
);

/// "0km", "4.2km", "30.7km", "128km" from [from] to [to]; empty without a
/// starting point.
String savedPlaceDistance(LatLng? from, LatLng to) {
  if (from == null) return '';
  final km = const Distance().as(LengthUnit.Meter, from, to) / 1000;
  if (km < 0.05) return '0km';
  if (km >= 100) return '${km.round()}km';
  return '${km.toStringAsFixed(1)}km';
}

/// Why a place can't be saved yet; null when it can.
String? savedPlaceProblem({required SavedPlaceKind kind, required String name, required String address}) {
  if (address.trim().isEmpty) return 'Choose the address first';
  if (kind == SavedPlaceKind.other && name.trim().isEmpty) return 'Give the place a name';
  if (name.trim().length > 80) return 'The name is too long';
  return null;
}
