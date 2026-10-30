/// Admin → Settings → Partner Service type rules (migration 0245): a vehicle
/// age limit, a permit requirement, street hail, and where the type is
/// offered, each by region. Kept in the type's entry as `values.rules`; the
/// server (`partner_type_rules`, `ptr_*`) reads the same shape and has the
/// last word. Pure.
///
/// The partner registration settings ([PartnerServiceSettings]: citizens
/// only, business registration, driver and vehicle permits, whose age limits
/// a type's limit covers) sit beside them as top-level keys of `values`, and
/// the helpers at the end of the file ([citizensOnlyTypes],
/// [needsBusinessRegistration], [driverPermitFor], [vehiclePermitFor],
/// [effectiveMaxVehicleAge]) answer for a service area what registration
/// asks.
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
import 'partner_modes.dart' show defaultVehicleRequired;

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
    this.mygigAllowed = false,
    this.mygigRegions = const RegionList(),
  });

  /// Reads `values.rules` of a partner-type entry.
  factory PartnerTypeRules.fromValues(Map<String, dynamic> values) {
    final raw = _json(values['rules']);
    if (raw is! Map) return const PartnerTypeRules();
    Map m(Object? x) => x is Map ? x : const {};
    final age = m(raw['vehicleAge']);
    final permit = m(raw['permit']);
    final hail = m(raw['hail']);
    final mygig = m(raw['mygig']);
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
      mygigAllowed: _flag(mygig['allowed'], false),
      mygigRegions: RegionList.fromJson(mygig),
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

  /// myGiG (0329): a street hail with a price agreed in the app, for a type
  /// that isn't TEKSI. Off until the admin turns it on; where it is offered.
  final bool mygigAllowed;
  final RegionList mygigRegions;

  PartnerTypeRules copyWith({
    bool? ageRequired,
    List<AgeRule>? ageRules,
    bool? permitRequired,
    RegionList? permitRegions,
    bool? hailAllowed,
    RegionList? hailRegions,
    RegionList? availability,
    bool? mygigAllowed,
    RegionList? mygigRegions,
  }) =>
      PartnerTypeRules(
        ageRequired: ageRequired ?? this.ageRequired,
        ageRules: ageRules ?? this.ageRules,
        permitRequired: permitRequired ?? this.permitRequired,
        permitRegions: permitRegions ?? this.permitRegions,
        hailAllowed: hailAllowed ?? this.hailAllowed,
        hailRegions: hailRegions ?? this.hailRegions,
        availability: availability ?? this.availability,
        mygigAllowed: mygigAllowed ?? this.mygigAllowed,
        mygigRegions: mygigRegions ?? this.mygigRegions,
      );

  Map<String, dynamic> toJson() => {
        'vehicleAge': {'required': ageRequired, 'rules': [for (final r in ageRules) r.toJson()]},
        'permit': {'required': permitRequired, ...permitRegions.toJson()},
        'hail': {if (hailAllowed != null) 'allowed': hailAllowed, ...hailRegions.toJson()},
        'availability': availability.toJson(),
        'mygig': {'allowed': mygigAllowed, ...mygigRegions.toJson()},
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
      return 'Pick the regions where this Partner Service type is offered, or choose All regions.';
    }
    if (mygigAllowed && !mygigRegions.all && mygigRegions.regions.isEmpty) {
      return 'Pick the regions where myGiG is allowed, or choose All regions.';
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
    this.settings = const PartnerServiceSettings(),
  });

  /// [entries]' entry named [type] (by [partnerTypeNameKey]); a name with no
  /// entry has no rules.
  factory EffectiveTypeRules.of(String type, Iterable<Map<String, dynamic>> entries) {
    final key = partnerTypeNameKey(type);
    final v = entries.where((e) => partnerTypeNameKey(_s(e['name'])) == key).firstOrNull ?? const <String, dynamic>{};
    final vehicle = v.containsKey('vehicleRequired') ? _flag(v['vehicleRequired'], false) : defaultVehicleRequired(key);
    final name = _s(v['name']);
    return EffectiveTypeRules(
      name: name.isEmpty ? type.trim() : name,
      vehicleRequired: vehicle,
      rules: PartnerTypeRules.fromValues(v),
      settings: PartnerServiceSettings.fromValues(v),
    );
  }

  final String name;
  final bool vehicleRequired;
  final PartnerTypeRules rules;

  /// Citizens only, business registration, permits and age-limit cover.
  final PartnerServiceSettings settings;

  String get key => partnerTypeNameKey(name);

  bool get isTeksi => partnerTypeNameKey(name) == 'teksi';
  bool get ageRequired => vehicleRequired && rules.ageRequired;
  bool get permitRequired => vehicleRequired && rules.permitRequired;

  /// Street hail is on: as set, else TEKSI's alone.
  bool get hailOn => vehicleRequired ? (rules.hailAllowed ?? isTeksi) : isTeksi;

  bool availableAt(RegionPlace p) => rules.availability.allows(p);

  /// myGiG (0329) is on for this type: as set, never TEKSI (it has the meter).
  bool get mygigOn => !isTeksi && rules.mygigAllowed;

  /// myGiG at [p]; a place that can't be told is not refused (the server's
  /// mygig_type_ok).
  bool mygigAt(RegionPlace p) => mygigOn && (p.country.isEmpty || rules.mygigRegions.allows(p));

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
    'Street hail is not offered for your Partner Service type here. Use the app for e-hailing jobs instead.';

// ---------------------------------------------------------------------------
// Partner registration settings (Admin → Partner Service type editor)
// ---------------------------------------------------------------------------

List<String> _names(Object? raw) {
  final v = _json(raw);
  if (v is! List) return const [];
  final out = <String>[];
  final seen = <String>{};
  for (final x in v) {
    final s = _s(x);
    if (s.isNotEmpty && seen.add(partnerTypeNameKey(s))) out.add(s);
  }
  return out;
}

bool _sameType(String a, String b) => partnerTypeNameKey(a) == partnerTypeNameKey(b);

/// A switch that holds in some regions: `{"required": bool, "all": bool,
/// "regions": [...]}` (the shape of the permit rule in `values.rules`).
class RegionRequirement {
  const RegionRequirement({this.required = false, this.where = const RegionList()});

  factory RegionRequirement.fromJson(Object? raw) {
    final m = _json(raw);
    if (m is! Map) return const RegionRequirement();
    return RegionRequirement(required: _flag(m['required'], false), where: RegionList.fromJson(m));
  }

  final bool required;
  final RegionList where;

  bool appliesAt(RegionPlace p) => required && where.allows(p);

  /// Where in [area] it holds: the region's narrowest name ('' for All
  /// regions), or null when it holds nowhere there.
  String? regionIn(ServiceArea area) {
    if (!required) return null;
    if (where.all) return '';
    for (final p in areaPlaces(area)) {
      final m = where.matchFor(p);
      if (m != null) return m.name ?? '';
    }
    return null;
  }

  RegionRequirement copyWith({bool? required, RegionList? where}) =>
      RegionRequirement(required: required ?? this.required, where: where ?? this.where);

  Map<String, dynamic> toJson() => {'required': required, ...where.toJson()};
}

/// One region's permit: its name and issuer ("Kad Pemandu", "APAD") and,
/// when picked from Admin → Vehicle permits → Permit types, that type's key.
class PermitRule {
  const PermitRule({this.scope = RegionScope.all, this.name = '', this.issuer = '', this.permitType = ''});

  factory PermitRule.fromJson(Map raw) => PermitRule(
        scope: RegionScope.fromJson(raw),
        name: _s(raw['name']),
        issuer: _s(raw['issuer']),
        permitType: _s(raw['permitType']),
      );

  final RegionScope scope;
  final String name;
  final String issuer;

  /// `permit_types.key` in the scope's country ('' when typed by hand).
  final String permitType;

  /// "Kad Pemandu (APAD)".
  String get label => issuer.isEmpty ? name : '$name ($issuer)';

  PermitRule copyWith({RegionScope? scope, String? name, String? issuer, String? permitType}) => PermitRule(
        scope: scope ?? this.scope,
        name: name ?? this.name,
        issuer: issuer ?? this.issuer,
        permitType: permitType ?? this.permitType,
      );

  Map<String, dynamic> toJson() => {
        ...scope.toJson(),
        'name': name.trim(),
        if (issuer.trim().isNotEmpty) 'issuer': issuer.trim(),
        if (permitType.trim().isNotEmpty) 'permitType': permitType.trim(),
      };
}

/// A permit required in some regions, named per region:
/// `{"required": bool, "rules": [{country, state, ..., name, issuer, permitType}]}`.
class PermitRequirement {
  const PermitRequirement({this.required = false, this.rules = const []});

  factory PermitRequirement.fromJson(Object? raw) {
    final m = _json(raw);
    if (m is! Map) return const PermitRequirement();
    final list = _json(m['rules']);
    return PermitRequirement(
      required: _flag(m['required'], false),
      rules: [
        if (list is List)
          for (final r in list)
            if (r is Map) PermitRule.fromJson(r),
      ],
    );
  }

  final bool required;
  final List<PermitRule> rules;

  /// The narrowest rule holding [p] (the first on a tie), or null.
  PermitRule? ruleAt(RegionPlace p) {
    if (!required) return null;
    PermitRule? best;
    for (final r in rules) {
      if (r.scope.matches(p) && (best == null || r.scope.rank > best.scope.rank)) best = r;
    }
    return best;
  }

  /// The first place of [area] (in [areaPlaces] order) that needs a permit,
  /// with its rule.
  PermitRule? ruleIn(ServiceArea area) {
    for (final p in areaPlaces(area)) {
      final r = ruleAt(p);
      if (r != null) return r;
    }
    return null;
  }

  PermitRequirement copyWith({bool? required, List<PermitRule>? rules}) =>
      PermitRequirement(required: required ?? this.required, rules: rules ?? this.rules);

  Map<String, dynamic> toJson() => {'required': required, 'rules': [for (final r in rules) r.toJson()]};

  String? problem(String what) {
    if (!required) return null;
    if (rules.isEmpty) return 'Add at least one region for the $what, or turn it off.';
    final seen = <String>{};
    for (final r in rules) {
      if (r.name.trim().isEmpty) return 'Name the $what for ${r.scope.label}.';
      if (!seen.add(r.scope.key)) return 'Two $what rules are for ${r.scope.label}. Keep one.';
    }
    return null;
  }
}

/// In [scope], this type's max vehicle age replaces the limit of [types]
/// for a vehicle registered for this type (a taxi's 20 years covers
/// eHailing's 15).
class AgeCoverRule {
  const AgeCoverRule({this.scope = RegionScope.all, this.types = const []});

  factory AgeCoverRule.fromJson(Map raw) => AgeCoverRule(scope: RegionScope.fromJson(raw), types: _names(raw['types']));

  final RegionScope scope;
  final List<String> types;

  bool covers(String type) => types.any((t) => _sameType(t, type));

  AgeCoverRule copyWith({RegionScope? scope, List<String>? types}) =>
      AgeCoverRule(scope: scope ?? this.scope, types: types ?? this.types);

  Map<String, dynamic> toJson() => {...scope.toJson(), 'types': types};
}

/// A Partner Service type's registration settings, kept as top-level keys
/// of its `values` (next to `vehicleRequired` and `rules`):
///
/// * `citizensOnly`: where only citizens may join ([RegionRequirement]).
/// * `businessRegistration`: where a registered business is required.
/// * `driverPermit`: where the driver needs a permit, and its name and
///   issuer per region ([PermitRequirement]).
/// * `vehiclePermit`: where each vehicle needs a permit, uploaded by GET.ride
///   or the admin in Vehicle permits (never by the driver). Vehicle services
///   only.
/// * `vehiclePermitAlsoFor`: the other types whose vehicles need that permit
///   when doing this service (a taxi doing eHailing).
/// * `ageLimitCovers`: per region, the other types whose max vehicle age this
///   type's limit (`rules.vehicleAge`) replaces for a vehicle registered for
///   this type.
///
/// Missing keys are "off": nothing changes for a type never edited.
class PartnerServiceSettings {
  const PartnerServiceSettings({
    this.citizensOnly = const RegionRequirement(),
    this.businessRegistration = const RegionRequirement(),
    this.driverPermit = const PermitRequirement(),
    this.vehiclePermit = const PermitRequirement(),
    this.vehiclePermitAlsoFor = const [],
    this.ageLimitCovers = const [],
  });

  factory PartnerServiceSettings.fromValues(Map<String, dynamic> values) {
    final covers = _json(values['ageLimitCovers']);
    return PartnerServiceSettings(
      citizensOnly: RegionRequirement.fromJson(values['citizensOnly']),
      businessRegistration: RegionRequirement.fromJson(values['businessRegistration']),
      driverPermit: PermitRequirement.fromJson(values['driverPermit']),
      vehiclePermit: PermitRequirement.fromJson(values['vehiclePermit']),
      vehiclePermitAlsoFor: _names(values['vehiclePermitAlsoFor']),
      ageLimitCovers: [
        if (covers is List)
          for (final r in covers)
            if (r is Map) AgeCoverRule.fromJson(r),
      ],
    );
  }

  /// The `values` keys these settings are kept under.
  static const keys = [
    'citizensOnly',
    'businessRegistration',
    'driverPermit',
    'vehiclePermit',
    'vehiclePermitAlsoFor',
    'ageLimitCovers',
  ];

  final RegionRequirement citizensOnly;
  final RegionRequirement businessRegistration;
  final PermitRequirement driverPermit;
  final PermitRequirement vehiclePermit;
  final List<String> vehiclePermitAlsoFor;
  final List<AgeCoverRule> ageLimitCovers;

  PartnerServiceSettings copyWith({
    RegionRequirement? citizensOnly,
    RegionRequirement? businessRegistration,
    PermitRequirement? driverPermit,
    PermitRequirement? vehiclePermit,
    List<String>? vehiclePermitAlsoFor,
    List<AgeCoverRule>? ageLimitCovers,
  }) =>
      PartnerServiceSettings(
        citizensOnly: citizensOnly ?? this.citizensOnly,
        businessRegistration: businessRegistration ?? this.businessRegistration,
        driverPermit: driverPermit ?? this.driverPermit,
        vehiclePermit: vehiclePermit ?? this.vehiclePermit,
        vehiclePermitAlsoFor: vehiclePermitAlsoFor ?? this.vehiclePermitAlsoFor,
        ageLimitCovers: ageLimitCovers ?? this.ageLimitCovers,
      );

  /// The `values` keys to write.
  Map<String, dynamic> toValues() => {
        'citizensOnly': citizensOnly.toJson(),
        'businessRegistration': businessRegistration.toJson(),
        'driverPermit': driverPermit.toJson(),
        'vehiclePermit': vehiclePermit.toJson(),
        'vehiclePermitAlsoFor': vehiclePermitAlsoFor,
        'ageLimitCovers': [for (final r in ageLimitCovers) r.toJson()],
      };

  /// Why these settings can't be saved, or null. The vehicle settings are
  /// only checked for a vehicle service, and the age cover only with the age
  /// limit on (they are hidden otherwise).
  String? problem({required bool vehicleRequired, required bool ageRequired}) {
    if (citizensOnly.required && !citizensOnly.where.all && citizensOnly.where.regions.isEmpty) {
      return 'Pick the regions where only citizens may join, or choose All regions.';
    }
    if (businessRegistration.required &&
        !businessRegistration.where.all &&
        businessRegistration.where.regions.isEmpty) {
      return 'Pick the regions where a registered business is required, or choose All regions.';
    }
    final driver = driverPermit.problem('driver permit');
    if (driver != null) return driver;
    if (vehicleRequired) {
      final vehicle = vehiclePermit.problem('vehicle permit');
      if (vehicle != null) return vehicle;
      if (ageRequired) {
        final seen = <String>{};
        for (final r in ageLimitCovers) {
          if (r.types.isEmpty) return 'Pick the Partner Service types the age limit covers in ${r.scope.label}.';
          if (!seen.add(r.scope.key)) return 'Two age limit cover rules are for ${r.scope.label}. Keep one.';
        }
      }
    }
    return null;
  }
}

/// A permit registration needs: for [type], named [name] by [issuer]
/// ([permitType] when picked from the permit types), required in [region]
/// ('' for All regions).
typedef PermitNeed = ({String type, String name, String issuer, String permitType, String region});

PermitNeed _need(String type, PermitRule r) =>
    (type: type, name: r.name, issuer: r.issuer, permitType: r.permitType, region: r.scope.name ?? '');

/// Of [types], those only citizens may join somewhere in [area] (in
/// [types]' order, as the entries name them). Registration's disclaimer
/// lists them; the rest are open to everyone ([openToEveryoneTypes]).
List<String> citizensOnlyTypes(List<String> types, Iterable<Map<String, dynamic>> entries, ServiceArea area) => [
      for (final t in types)
        if (t.trim().isNotEmpty)
          if (EffectiveTypeRules.of(t, entries) case final r when r.settings.citizensOnly.regionIn(area) != null) r.name,
    ];

/// Of [types], those anyone may join in [area].
List<String> openToEveryoneTypes(List<String> types, Iterable<Map<String, dynamic>> entries, ServiceArea area) {
  final only = {for (final t in citizensOnlyTypes(types, entries, area)) partnerTypeNameKey(t)};
  return [
    for (final t in types)
      if (t.trim().isNotEmpty && !only.contains(partnerTypeNameKey(t))) EffectiveTypeRules.of(t, entries).name,
  ];
}

/// Of [types], those that need a registered business somewhere in [area].
List<String> businessRegistrationTypes(
  List<String> types,
  Iterable<Map<String, dynamic>> entries,
  ServiceArea area,
) =>
    [
      for (final t in types)
        if (t.trim().isNotEmpty)
          if (EffectiveTypeRules.of(t, entries) case final r when r.settings.businessRegistration.regionIn(area) != null)
            r.name,
    ];

/// Whether one of [types] needs a registered business in [area] (the "Your
/// company" step).
bool needsBusinessRegistration(List<String> types, Iterable<Map<String, dynamic>> entries, ServiceArea area) =>
    businessRegistrationTypes(types, entries, area).isNotEmpty;

/// The driver permits [types] need in [area], one per permit (a permit two
/// types need is listed once, under the first).
List<PermitNeed> driverPermitFor(List<String> types, Iterable<Map<String, dynamic>> entries, ServiceArea area) {
  final out = <PermitNeed>[];
  final seen = <String>{};
  for (final t in types) {
    if (t.trim().isEmpty) continue;
    final r = EffectiveTypeRules.of(t, entries);
    final rule = r.settings.driverPermit.ruleIn(area);
    if (rule == null) continue;
    final id = rule.permitType.isNotEmpty ? 'k:${rule.permitType.toLowerCase()}' : 'n:${_norm(rule.name)}';
    if (seen.add(id)) out.add(_need(r.name, rule));
  }
  return out;
}

/// The vehicle permit a vehicle registered for [vehicleTypes] needs to do
/// [service] in [area], or null. It is needed when [service] is a vehicle
/// service requiring one there and the vehicle is registered for [service]
/// itself, for a type in its `vehiclePermitAlsoFor` (a taxi doing eHailing),
/// or for no type yet. Uploaded by GET.ride or the admin, never the driver;
/// the service stays off for that vehicle until it is.
PermitNeed? vehiclePermitFor(
  String service,
  List<String> vehicleTypes,
  Iterable<Map<String, dynamic>> entries,
  ServiceArea area,
) {
  if (service.trim().isEmpty) return null;
  final r = EffectiveTypeRules.of(service, entries);
  if (!r.vehicleRequired) return null;
  final rule = r.settings.vehiclePermit.ruleIn(area);
  if (rule == null) return null;
  final registered = [for (final t in vehicleTypes) if (t.trim().isNotEmpty) t];
  final applies = registered.isEmpty ||
      registered.any((t) => _sameType(t, service) || r.settings.vehiclePermitAlsoFor.any((a) => _sameType(a, t)));
  return applies ? _need(r.name, rule) : null;
}

/// The age limit a vehicle meets for a service: at most [maxYears] years,
/// set by [type]'s rule ([type] is the service itself, or the vehicle's
/// registered type whose limit covers it) for [region] ('' for All regions).
typedef VehicleAgeLimit = ({int maxYears, String type, String region});

/// The max age of a vehicle registered for [vehicleTypes] doing [service] in
/// [area], or null when there is no limit. At each place the service's own
/// limit holds, unless a registered type covers the service there
/// (`ageLimitCovers`) and has a limit of its own there: that limit replaces
/// it (the largest when several cover it). A service with no limit at a
/// place has none, covered or not. Over the area, the lowest place wins, as
/// [EffectiveTypeRules.vehicleAgeProblem] does.
VehicleAgeLimit? effectiveMaxVehicleAge(
  String service,
  List<String> vehicleTypes,
  Iterable<Map<String, dynamic>> entries,
  ServiceArea area,
) {
  if (service.trim().isEmpty) return null;
  final s = EffectiveTypeRules.of(service, entries);
  final covering = [
    for (final t in vehicleTypes)
      if (t.trim().isNotEmpty && !_sameType(t, service)) EffectiveTypeRules.of(t, entries),
  ];
  VehicleAgeLimit? worst;
  for (final p in areaPlaces(area)) {
    final own = s.ageRuleAt(p);
    if (own == null) continue;
    VehicleAgeLimit at = (maxYears: own.maxYears, type: s.name, region: own.scope.name ?? '');
    VehicleAgeLimit? cover;
    for (final c in covering) {
      if (!c.vehicleRequired) continue;
      final rule = coverRuleAt(c.settings.ageLimitCovers, p);
      if (rule == null || !rule.covers(service)) continue;
      final limit = c.ageRuleAt(p);
      if (limit == null) continue;
      if (cover == null || limit.maxYears > cover.maxYears) {
        cover = (maxYears: limit.maxYears, type: c.name, region: limit.scope.name ?? '');
      }
    }
    if (cover != null) at = cover;
    if (worst == null || at.maxYears < worst.maxYears) worst = at;
  }
  return worst;
}

/// The narrowest of [rules] holding [p], or null.
AgeCoverRule? coverRuleAt(List<AgeCoverRule> rules, RegionPlace p) {
  AgeCoverRule? best;
  for (final r in rules) {
    if (r.scope.matches(p) && (best == null || r.scope.rank > best.scope.rank)) best = r;
  }
  return best;
}

/// Whole years from [registered] to [now] (a vehicle registered 1 Nov 2010
/// is 15 on 31 Oct 2026 and 16 on 1 Nov 2026).
int vehicleAgeYears(DateTime registered, {DateTime? now}) {
  final n = now ?? DateTime.now();
  var years = n.year - registered.year;
  if (n.month < registered.month || (n.month == registered.month && n.day < registered.day)) years--;
  return years < 0 ? 0 : years;
}

/// Whether a vehicle registered on [registered] is over [limit] on [now]:
/// it may work until the day it turns `maxYears + 1`.
bool overVehicleAgeLimit(DateTime registered, VehicleAgeLimit limit, {DateTime? now}) =>
    vehicleAgeYears(registered, now: now) > limit.maxYears;
