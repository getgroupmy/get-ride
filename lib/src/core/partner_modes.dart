/// Admin → Partner Type in the driver app (Expo `utils/partnerModeOptions`):
/// which service modes a partner can enter, as the admin describes them, and
/// whether a mode needs a vehicle first. Pure.
library;

typedef PartnerTypeEntry = ({String id, Map<String, dynamic> values});

/// Modes that need a vehicle when the admin's entry says nothing either way;
/// an explicit "Vehicle required" on the entry always wins.
const defaultVehicleModes = {'teksi', 'ehailing', 'phailing'};

/// "Vehicle required" for a partner type named [name] whose entry says
/// nothing: on for [defaultVehicleModes]. The one default for the driver
/// app, the admin's Partner Type editor and partner form, and the server
/// (0245 `partner_type_rules`).
bool defaultVehicleRequired(String name) => defaultVehicleModes.contains(_key(name));

/// "Vehicle required" for the partner type named [name] with the catalogue
/// [values] (null: no entry): the admin's switch when set, else the default.
bool typeVehicleRequired(String name, Map<String, dynamic>? values) =>
    values != null && values.containsKey('vehicleRequired')
        ? _truthy(values['vehicleRequired'])
        : defaultVehicleRequired(name);

/// Whether [mode] (a partner-type name) needs a vehicle before it starts.
bool vehicleRequiredFor(String mode, List<PartnerTypeEntry> entries) {
  final key = _key(mode);
  final entry = entries.where((e) => _key('${e.values['name'] ?? ''}') == key).firstOrNull;
  return typeVehicleRequired(mode, entry?.values);
}

/// Whether the partner's modes ([assigned], their `partner_types`) need a
/// vehicle: the meter's for [teksi] true, the ride modes' for false, any
/// for null. No mode: as a plain e-hailing (or taxi) partner.
bool modesNeedVehicle(Iterable<Object?> assigned, List<PartnerTypeEntry> entries, {bool? teksi}) {
  final modes = [
    for (final m in partnerModeOptions(assigned, entries))
      if (teksi == null || m.isTeksi == teksi) m.name,
  ];
  return (modes.isEmpty ? [teksi == true ? 'teksi' : 'ehailing'] : modes).any((m) => vehicleRequiredFor(m, entries));
}

/// A mode the partner can enter: one of their assigned types, with the
/// admin's description and icon.
class PartnerModeOption {
  const PartnerModeOption({required this.name, this.description, this.iconUrl});
  final String name;
  final String? description;
  final String? iconUrl;

  /// TEKSI is the metered taxi; every other type takes ride requests.
  bool get isTeksi => _key(name) == 'teksi';
}

/// [assigned] (the partner's `partner_types`) as options: a type the admin
/// switched off is dropped, the rest ordered by the admin's display
/// priority; a type with no catalogue entry is kept, last.
List<PartnerModeOption> partnerModeOptions(Iterable<Object?> assigned, List<PartnerTypeEntry> entries) {
  final byName = {for (final e in entries) _key('${e.values['name'] ?? ''}'): e.values};
  final seen = <String>{};
  final out = <(PartnerModeOption, double, int)>[];
  for (final raw in assigned) {
    final name = '${raw ?? ''}'.trim();
    if (name.isEmpty || !seen.add(_key(name))) continue;
    final v = byName[_key(name)];
    if (v != null && v['enabled'] != null && !_truthy(v['enabled'])) continue;
    String? s(Object? x) => x is String && x.trim().isNotEmpty ? x.trim() : null;
    final p = v == null ? null : double.tryParse('${v['displayPriority'] ?? ''}');
    out.add((
      PartnerModeOption(
        name: name,
        description: v == null ? null : s(v['shortInfo']) ?? s(v['description']),
        iconUrl: v == null ? null : s(v['iconUrl']),
      ),
      p ?? double.infinity,
      out.length,
    ));
  }
  out.sort((a, b) => a.$2 != b.$2 ? a.$2.compareTo(b.$2) : a.$3.compareTo(b.$3));
  return [for (final o in out) o.$1];
}

String _key(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '');

bool _truthy(Object? v) => v == true || v == 1 || (v is String && const {'true', '1', 'yes'}.contains(v.toLowerCase()));
