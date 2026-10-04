/// Commission-rate resolution, ported from the Expo app's
/// `utils/commissionStore.ts` (`resolveCommissionRate`). Priority, highest
/// first: user → suburb → city → state → country → master → default.
library;

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
      );

  final String level;
  final double rate;
  final bool active;
  final String? country, state, city, suburb, userId;
}

class Geo {
  const Geo({this.country, this.state, this.city, this.suburb});
  final String? country, state, city, suburb;
}

String? _norm(String? v) {
  final t = (v ?? '').trim();
  return t.isEmpty ? null : t;
}

bool _eqi(String? a, String? b) => (a ?? '').trim().toLowerCase() == (b ?? '').trim().toLowerCase();

bool _parentsMatch(CommissionRule r, Geo g) {
  if (r.country != null && g.country != null && !_eqi(r.country, g.country)) return false;
  if (r.state != null && g.state != null && !_eqi(r.state, g.state)) return false;
  if (r.city != null && g.city != null && !_eqi(r.city, g.city)) return false;
  return true;
}

double resolveCommissionRate(List<CommissionRule> rules, {String? userId, Geo geo = const Geo()}) {
  final active = rules.where((r) => r.active).toList();
  CommissionRule? find(bool Function(CommissionRule) test) {
    for (final r in active) {
      if (test(r)) return r;
    }
    return null;
  }

  final uid = _norm(userId);
  if (uid != null) {
    final hit = find((r) => r.level == 'user' && r.userId == uid);
    if (hit != null) return hit.rate;
  }
  final suburb = _norm(geo.suburb);
  if (suburb != null) {
    final hit = find((r) => r.level == 'suburb' && _eqi(r.suburb, suburb) && _parentsMatch(r, geo));
    if (hit != null) return hit.rate;
  }
  final city = _norm(geo.city);
  if (city != null) {
    final hit = find((r) => r.level == 'city' && _eqi(r.city, city) && _parentsMatch(r, geo));
    if (hit != null) return hit.rate;
  }
  final state = _norm(geo.state);
  if (state != null) {
    final hit = find((r) => r.level == 'state' && _eqi(r.state, state) && _parentsMatch(r, geo));
    if (hit != null) return hit.rate;
  }
  final country = _norm(geo.country);
  if (country != null) {
    final hit = find((r) => r.level == 'country' && _eqi(r.country, country));
    if (hit != null) return hit.rate;
  }
  return find((r) => r.level == 'master')?.rate ?? defaultCommissionRate;
}
