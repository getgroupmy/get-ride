/// Region ride-display rules (migration 0411): per Country / State / City /
/// Suburb an admin can turn off the AI fare (its pricing and its badge) and the
/// distance·time line. Resolved narrowest-first, exactly like the commission
/// rate (core/commission.dart): the most specific active rule wins, then the
/// higher priority, then the rule naming more of its parents, then the newest.
/// One winning rule carries both switches; with no rule the ride home shows
/// everything, as before.
library;

import 'commission.dart' show Geo;
import 'ride_bidding.dart' show placeNameMatches;

class RideDisplayRule {
  const RideDisplayRule({
    required this.level,
    this.aiFareOff = false,
    this.distanceTimeOff = false,
    this.active = true,
    this.country,
    this.state,
    this.city,
    this.suburb,
    this.id,
    this.priority = 0,
    this.updatedAt,
  });

  factory RideDisplayRule.fromRow(Map<String, dynamic> r) => RideDisplayRule(
        level: r['level'] as String,
        aiFareOff: r['ai_fare_off'] == true,
        distanceTimeOff: r['distance_time_off'] == true,
        active: r['active'] != false,
        country: r['country'] as String?,
        state: r['state'] as String?,
        city: r['city'] as String?,
        suburb: r['suburb'] as String?,
        id: r['id'] as String?,
        priority: (r['priority'] as num?)?.toInt() ?? 0,
        updatedAt: DateTime.tryParse('${r['updated_at'] ?? ''}'),
      );

  final String level;
  final bool aiFareOff, distanceTimeOff, active;
  final String? country, state, city, suburb, id;
  final int priority;
  final DateTime? updatedAt;
}

/// What the ride home should show for a pickup: both switches, defaulting to
/// "show everything" (nothing turned off).
class RideDisplay {
  const RideDisplay({this.aiFareOff = false, this.distanceTimeOff = false});
  final bool aiFareOff, distanceTimeOff;
}

/// The default: the AI fare and the distance·time line both show.
const rideDisplayShown = RideDisplay();

String? _norm(String? v) {
  final t = (v ?? '').trim();
  return t.isEmpty ? null : t;
}

/// A rule's place against the trip's: the same, or the region's name as whole
/// words in the geocoder's (mirrors commission's `_place`).
bool _place(String? rule, String? ride) {
  final r = _norm(rule), p = _norm(ride);
  return r != null && p != null && (r.toLowerCase() == p.toLowerCase() || placeNameMatches(r, p));
}

/// A parent only counts when both the rule and the trip name it.
bool _parent(String? rule, String? ride) => _norm(rule) == null || _norm(ride) == null || _place(rule, ride);

const _rank = {'suburb': 5, 'city': 4, 'state': 3, 'country': 2, 'master': 1};

bool _applies(RideDisplayRule r, Geo g) => switch (r.level) {
      'suburb' => _place(r.suburb, g.suburb) && _parent(r.city, g.city) && _parent(r.state, g.state) &&
          _parent(r.country, g.country),
      'city' => _place(r.city, g.city) && _parent(r.state, g.state) && _parent(r.country, g.country),
      'state' => _place(r.state, g.state) && _parent(r.country, g.country),
      'country' => _place(r.country, g.country),
      'master' => true,
      _ => false,
    };

int _named(RideDisplayRule r) => [r.country, r.state, r.city].where((v) => v != null).length;

/// The rule a trip in [geo] is shown under; null when none applies.
RideDisplayRule? resolveRideDisplayRule(List<RideDisplayRule> rules, {Geo geo = const Geo()}) {
  final hits = rules.where((r) => r.active && _applies(r, geo)).toList()
    ..sort((a, b) {
      int by(int x, int y) => y.compareTo(x);
      return [
        by(_rank[a.level] ?? 0, _rank[b.level] ?? 0),
        by(a.priority, b.priority),
        by(_named(a), _named(b)),
        (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)),
        (a.id ?? '').compareTo(b.id ?? ''),
      ].firstWhere((v) => v != 0, orElse: () => 0);
    });
  return hits.firstOrNull;
}

/// Both display switches for a pickup in [geo]; "show everything" with no rule.
RideDisplay resolveRideDisplay(List<RideDisplayRule> rules, {Geo geo = const Geo()}) {
  final r = resolveRideDisplayRule(rules, geo: geo);
  return r == null ? rideDisplayShown : RideDisplay(aiFareOff: r.aiFareOff, distanceTimeOff: r.distanceTimeOff);
}

/// Which geography fields a level needs (mirrors commission's `requiredScope`,
/// without the per-user level).
List<String> rideDisplayRequiredScope(String level) => switch (level) {
      'country' => ['country'],
      'state' => ['country', 'state'],
      'city' => ['country', 'state', 'city'],
      'suburb' => ['country', 'state', 'city', 'suburb'],
      _ => const [],
    };

/// The scope in words: "Platform default", or "Kajang, Selangor, Malaysia".
String rideDisplayScopeLabel(Map<String, dynamic> r) => switch (r['level']) {
      'master' => 'Platform default',
      _ => [r['suburb'], r['city'], r['state'], r['country']]
          .whereType<String>()
          .where((s) => s.trim().isNotEmpty)
          .join(', '),
    };
