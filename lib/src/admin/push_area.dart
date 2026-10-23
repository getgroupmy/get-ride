/// Where an admin broadcast goes (Admin -> Push Notification, migration
/// 0168): everywhere, the people in a region, or within a radius of a point.
/// send-push does the matching against each phone's last known place
/// (`_shared/push.ts`: parseArea / inArea); this is the admin's side of it.
/// Pure.
library;

import '../core/ride_bidding.dart' show BiddingRegion;

enum PushAreaKind { everywhere, region, radius }

/// The largest radius send-push accepts (AREA_MAX_RADIUS_KM).
const pushAreaMaxRadiusKm = 500.0;

class PushArea {
  const PushArea.everywhere()
    : kind = PushAreaKind.everywhere,
      country = '',
      state = '',
      city = '',
      suburb = '',
      lat = null,
      lng = null,
      radiusKm = 5;

  const PushArea.region({required this.country, this.state = '', this.city = '', this.suburb = ''})
    : kind = PushAreaKind.region,
      lat = null,
      lng = null,
      radiusKm = 5;

  const PushArea.radius({this.lat, this.lng, this.radiusKm = 5})
    : kind = PushAreaKind.radius,
      country = '',
      state = '',
      city = '',
      suburb = '';

  /// Read back from a saved notification or the history's `target`.
  static PushArea fromJson(Object? raw) {
    if (raw is! Map) return const PushArea.everywhere();
    final m = raw.map((k, v) => MapEntry('$k', v));
    double? n(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
    final lat = n(m['lat']), lng = n(m['lng']), r = n(m['radiusKm']);
    if (lat != null && lng != null && r != null) return PushArea.radius(lat: lat, lng: lng, radiusKm: r);
    String s(String k) => '${m[k] ?? ''}'.trim();
    if (s('country').isEmpty) return const PushArea.everywhere();
    return PushArea.region(country: s('country'), state: s('state'), city: s('city'), suburb: s('suburb'));
  }

  final PushAreaKind kind;
  final String country;
  final String state;
  final String city;
  final String suburb;
  final double? lat;
  final double? lng;
  final double radiusKm;

  /// Whether send-push can use it: everywhere, a region with a country, or a
  /// point with a radius in range.
  bool get complete => switch (kind) {
    PushAreaKind.everywhere => true,
    PushAreaKind.region => country.isNotEmpty,
    PushAreaKind.radius => lat != null && lng != null && radiusKm > 0 && radiusKm <= pushAreaMaxRadiusKm,
  };

  /// The request body's `area`; null for everywhere.
  Map<String, dynamic>? toJson() => switch (kind) {
    PushAreaKind.everywhere => null,
    PushAreaKind.region => {
      'country': country,
      if (state.isNotEmpty) 'state': state,
      if (city.isNotEmpty) 'city': city,
      if (suburb.isNotEmpty) 'suburb': suburb,
    },
    PushAreaKind.radius => {'lat': lat, 'lng': lng, 'radiusKm': radiusKm},
  };

  /// "in Kuala Lumpur, Malaysia", "within 5 km of 3.1390, 101.6869", or ''.
  String get label => switch (kind) {
    PushAreaKind.everywhere => '',
    PushAreaKind.region => 'in ${[suburb, city, state, country].where((s) => s.isNotEmpty).join(', ')}',
    PushAreaKind.radius =>
      lat == null || lng == null
          ? 'within ${_km(radiusKm)} of a point'
          : 'within ${_km(radiusKm)} of ${lat!.toStringAsFixed(4)}, ${lng!.toStringAsFixed(4)}',
  };

  PushArea copyWith({String? country, String? state, String? city, String? suburb, double? radiusKm}) => switch (kind) {
    PushAreaKind.region => PushArea.region(
      country: country ?? this.country,
      state: state ?? this.state,
      city: city ?? this.city,
      suburb: suburb ?? this.suburb,
    ),
    PushAreaKind.radius => PushArea.radius(lat: lat, lng: lng, radiusKm: radiusKm ?? this.radiusKm),
    PushAreaKind.everywhere => this,
  };

  @override
  bool operator ==(Object other) =>
      other is PushArea &&
      other.kind == kind &&
      other.country == country &&
      other.state == state &&
      other.city == city &&
      other.suburb == suburb &&
      other.lat == lat &&
      other.lng == lng &&
      other.radiusKm == radiusKm;

  @override
  int get hashCode => Object.hash(kind, country, state, city, suburb, lat, lng, radiusKm);
}

String _km(double km) => '${km == km.roundToDouble() ? km.toInt() : km} km';

/// The choices at each level of the region picker, from the admin's own
/// Regions (country -> state -> city -> suburb), sorted, each once.
({List<String> countries, List<String> states, List<String> cities, List<String> suburbs}) pushRegionChoices(
  List<BiddingRegion> regions,
  PushArea area,
) {
  String n(String s) => s.trim().toLowerCase();
  List<String> pick(bool Function(BiddingRegion r) where, String Function(BiddingRegion r) value) {
    final seen = <String, String>{};
    for (final r in regions) {
      final v = value(r).trim();
      if (v.isNotEmpty && where(r)) seen.putIfAbsent(n(v), () => v);
    }
    return seen.values.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  bool inCountry(BiddingRegion r) => n(r.country) == n(area.country);
  bool inState(BiddingRegion r) => inCountry(r) && n(r.state) == n(area.state);
  bool inCity(BiddingRegion r) => inState(r) && n(r.city) == n(area.city);
  return (
    countries: pick((_) => true, (r) => r.country),
    states: area.country.isEmpty ? const [] : pick(inCountry, (r) => r.state),
    cities: area.state.isEmpty ? const [] : pick(inState, (r) => r.city),
    suburbs: area.city.isEmpty ? const [] : pick(inCity, (r) => r.suburb),
  );
}

/// The preview line under the compose card, from send-push's dryRun answer.
String pushReachText(Map<String, dynamic> r, PushArea area) {
  int v(String k) => (r[k] as num?)?.toInt() ?? 0;
  final devices = v('recipients'), people = v('accounts'), unlocated = v('unlocated');
  final where = area.label.isEmpty ? '' : ' ${area.label}';
  final head = devices == 0
      ? 'Nobody$where would get this'
      : 'Reaches $people ${people == 1 ? 'person' : 'people'} on $devices ${devices == 1 ? 'device' : 'devices'}$where';
  // A partner send counts its partners too (0279), each once whatever its types.
  final partners = r['partners'] is num
      ? ' ${v('partners')} ${v('partners') == 1 ? 'partner matches' : 'partners match'}, each counted once.'
      : '';
  if (area.kind == PushAreaKind.everywhere || unlocated == 0) return '$head.$partners';
  return '$head. $unlocated ${unlocated == 1 ? 'device has' : 'devices have'} no known location yet and '
      '${unlocated == 1 ? 'is' : 'are'} left out.$partners';
}
