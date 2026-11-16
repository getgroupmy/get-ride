/// Staged dispatch ladder (migration 0417): per service type AND region, an
/// ordered list of rings `{radius_km, hold_sec}` the server widens a new open
/// request through — 2 km first, then 5 km after a hold, then 10 km, then
/// everybody. The server resolves the ladder once from the pickup point and
/// FREEZES it onto the request row (`dispatch_ladder` + `dispatch_opened_at` +
/// `dispatch_step`), pushing one ring at a time; the partner app reads the same
/// frozen ladder so the offer appears on screen exactly as the push widens.
///
/// Two halves live here:
///   * [DispatchLadder] — the runtime, frozen ladder a request carries, used by
///     the partner list to decide the reach a request has been offered to.
///   * [DispatchLadderRule] — one admin rule (service + region + rings), edited
///     in Admin → Dispatch ladder and resolved on the server (dispatch_ladder_at).
library;

import 'commission.dart' show Geo;
import 'ride_bidding.dart' show placeNameMatches;

/// One runtime ring: the drivers within [radiusKm] of the pickup are pushed
/// [afterSec] seconds after the request opened to all. A null [radiusKm] is the
/// "everybody" ring (every online driver, no distance cap).
typedef LadderRing = ({int afterSec, double? radiusKm});

/// The expanded ladder frozen on a request row (`ride_requests.dispatch_ladder`,
/// an array of `{after_sec, radius_km}`). Pure.
class DispatchLadder {
  const DispatchLadder(this.rings);

  final List<LadderRing> rings;

  /// Parses the stamped `dispatch_ladder` value (a JSON array), or null when it
  /// is absent or malformed (the caller then falls back to the service radius).
  static DispatchLadder? fromStamped(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    final rings = <LadderRing>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final after = e['after_sec'];
      final radius = e['radius_km'];
      rings.add((
        afterSec: after is num ? after.toInt() : int.tryParse('${after ?? ''}') ?? 0,
        radiusKm: radius == null ? null : (radius is num ? radius.toDouble() : double.tryParse('$radius')),
      ));
    }
    return rings.isEmpty ? null : DispatchLadder(rings);
  }

  /// The reach the server has actually offered this request to, from the number
  /// of rings it has pushed ([dispatchStep], `ride_requests.dispatch_step`): the
  /// widest radius among the pushed rings, or [double.infinity] once the
  /// "everybody" ring is among them. Gating the on-screen list on this — rather
  /// than on a local clock — keeps the list in lockstep with the push, since the
  /// server bumps dispatch_step (a realtime row update) exactly as it widens.
  /// 0 before anything is pushed.
  double reachedRadiusKmByStep(int dispatchStep) {
    var reach = 0.0;
    final n = dispatchStep.clamp(0, rings.length);
    for (var i = 0; i < n; i++) {
      final r = rings[i].radiusKm;
      if (r == null) return double.infinity; // the everybody ring
      if (r > reach) reach = r;
    }
    return reach;
  }

  /// The reach by [elapsedSeconds] since the request opened to all: the widest
  /// due ring, [double.infinity] once the everybody ring is due. Mirrors the
  /// server's dispatch_ladder_reached_km; the list gates on
  /// [reachedRadiusKmByStep] instead, but this is handy for a "searching within
  /// N km" read-out and parity tests.
  double reachedRadiusKmByTime(double elapsedSeconds) {
    var reach = 0.0;
    for (final ring in rings) {
      if (ring.afterSec <= elapsedSeconds) {
        final r = ring.radiusKm;
        if (r == null) return double.infinity;
        if (r > reach) reach = r;
      }
    }
    return reach;
  }
}

/// One admin dispatch-ladder rule (`dispatch_ladder_rules`): the rings for a
/// service in a region. Resolved on the server narrowest-first with a
/// service-specific row beating an all-service one, exactly like the commission
/// rate and the scheduling surcharge; this model backs the admin editor.
class DispatchLadderRule {
  const DispatchLadderRule({
    required this.level,
    this.service,
    this.steps = const [],
    this.offerEveryone = true,
    this.active = true,
    this.country,
    this.state,
    this.city,
    this.suburb,
    this.id,
    this.priority = 0,
    this.updatedAt,
  });

  factory DispatchLadderRule.fromRow(Map<String, dynamic> r) => DispatchLadderRule(
        level: r['level'] as String,
        service: _norm(r['service'] as String?),
        steps: parseLadderSteps(r['steps']),
        offerEveryone: r['offer_everyone'] != false,
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

  /// The service this ladder is for, or null for every service.
  final String? service;

  /// The rings as stored: each a radius (km) and how long to hold there before
  /// widening to the next.
  final List<LadderStep> steps;
  final bool offerEveryone;
  final bool active;
  final String? country, state, city, suburb, id;
  final int priority;
  final DateTime? updatedAt;

  /// The rings expanded to the runtime ladder the server freezes and the app
  /// reads — cumulative `after_sec`, plus a trailing everybody ring when
  /// [offerEveryone]. Mirrors the server's dispatch_ladder_expand.
  DispatchLadder expand() {
    final rings = <LadderRing>[];
    var acc = 0;
    for (final s in steps) {
      rings.add((afterSec: acc, radiusKm: s.radiusKm));
      acc += s.holdSec < 0 ? 0 : s.holdSec;
    }
    if (offerEveryone) rings.add((afterSec: acc, radiusKm: null));
    return DispatchLadder(rings);
  }
}

/// One stored ring in a rule: a radius and the hold at it before widening.
typedef LadderStep = ({double radiusKm, int holdSec});

/// Parses a rule's `steps` JSON (array of `{radius_km, hold_sec}`); drops
/// malformed entries.
List<LadderStep> parseLadderSteps(Object? raw) {
  if (raw is! List) return const [];
  final out = <LadderStep>[];
  for (final e in raw) {
    if (e is! Map) continue;
    final radius = e['radius_km'];
    final hold = e['hold_sec'];
    final r = radius is num ? radius.toDouble() : double.tryParse('${radius ?? ''}');
    if (r == null || r <= 0) continue;
    out.add((radiusKm: r, holdSec: hold is num ? hold.toInt() : int.tryParse('${hold ?? ''}') ?? 0));
  }
  return out;
}

/// The rings as JSON for a write (`{radius_km, hold_sec}` per ring).
List<Map<String, dynamic>> ladderStepsToJson(List<LadderStep> steps) =>
    [for (final s in steps) {'radius_km': s.radiusKm, 'hold_sec': s.holdSec}];

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

bool _regionApplies(DispatchLadderRule r, Geo g) => switch (r.level) {
      'suburb' => _place(r.suburb, g.suburb) && _parent(r.city, g.city) && _parent(r.state, g.state) &&
          _parent(r.country, g.country),
      'city' => _place(r.city, g.city) && _parent(r.state, g.state) && _parent(r.country, g.country),
      'state' => _place(r.state, g.state) && _parent(r.country, g.country),
      'country' => _place(r.country, g.country),
      'master' => true,
      _ => false,
    };

bool _serviceApplies(DispatchLadderRule r, String? service) =>
    r.service == null || r.service!.toLowerCase() == _norm(service)?.toLowerCase();

int _named(DispatchLadderRule r) => [r.country, r.state, r.city].where((v) => v != null).length;

/// The rule a request for [service] in [geo] resolves to; null when none match
/// (the server then uses the legacy per-service min/max/widen config). Mirrors
/// the server's dispatch_ladder_at ordering; used for the admin editor's "what
/// applies here" preview.
DispatchLadderRule? resolveDispatchLadderRule(
  List<DispatchLadderRule> rules, {
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

/// Which geography fields a level needs (mirrors commission's `requiredScope`).
List<String> dispatchLadderRequiredScope(String level) => switch (level) {
      'country' => ['country'],
      'state' => ['country', 'state'],
      'city' => ['country', 'state', 'city'],
      'suburb' => ['country', 'state', 'city', 'suburb'],
      _ => const [],
    };

/// The scope in words: "Everywhere", or "Kajang, Selangor, Malaysia".
String dispatchLadderScopeLabel(Map<String, dynamic> r) => switch (r['level']) {
      'master' => 'Everywhere',
      _ => [r['suburb'], r['city'], r['state'], r['country']]
          .whereType<String>()
          .where((s) => s.trim().isNotEmpty)
          .join(', '),
    };

/// "All services", or the service name.
String dispatchLadderServiceLabel(Map<String, dynamic> r) {
  final s = (r['service'] as String?)?.trim();
  return s == null || s.isEmpty ? 'All services' : s;
}

/// The rings in words: "2 km · 5 km · 10 km · everybody", or "No rings".
String dispatchLadderRingsLabel(Map<String, dynamic> r) {
  final steps = parseLadderSteps(r['steps']);
  final parts = [
    for (final s in steps) '${s.radiusKm == s.radiusKm.roundToDouble() ? s.radiusKm.toInt() : s.radiusKm} km',
    if (r['offer_everyone'] != false) 'everybody',
  ];
  return parts.isEmpty ? 'No rings' : parts.join(' · ');
}
