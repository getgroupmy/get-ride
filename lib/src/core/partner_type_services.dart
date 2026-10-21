/// Partner type services (migrations 0257, 0259): per partner type, the ride
/// services (`ride_requests.service`, the Vehicle Services names) its
/// partners see in open requests. The same rule as the database's
/// `partner_type_allows_service` / `caller_partner_service_ok`, for the
/// admin page's "Who sees this request?". Pure.
library;

import 'partner_type_rules.dart' show partnerTypeNameKey;

/// A type or service name as the database compares them (`ptr_key`): no
/// case, spaces, `_` or `-`.
String partnerServiceKey(String s) => partnerTypeNameKey(s);

/// One `partner_type_services` row.
class PartnerTypeServiceRule {
  const PartnerTypeServiceRule({
    required this.typeKey,
    required this.typeName,
    this.allServices = true,
    this.services = const [],
    this.note = '',
    this.updatedAt,
    this.updatedBy,
  });

  factory PartnerTypeServiceRule.fromRow(Map<String, dynamic> r) {
    final key = '${r['type_key'] ?? ''}'.trim();
    final name = '${r['type_name'] ?? ''}'.trim();
    return PartnerTypeServiceRule(
      typeKey: key,
      typeName: name.isEmpty ? key : name,
      allServices: r['all_services'] != false,
      services: [
        for (final s in (r['services'] is List ? r['services'] as List : const []))
          if ('${s ?? ''}'.trim().isNotEmpty) '$s'.trim(),
      ],
      note: '${r['note'] ?? ''}'.trim(),
      updatedAt: DateTime.tryParse('${r['updated_at'] ?? ''}'),
      updatedBy: r['updated_by'] as String?,
    );
  }

  /// `ptr_key` of the type's name.
  final String typeKey;
  final String typeName;

  /// Sees every service, including ones added later.
  final bool allServices;
  final List<String> services;
  final String note;
  final DateTime? updatedAt;
  final String? updatedBy;

  /// Whether partners of this type see [service].
  bool allows(String service) {
    if (allServices) return true;
    final k = partnerServiceKey(service);
    return services.any((s) => partnerServiceKey(s) == k);
  }

  /// The row as written (the server stamps updated_at / updated_by).
  Map<String, dynamic> toRow() => {
        'type_key': typeKey,
        'type_name': typeName.trim(),
        'all_services': allServices,
        'services': services,
        'note': note.trim().isEmpty ? null : note.trim(),
      };
}

/// The rules by key.
Map<String, PartnerTypeServiceRule> rulesByKey(Iterable<PartnerTypeServiceRule> rules) =>
    {for (final r in rules) r.typeKey: r};

/// Whether partners of [type] see [service]: its rule, or every service
/// when the type has none (`partner_type_allows_service`).
bool partnerTypeAllowsService(Map<String, PartnerTypeServiceRule> rules, String type, String service) =>
    rules[partnerServiceKey(type)]?.allows(service) ?? true;

/// Whether a partner with [types] sees an open request for [service]: a
/// blank service, no types, or any type allowing it
/// (`caller_partner_service_ok`).
bool partnerSeesService(Map<String, PartnerTypeServiceRule> rules, Iterable<String> types, String service) {
  if (service.trim().isEmpty) return true;
  final list = [for (final t in types) if (t.trim().isNotEmpty) t.trim()];
  if (list.isEmpty) return true;
  return list.any((t) => partnerTypeAllowsService(rules, t, service));
}

/// The pill on a type: "All", or "N of M" of the [total] services.
String ruleCountLabel(PartnerTypeServiceRule r, int total) =>
    r.allServices ? 'All' : '${r.services.length} of $total';

/// The services a type sees, in words.
String ruleSummary(PartnerTypeServiceRule r) =>
    r.allServices ? 'All services' : (r.services.isEmpty ? 'No services' : r.services.join(', '));

/// The services to tick: the catalogue's, then any a rule names that the
/// catalogue no longer has (so it can still be unticked). One per key.
List<String> serviceChoices(Iterable<String> catalogue, Iterable<PartnerTypeServiceRule> rules) {
  final seen = <String>{};
  final out = <String>[];
  for (final s in [...catalogue, for (final r in rules) ...r.services]) {
    final name = s.trim();
    if (name.isNotEmpty && seen.add(partnerServiceKey(name))) out.add(name);
  }
  return out;
}

/// The partner types from [names] that have no rule yet, one per key.
List<String> typesWithoutRule(Iterable<String> names, Iterable<PartnerTypeServiceRule> rules) {
  final taken = {for (final r in rules) r.typeKey};
  final out = <String>[];
  for (final n in names) {
    final name = n.trim();
    final k = partnerServiceKey(name);
    if (k.isNotEmpty && taken.add(k)) out.add(name);
  }
  return out;
}

/// Whether [r] matches what was typed in the list's search: its name, key,
/// note or a service.
bool ruleMatches(PartnerTypeServiceRule r, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return r.typeName.toLowerCase().contains(q) ||
      (partnerServiceKey(q).isNotEmpty && r.typeKey.contains(partnerServiceKey(q))) ||
      r.note.toLowerCase().contains(q) ||
      r.services.any((s) => s.toLowerCase().contains(q));
}
