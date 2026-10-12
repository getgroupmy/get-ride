/// Finding a person by name, phone, email, account id or exact profile id
/// (Expo's commission user search). Pure, so the filter the database sees
/// is tested without one.
library;

final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', caseSensitive: false);

/// Whether [s] is a profile id, which is looked up exactly.
bool isProfileUuid(String s) => _uuid.hasMatch(s.trim());

/// A search term safe inside a PostgREST `or=(…ilike.*term*…)` filter: the
/// characters that filter grammar reserves (`,()*:%\"`) are dropped, not
/// escaped. Null when fewer than two characters are left to search on.
String? peopleSearchTerm(String raw) {
  final t = raw.replaceAll(RegExp(r'[,()*:%\\"]'), ' ').trim().replaceAll(RegExp(r'\s+'), ' ');
  return t.length < 2 ? null : t;
}

/// The `.or()` filter for a sanitised [term]. Phone numbers are matched on
/// their digits, so "+60 12-345" finds "60123456789"; too few digits and the
/// phone is not searched at all (every number contains "6").
String peopleOrFilter(String term) {
  final digits = term.replaceAll(RegExp(r'[^\d]'), '');
  return [
    'name.ilike.*$term*',
    'email.ilike.*$term*',
    'display_id.ilike.*$term*',
    if (digits.length >= 3) 'phone.ilike.*$digits*',
  ].join(',');
}

/// The label a commission rule keeps for the person it is about.
String personLabel(Map<String, dynamic> p) {
  final name = '${p['name'] ?? ''}'.trim();
  if (name.isNotEmpty) return name;
  for (final k in ['phone', 'email', 'display_id']) {
    final v = '${p[k] ?? ''}'.trim();
    if (v.isNotEmpty) return v;
  }
  return '${p['id']}';
}

/// The second line of a search result: how else the person is known.
String personDetails(Map<String, dynamic> p) =>
    [p['display_id'], p['phone'], p['email']].map((v) => '${v ?? ''}'.trim()).where((s) => s.isNotEmpty).join(' · ');
