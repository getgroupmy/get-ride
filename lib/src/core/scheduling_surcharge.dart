/// Advance-booking (scheduled ride) surcharge overrides (migration 0414): per
/// service type AND region (Country / State / City / Suburb, plus one master),
/// a flat amount plus a percentage of the fare. Resolved narrowest-first like a
/// commission rate (core/commission.dart) and the ride-display rule
/// (ride_display_rules.dart), with one extra tie-break: a row naming a service
/// beats an all-service row at the same level. With no matching row the booking
/// falls back to the global scheduled-rides fee (scheduled_rides.dart), so the
/// override table is purely additive.
library;

import 'commission.dart' show Geo;
import 'ride_bidding.dart' show placeNameMatches;
import 'scheduled_rides.dart' show ScheduledRidesConfig, schedulingFee;

class SchedulingSurchargeRule {
  const SchedulingSurchargeRule({
    required this.level,
    this.service,
    this.feeFixed = 0,
    this.feePercent = 0,
    this.active = true,
    this.country,
    this.state,
    this.city,
    this.suburb,
    this.id,
    this.priority = 0,
    this.updatedAt,
  });

  factory SchedulingSurchargeRule.fromRow(Map<String, dynamic> r) => SchedulingSurchargeRule(
        level: r['level'] as String,
        service: _norm(r['service'] as String?),
        feeFixed: (r['fee_fixed'] as num?)?.toDouble() ?? 0,
        feePercent: (r['fee_percent'] as num?)?.toDouble() ?? 0,
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

  /// The service type this rate is for, or null for every service.
  final String? service;
  final double feeFixed, feePercent;
  final bool active;
  final String? country, state, city, suburb, id;
  final int priority;
  final DateTime? updatedAt;

  /// The fee this rate charges on a ride of [fare], to the cent.
  double feeOn(double fare) => _cents(feeFixed + (fare < 0 ? 0 : fare) * feePercent / 100);
}

double _cents(double v) => (v * 100).roundToDouble() / 100;

String? _norm(String? v) {
  final t = (v ?? '').trim();
  return t.isEmpty ? null : t;
}

bool _place(String? rule, String? ride) {
  final r = _norm(rule), p = _norm(ride);
  return r != null && p != null && (r.toLowerCase() == p.toLowerCase() || placeNameMatches(r, p));
}

bool _parent(String? rule, String? ride) => _norm(rule) == null || _norm(ride) == null || _place(rule, ride);

const _rank = {'suburb': 5, 'city': 4, 'state': 3, 'country': 2, 'master': 1};

bool _regionApplies(SchedulingSurchargeRule r, Geo g) => switch (r.level) {
      'suburb' => _place(r.suburb, g.suburb) && _parent(r.city, g.city) && _parent(r.state, g.state) &&
          _parent(r.country, g.country),
      'city' => _place(r.city, g.city) && _parent(r.state, g.state) && _parent(r.country, g.country),
      'state' => _place(r.state, g.state) && _parent(r.country, g.country),
      'country' => _place(r.country, g.country),
      'master' => true,
      _ => false,
    };

/// Whether this rate is for [service]: an all-service row matches anything; a
/// service row matches that service only (case-insensitive).
bool _serviceApplies(SchedulingSurchargeRule r, String? service) =>
    r.service == null || r.service!.toLowerCase() == _norm(service)?.toLowerCase();

int _named(SchedulingSurchargeRule r) => [r.country, r.state, r.city].where((v) => v != null).length;

/// The rate a scheduled booking of [service] in [geo] resolves to; null when no
/// row matches (the caller then uses the global fee).
SchedulingSurchargeRule? resolveSchedulingSurchargeRule(
  List<SchedulingSurchargeRule> rules, {
  String? service,
  Geo geo = const Geo(),
}) {
  final hits = rules.where((r) => r.active && _serviceApplies(r, service) && _regionApplies(r, geo)).toList()
    ..sort((a, b) {
      int by(int x, int y) => y.compareTo(x);
      return [
        by(_rank[a.level] ?? 0, _rank[b.level] ?? 0),
        by(a.service != null ? 1 : 0, b.service != null ? 1 : 0), // a service row wins
        by(a.priority, b.priority),
        by(_named(a), _named(b)),
        (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)),
        (a.id ?? '').compareTo(b.id ?? ''),
      ].firstWhere((v) => v != 0, orElse: () => 0);
    });
  return hits.firstOrNull;
}

/// The advance-booking surcharge on a scheduled booking of [service] in [geo]
/// for a ride of [fare]: the matching override rate, else the global
/// scheduled-rides fee ([config]). Mirrors the server's scheduling_surcharge_fee.
double resolveSchedulingSurcharge(
  List<SchedulingSurchargeRule> rules,
  ScheduledRidesConfig config, {
  required double fare,
  String? service,
  Geo geo = const Geo(),
}) {
  final rule = resolveSchedulingSurchargeRule(rules, service: service, geo: geo);
  return rule?.feeOn(fare) ?? schedulingFee(fare, config);
}

/// Which geography fields a level needs (mirrors commission's `requiredScope`).
List<String> schedulingSurchargeRequiredScope(String level) => switch (level) {
      'country' => ['country'],
      'state' => ['country', 'state'],
      'city' => ['country', 'state', 'city'],
      'suburb' => ['country', 'state', 'city', 'suburb'],
      _ => const [],
    };

/// The scope in words: "Platform default", or "Kajang, Selangor, Malaysia".
String schedulingSurchargeScopeLabel(Map<String, dynamic> r) => switch (r['level']) {
      'master' => 'Everywhere',
      _ => [r['suburb'], r['city'], r['state'], r['country']]
          .whereType<String>()
          .where((s) => s.trim().isNotEmpty)
          .join(', '),
    };
