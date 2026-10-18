/// Commission-rate resolution, kept in step with the database's
/// `commission_resolve` (migration 0216): the most specific level wins
/// (user → suburb → city → state → country → master), then the higher
/// priority, then the rule naming more of its parents, then the newest.
/// Places match as region names do (`placeNameMatches`, 0126).
library;

import 'ride_bidding.dart' show placeNameMatches;

const defaultCommissionRate = 0.15;

class CommissionRule {
  const CommissionRule({
    required this.level,
    required this.rate,
    this.active = true,
    this.country,
    this.state,
    this.city,
    this.suburb,
    this.userId,
    this.id,
    this.priority = 0,
    this.updatedAt,
  });

  factory CommissionRule.fromRow(Map<String, dynamic> r) => CommissionRule(
        level: r['level'] as String,
        rate: (r['rate'] as num).toDouble(),
        active: r['active'] != false,
        country: r['country'] as String?,
        state: r['state'] as String?,
        city: r['city'] as String?,
        suburb: r['suburb'] as String?,
        userId: r['user_id'] as String?,
        id: r['id'] as String?,
        priority: (r['priority'] as num?)?.toInt() ?? 0,
        updatedAt: DateTime.tryParse('${r['updated_at'] ?? ''}'),
      );

  final String level;
  final double rate;
  final bool active;
  final String? country, state, city, suburb, userId, id;
  final int priority;
  final DateTime? updatedAt;
}

class Geo {
  const Geo({this.country, this.state, this.city, this.suburb});
  final String? country, state, city, suburb;
}

String? _norm(String? v) {
  final t = (v ?? '').trim();
  return t.isEmpty ? null : t;
}

/// A rule's place against the trip's: the same, or the region's name as
/// whole words in the geocoder's.
bool _place(String? rule, String? ride) {
  final r = _norm(rule), p = _norm(ride);
  return r != null && p != null && (r.toLowerCase() == p.toLowerCase() || placeNameMatches(r, p));
}

/// A parent only counts when both the rule and the trip name it.
bool _parent(String? rule, String? ride) => _norm(rule) == null || _norm(ride) == null || _place(rule, ride);

const _rank = {'user': 6, 'suburb': 5, 'city': 4, 'state': 3, 'country': 2, 'master': 1};

bool _applies(CommissionRule r, String? userId, Geo g) => switch (r.level) {
      'user' => userId != null && r.userId == userId,
      'suburb' => _place(r.suburb, g.suburb) && _parent(r.city, g.city) && _parent(r.state, g.state) &&
          _parent(r.country, g.country),
      'city' => _place(r.city, g.city) && _parent(r.state, g.state) && _parent(r.country, g.country),
      'state' => _place(r.state, g.state) && _parent(r.country, g.country),
      'country' => _place(r.country, g.country),
      'master' => true,
      _ => false,
    };

int _named(CommissionRule r) => [r.country, r.state, r.city].where((v) => v != null).length;

/// The rule a trip by [userId] in [geo] is charged under; null for the
/// built-in [defaultCommissionRate].
CommissionRule? resolveCommissionRule(List<CommissionRule> rules, {String? userId, Geo geo = const Geo()}) {
  final uid = _norm(userId);
  final hits = rules.where((r) => r.active && _applies(r, uid, geo)).toList()
    ..sort((a, b) {
      int by(int x, int y) => y.compareTo(x);
      final c = [
        by(_rank[a.level] ?? 0, _rank[b.level] ?? 0),
        by(a.priority, b.priority),
        by(_named(a), _named(b)),
        (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)),
        (a.id ?? '').compareTo(b.id ?? ''),
      ].firstWhere((v) => v != 0, orElse: () => 0);
      return c;
    });
  return hits.firstOrNull;
}

double resolveCommissionRate(List<CommissionRule> rules, {String? userId, Geo geo = const Geo()}) =>
    resolveCommissionRule(rules, userId: userId, geo: geo)?.rate ?? defaultCommissionRate;
