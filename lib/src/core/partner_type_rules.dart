/// Admin → Settings → Partner Type rules (migration 0245): a vehicle age
/// limit, a permit requirement, street hail, and where the type is offered,
/// each by region. Kept in the type's entry as `values.rules`; the server
/// (`partner_type_rules`, `ptr_*`) reads the same shape and has the last
/// word. Pure.
///
/// A [RegionScope] names a country, state, city and suburb; blank levels
/// match any place, so an empty scope is "All regions". The narrowest
/// matching age rule decides a place.
///
/// Missing rules keep the behaviour from before them: no age limit, no extra
/// permit, street hail for TEKSI only, and every type offered everywhere.
library;

import 'dart:convert';

import '../admin/screens/people/people_logic.dart' show ServiceArea;

/// Whole years a vehicle may be, as the editor accepts them.
const minVehicleAgeYears = 1;
const maxVehicleAgeYears = 50;

/// A place: country, state, city and suburb names ('' when unknown).
typedef RegionPlace = ({String country, String state, String city, String suburb});

const RegionPlace unknownPlace = (country: '', state: '', city: '', suburb: '');

String _norm(String s) => s.trim().toLowerCase();

String _s(Object? v) => v is String ? v.trim() : (v == null ? '' : '$v'.trim());

bool _flag(Object? v, bool fallback) {
  if (v == null) return fallback;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return const {'true', '1', 'yes'}.contains(v.trim().toLowerCase());
  return fallback;
}

/// A JSON value the admin app may have stored as a string, parsed.
Object? _json(Object? v) {
  if (v is String) {
    try {
      return jsonDecode(v);
    } catch (_) {
      return null;
    }
  }
  return v;
}

/// A partner-type name as the apps compare them.
String partnerTypeNameKey(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '');

/// Country / state / city / suburb, blank for "any".
class RegionScope {
  const RegionScope({this.country = '', this.state = '', this.city = '', this.suburb = ''});

  factory RegionScope.fromJson(Object? raw) {
    if (raw is! Map) return const RegionScope();
    return RegionScope(
      country: _s(raw['country']),
      state: _s(raw['state']),
      city: _s(raw['city']),
      suburb: _s(raw['suburb']),
    );
  }

  final String country, state, city, suburb;

  static const all = RegionScope();

  bool get isAll => country.isEmpty && state.isEmpty && city.isEmpty && suburb.isEmpty;

  /// The levels it names, outermost first; a level below a blank one is
  /// ignored (the editor never leaves such a gap).
  List<String> get path {
    final out = <String>[];
    for (final l in [country, state, city, suburb]) {
      if (l.isEmpty) break;
      out.add(l);
    }
    return out;
  }

  /// How narrow it is: 0 for All regions, 4 for a suburb.
  int get rank => [country, state, city, suburb].where((l) => l.isNotEmpty).length;

  bool matches(RegionPlace p) =>
      (country.isEmpty || _norm(country) == _norm(p.country)) &&
      (state.isEmpty || _norm(state) == _norm(p.state)) &&
      (city.isEmpty || _norm(city) == _norm(p.city)) &&
      (suburb.isEmpty || _norm(suburb) == _norm(p.suburb));

  /// Its narrowest name, as the server words its reasons; null for All regions.
  String? get name => path.isEmpty ? null : path.last;

  /// "Ampang, Selangor, Malaysia" (narrowest first), or "All regions".
  String get label => isAll ? 'All regions' : path.reversed.join(', ');

  String get key => path.map(_norm).join('|');

  Map<String, dynamic> toJson() => {
        if (country.isNotEmpty) 'country': country,
        if (state.isNotEmpty) 'state': state,
        if (city.isNotEmpty) 'city': city,
        if (suburb.isNotEmpty) 'suburb': suburb,
      };

  @override
  bool operator ==(Object other) => other is RegionScope && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// "All regions" or a list of picked regions.
class RegionList {
  const RegionList({this.all = true, this.regions = const []});

  factory RegionList.fromJson(Object? raw) {
    if (raw is! Map) return const RegionList();
    final list = _json(raw['regions']);
    return RegionList(
      all: _flag(raw['all'], true),
      regions: [
        if (list is List)
          for (final r in list)
            if (r is Map) RegionScope.fromJson(r),
      ],
    );
  }

  final bool all;
  final List<RegionScope> regions;

  bool allows(RegionPlace p) => all || regions.any((r) => r.matches(p));

  /// The first picked region holding [p] (null with "All regions" or none).
  RegionScope? matchFor(RegionPlace p) => all ? null : regions.where((r) => r.matches(p)).firstOrNull;

  RegionList copyWith({bool? all, List<RegionScope>? regions}) =>
      RegionList(all: all ?? this.all, regions: regions ?? this.regions);

  Map<String, dynamic> toJson() => {'all': all, 'regions': [for (final r in regions) r.toJson()]};
}

/// "At most [maxYears] years old" in [scope].
class AgeRule {
  const AgeRule({this.scope = RegionScope.all, required this.maxYears});

  factory AgeRule.fromJson(Map raw) =>
      AgeRule(scope: RegionScope.fromJson(raw), maxYears: int.tryParse('${raw['maxYears'] ?? ''}') ?? 0);

  final RegionScope scope;
  final int maxYears;

  AgeRule copyWith({RegionScope? scope, int? maxYears}) =>
      AgeRule(scope: scope ?? this.scope, maxYears: maxYears ?? this.maxYears);

  Map<String, dynamic> toJson() => {...scope.toJson(), 'maxYears': maxYears};
}

/// One partner type's rules, as stored (before "Vehicle required" and the
/// defaults are applied: see [EffectiveTypeRules]).
class PartnerTypeRules {
  const PartnerTypeRules({
    this.ageRequired = false,
    this.ageRules = const [],
    this.permitRequired = false,
    this.permitRegions = const RegionList(),
    this.hailAllowed,
    this.hailRegions = const RegionList(),
    this.availability = const RegionList(),
  });

  /// Reads `values.rules` of a partner-type entry.
  factory PartnerTypeRules.fromValues(Map<String, dynamic> values) {
    final raw = _json(values['rules']);
    if (raw is! Map) return const PartnerTypeRules();
    Map m(Object? x) => x is Map ? x : const {};
    final age = m(raw['vehicleAge']);
    final permit = m(raw['permit']);
    final hail = m(raw['hail']);
    final ageList = _json(age['rules']);
    return PartnerTypeRules(
      ageRequired: _flag(age['required'], false),
      ageRules: [
        if (ageList is List)
          for (final r in ageList)
            if (r is Map) AgeRule.fromJson(r),
      ],
      permitRequired: _flag(permit['required'], false),
      permitRegions: RegionList.fromJson(permit),
      hailAllowed: hail.containsKey('allowed') ? _flag(hail['allowed'], false) : null,
      hailRegions: RegionList.fromJson(hail),
      availability: RegionList.fromJson(raw['availability']),
    );
  }

  final bool ageRequired;
  final List<AgeRule> ageRules;
  final bool permitRequired;
  final RegionList permitRegions;

  /// Null when never set: street hail then stays TEKSI's ([EffectiveTypeRules]).
  final bool? hailAllowed;
  final RegionList hailRegions;
  final RegionList availability;

  PartnerTypeRules copyWith({
    bool? ageRequired,
    List<AgeRule>? ageRules,
    bool? permitRequired,
    RegionList? permitRegions,
    bool? hailAllowed,
    RegionList? hailRegions,
    RegionList? availability,
  }) =>
      PartnerTypeRules(
        ageRequired: ageRequired ?? this.ageRequired,
        ageRules: ageRules ?? this.ageRules,
        permitRequired: permitRequired ?? this.permitRequired,
        permitRegions: permitRegions ?? this.permitRegions,
        hailAllowed: hailAllowed ?? this.hailAllowed,
        hailRegions: hailRegions ?? this.hailRegions,
        availability: availability ?? this.availability,
      );

  Map<String, dynamic> toJson() => {
        'vehicleAge': {'required': ageRequired, 'rules': [for (final r in ageRules) r.toJson()]},
        'permit': {'required': permitRequired, ...permitRegions.toJson()},
        'hail': {if (hailAllowed != null) 'allowed': hailAllowed, ...hailRegions.toJson()},
        'availability': availability.toJson(),
      };

  /// Why these rules can't be saved, or null. The vehicle rules are only
  /// checked when [vehicleRequired] (they are hidden otherwise).
  String? problem({required bool vehicleRequired}) {
    if (vehicleRequired) {
      if (ageRequired) {
        if (ageRules.isEmpty) return 'Add at least one vehicle age rule, or set the age limit to not required.';
        final seen = <String>{};
        for (final r in ageRules) {
          if (r.maxYears < minVehicleAgeYears || r.maxYears > maxVehicleAgeYears) {
            return 'A vehicle age limit is $minVehicleAgeYears to $maxVehicleAgeYears years.';
          }
          if (!seen.add(r.scope.key)) return 'Two vehicle age rules are for ${r.scope.label}. Keep one.';
        }
      }
      if (permitRequired && !permitRegions.all && permitRegions.regions.isEmpty) {
        return 'Pick the regions where a permit is required, or choose All regions.';
      }
      if ((hailAllowed ?? false) && !hailRegions.all && hailRegions.regions.isEmpty) {
        return 'Pick the regions where street hail is allowed, or choose All regions.';
      }
    }
    if (!availability.all && availability.regions.isEmpty) {
      return 'Pick the regions where this partner type is offered, or choose All regions.';
    }
    return null;
  }
}

/// A type's rules with "Vehicle required" and the defaults applied, as the
/// server's `partner_type_rules` gives them.
class EffectiveTypeRules {
  const EffectiveTypeRules({
    required this.name,
    required this.vehicleRequired,
    required this.rules,
  });

  /// [entries]' entry named [type] (by [partnerTypeNameKey]); a name with no
  /// entry has no rules.
  factory EffectiveTypeRules.of(String type, Iterable<Map<String, dynamic>> entries) {
    final key = partnerTypeNameKey(type);
    final v = entries.where((e) => partnerTypeNameKey(_s(e['name'])) == key).firstOrNull ?? const <String, dynamic>{};
    final vehicle = v.containsKey('vehicleRequired')
        ? _flag(v['vehicleRequired'], false)
        : const {'teksi', 'ehailing', 'phailing'}.contains(key);
    final name = _s(v['name']);
    return EffectiveTypeRules(
      name: name.isEmpty ? type.trim() : name,
      vehicleRequired: vehicle,
      rules: PartnerTypeRules.fromValues(v),
    );
  }

  final String name;
  final bool vehicleRequired;
  final PartnerTypeRules rules;

  bool get isTeksi => partnerTypeNameKey(name) == 'teksi';
  bool get ageRequired => vehicleRequired && rules.ageRequired;
  bool get permitRequired => vehicleRequired && rules.permitRequired;

  /// Street hail is on: as set, else TEKSI's alone.
  bool get hailOn => vehicleRequired ? (rules.hailAllowed ?? isTeksi) : isTeksi;

  bool availableAt(RegionPlace p) => rules.availability.allows(p);

  bool availableIn(ServiceArea area) => areaPlaces(area).any(availableAt);

  /// Street hail at [p]; a place that can't be told is not refused.
  bool hailAt(RegionPlace p) {
    if (!hailOn) return false;
    if (p.country.isEmpty) return true;
    return availableAt(p) && (!vehicleRequired || rules.hailRegions.allows(p));
  }

  /// The narrowest age rule at [p] (the lower limit on a tie), or null.
  AgeRule? ageRuleAt(RegionPlace p) {
    if (!ageRequired) return null;
    AgeRule? best;
    for (final r in rules.ageRules) {
      if (!r.scope.matches(p)) continue;
      if (best == null ||
          r.scope.rank > best.scope.rank ||
          (r.scope.rank == best.scope.rank && r.maxYears < best.maxYears)) {
        best = r;
      }
    }
    return best;
  }

  /// Where in [area] a permit is required ('' for All regions), or null.
  String? permitRegionIn(ServiceArea area) {
    if (!permitRequired) return null;
    if (rules.permitRegions.all) return '';
    for (final p in areaPlaces(area)) {
      final m = rules.permitRegions.matchFor(p);
      if (m != null) return m.name ?? '';
    }
    return null;
  }

  /// Why a vehicle of [year] can't be used for this type in [area], or null
  /// ([vehicleAgeProblem]).
  String? vehicleAgeProblem(String year, ServiceArea area, {DateTime? now, bool strict = true}) {
    AgeRule? worst;
    for (final p in areaPlaces(area)) {
      final r = ageRuleAt(p);
      if (r != null && (worst == null || r.maxYears < worst.maxYears)) worst = r;
    }
    if (worst == null) return null;
    final where = worst.scope.name == null ? '' : ' in ${worst.scope.name}';
    final y = int.tryParse(RegExp(r'\d{4}').firstMatch(year)?.group(0) ?? '');
    if (y == null) {
      return strict ? "Enter the vehicle's year: vehicles for $name$where must be at most ${worst.maxYears} years old." : null;
    }
    final age = (now ?? DateTime.now()).year - y;
    if (age <= worst.maxYears) return null;
    return 'Vehicles for $name$where must be at most ${worst.maxYears} years old (this one is $age).';
  }
}

/// The places of a service area, as the server's `ptr_area_places`: each
/// city, each state with none of its cities listed, each country with none
/// of its states listed; one blank place when the area is empty.
List<RegionPlace> areaPlaces(ServiceArea area) {
  List<String> parts(String k) => k.split('|').map((x) => x.trim()).toList();
  final out = <RegionPlace>[];
  final cityStates = <String>{};
  final stateCountries = <String>{};
  for (final c in area.cities) {
    final p = parts(c);
    if (p.length < 3 || p[2].isEmpty) continue;
    out.add((country: p[0], state: p[1], city: p[2], suburb: ''));
    cityStates.add('${_norm(p[0])}|${_norm(p[1])}');
    stateCountries.add(_norm(p[0]));
  }
  for (final s in area.states) {
    final p = parts(s);
    if (p.length < 2 || p[1].isEmpty) continue;
    stateCountries.add(_norm(p[0]));
    if (cityStates.contains('${_norm(p[0])}|${_norm(p[1])}')) continue;
    out.add((country: p[0], state: p[1], city: '', suburb: ''));
  }
  for (final c in area.countries) {
    if (c.trim().isEmpty || stateCountries.contains(_norm(c))) continue;
    out.add((country: c.trim(), state: '', city: '', suburb: ''));
  }
  return out.isEmpty ? const [unknownPlace] : out;
}

/// The partner type names offered somewhere in [area] (onboarding's type
/// step): [options] in their order, without those the admin limited to
/// other regions.
List<String> partnerTypesAvailableIn(
  List<String> options,
  Iterable<Map<String, dynamic>> entries,
  ServiceArea area,
) =>
    [for (final o in options) if (EffectiveTypeRules.of(o, entries).availableIn(area)) o];

/// Why a vehicle of [year] is refused for the partner's [types] in [area]:
/// null when one vehicle-required type takes it (or none needs a vehicle),
/// else the first type's reason. The server's `ptr_vehicle_fits_types`.
String? vehicleAgeProblem({
  required List<String> types,
  required String year,
  required ServiceArea area,
  required Iterable<Map<String, dynamic>> entries,
  DateTime? now,
  bool strict = true,
}) {
  String? first;
  for (final t in types) {
    if (t.trim().isEmpty) continue;
    final r = EffectiveTypeRules.of(t, entries);
    if (!r.vehicleRequired) continue;
    final why = r.vehicleAgeProblem(year, area, now: now, strict: strict);
    if (why == null) return null;
    first ??= why;
  }
  return first;
}

/// The partner's types that need a permit in [area] (with where), so the
/// permit document becomes compulsory.
List<({String type, String region})> permitRequirements(
  List<String> types,
  Iterable<Map<String, dynamic>> entries,
  ServiceArea area,
) =>
    [
      for (final t in types)
        if (EffectiveTypeRules.of(t, entries).permitRegionIn(area) case final where?)
          (type: EffectiveTypeRules.of(t, entries).name, region: where),
    ];

/// The server's verdict on working here (`partner_type_check`).
class PartnerTypeCheck {
  const PartnerTypeCheck({this.ok = true, this.reason, this.hail});

  factory PartnerTypeCheck.fromJson(Object? raw) {
    if (raw is! Map) return const PartnerTypeCheck();
    final reason = _s(raw['reason']);
    return PartnerTypeCheck(
      ok: _flag(raw['ok'], true),
      reason: reason.isEmpty ? null : reason,
      hail: raw['hail'] == null ? null : _flag(raw['hail'], true),
    );
  }

  /// Nothing known: let the driver through (the server still decides).
  static const unknown = PartnerTypeCheck();

  /// One of the driver's types for this mode may work here.
  final bool ok;
  final String? reason;

  /// Street hail is offered here for one of the driver's types; null when
  /// the caller is no partner (no opinion).
  final bool? hail;

  bool get hailBlocked => hail == false;
}

/// What the driver is told when the meter's street hail is refused here.
const hailNotOfferedMessage =
    'Street hail is not offered for your partner type here. Use the app for e-hailing jobs instead.';
