// Whether a service is offered at a place: Admin → Country / States /
// Cities → Services, each master service and each sub-service Inherit, On
// or Off per region. Pure; the server's twin is service_offered_at()
// (migration 0302), and both are tested on the same cases
// (test/region_service_switches_test.dart,
// supabase/tests/region_service_switches_0302.sql).
//
// What a region stores (its `values`), so apps from before keep working:
//
//   serviceSwitches  {id: 'on' | 'off'}  master services set here; missing
//                    is Inherit. New: only this says Off for a master.
//   subServices      {id: true | false}  sub-services set here; missing is
//                    Inherit (as before).
//   services         a JSON string of {id: true}, the master services on.
//                    Older apps read only this: "a region with a non-empty
//                    list offers only those". A region saved with switches
//                    keeps it as what is on there when it was saved.
//
// For each service the most specific region that says something about it
// decides (suburb, city, state, country); with none it is On. A region says
// something about an id when it sets it in serviceSwitches or subServices;
// a region from before switches (no serviceSwitches) with a non-empty
// services list says On for each master service in it and Off for every
// other one, as it always has.
//
// A service is offered when it and each sub-service above it is on, and,
// when it sits under master services, at least one of them is on.
import 'dart:convert';

/// One region's choice for one service.
enum ServiceSwitch {
  inherit('Inherit'),
  on('On'),
  off('Off');

  const ServiceSwitch(this.label);
  final String label;

  static ServiceSwitch of(bool? v) => v == null ? inherit : (v ? on : off);

  /// Null for [inherit].
  bool? get value => switch (this) {
    ServiceSwitch.inherit => null,
    ServiceSwitch.on => true,
    ServiceSwitch.off => false,
  };
}

Object? _decoded(Object? raw) {
  if (raw is! String) return raw;
  if (raw.trim().isEmpty) return null;
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}

/// A region's `serviceSwitches` (a map or a JSON string of `{id: 'on' |
/// 'off'}`) as `{id: true | false}`; anything else is Inherit.
Map<String, bool> parseServiceSwitches(Object? raw) {
  final j = _decoded(raw);
  if (j is! Map) return const {};
  return {
    for (final e in j.entries)
      if (e.value == 'on' || e.value == 'off') '${e.key}': e.value == 'on',
  };
}

/// `{id: true | false}` as stored in `serviceSwitches`.
Map<String, String> encodeServiceSwitches(Map<String, bool> m) => {
  for (final e in m.entries) e.key: e.value ? 'on' : 'off',
};

/// The ids a region's `services` list switches on (a map or a JSON string
/// of `{id: bool}`; true or a non-zero number is on); empty when none.
Set<String> parseServicesList(Object? raw) {
  final j = _decoded(raw);
  if (j is! Map) return const {};
  return {
    for (final e in j.entries)
      if (e.value == true || (e.value is num && e.value != 0)) '${e.key}',
  };
}

/// What one region says about services.
class ServiceSwitchLevel {
  const ServiceSwitchLevel({
    this.name = '',
    this.list = const {},
    this.switches = const {},
    this.subServices = const {},
  });

  /// From a region's `values`.
  factory ServiceSwitchLevel.fromValues(Map<String, dynamic> v, {String name = ''}) => ServiceSwitchLevel(
    name: name,
    list: parseServicesList(v['services']),
    switches: parseServiceSwitches(v['serviceSwitches']),
    subServices: _bools(v['subServices']),
  );

  static Map<String, bool> _bools(Object? raw) {
    final j = _decoded(raw);
    if (j is! Map) return const {};
    return {
      for (final e in j.entries)
        if (e.value is bool) '${e.key}': e.value as bool,
    };
  }

  /// The region's own name, for "On (from Selangor)".
  final String name;

  /// The master services its `services` list switches on.
  final Set<String> list;

  /// `serviceSwitches`: master services set On or Off here.
  final Map<String, bool> switches;

  /// `subServices`: sub-services set On or Off here.
  final Map<String, bool> subServices;

  /// Saved before switches: its non-empty list offers only those.
  bool get legacyList => switches.isEmpty && list.isNotEmpty;

  /// What it says about [id] (a master service when [master]): true, false,
  /// or null when it leaves it to the regions around it.
  bool? say(String id, {required bool master}) =>
      switches[id] ?? subServices[id] ?? (master && legacyList ? list.contains(id) : null);
}

/// The answer for one id: on or off, and which region decided ([level], an
/// index into the list asked about), null for the default (On).
class ServiceSwitchVerdict {
  const ServiceSwitchVerdict(this.on, [this.level]);
  final bool on;
  final int? level;
}

/// [id] at a place whose regions are [levels], most specific first.
ServiceSwitchVerdict resolveServiceSwitch(String id, List<ServiceSwitchLevel> levels, {required bool master}) {
  for (var i = 0; i < levels.length; i++) {
    final v = levels[i].say(id, master: master);
    if (v != null) return ServiceSwitchVerdict(v, i);
  }
  return const ServiceSwitchVerdict(true);
}

/// Whether a service whose [lineage] (itself, then everything above it,
/// nearest first) is offered at a place whose regions are [levels], most
/// specific first. [isMaster] tells the master services in the lineage.
bool serviceOffered(
  Iterable<String> lineage,
  List<ServiceSwitchLevel> levels, {
  required bool Function(String id) isMaster,
}) {
  final masters = <String>[];
  for (final id in lineage) {
    if (isMaster(id)) {
      masters.add(id);
    } else if (!resolveServiceSwitch(id, levels, master: false).on) {
      return false;
    }
  }
  return masters.isEmpty || masters.any((m) => resolveServiceSwitch(m, levels, master: true).on);
}

/// The `services` list older apps read for a region saved with switches:
/// the master services ([masters]) on there, given its own switches
/// ([own]) and the regions above it ([above], nearest first). Empty when
/// the region sets no master service, so older apps follow its parent.
Map<String, bool> servicesListForOlderApps(
  Iterable<String> masters,
  ServiceSwitchLevel own,
  List<ServiceSwitchLevel> above,
) {
  if (own.switches.isEmpty) return const {};
  final levels = [own, ...above];
  return {
    for (final m in masters)
      if (resolveServiceSwitch(m, levels, master: true).on) m: true,
  };
}

/// The server's refusal of a booking whose service is off at its pickup
/// (SERVICE_NOT_OFFERED_HERE, migration 0302, in Refuse mode): the modal's
/// title ("Premium isn't offered here") and the reason; null for any other
/// error. [service] names it when the reason can't be read.
({String title, String message})? serviceNotOfferedOf(Object e, {String? service}) {
  final s = '$e';
  if (!s.contains('SERVICE_NOT_OFFERED_HERE')) return null;
  // PostgrestException(message: ..., code: ..., details: ..., hint: <reason>)
  final hint = RegExp(r'hint: (.+)\)$', dotAll: true).firstMatch(s.trim())?.group(1)?.trim();
  final reason = hint != null && hint.contains("isn't offered") ? hint : null;
  final named = reason == null ? null : RegExp(r"^(.+?) isn't offered").firstMatch(reason)?.group(1)?.trim();
  final name = named ?? ((service ?? '').trim().isEmpty ? 'This service' : service!.trim());
  return (
    title: "$name isn't offered here",
    message: reason ?? "$name isn't offered for pickups here. Choose another service for this trip.",
  );
}
