// Admin ID review (migration 0345): comparing the fields read from a user's
// ID image with what they keyed, so the reviewer can keep either, per field.
// The five fields the review compares: name, ID number, date of birth, gender
// and address. Pure.
library;

import 'document_text.dart' show idKey;

/// Which value a field keeps: the user's keyed value or the one read from the
/// ID image.
enum IdSource { keyed, fromId }

/// One field's keyed value beside the value read from the ID image.
class IdFieldRow {
  IdFieldRow({required this.key, required this.label, required this.keyed, required this.read});

  /// The profile column: 'name', 'ic', 'birth_date', 'gender', 'address'.
  final String key;
  final String label;

  /// The keyed value, and the value read from the image (already normalised to
  /// how the profile stores it: digits for the IC, yyyy-mm-dd for the date,
  /// 'male'/'female'/'other' for gender). Null when absent.
  final String? keyed;
  final String? read;

  /// The image gave a value for this field.
  bool get hasRead => (read ?? '').trim().isNotEmpty;

  /// The read value is present and differs from the keyed one.
  bool get differs => hasRead && _norm(key, keyed) != _norm(key, read);

  /// What to pick by default: the ID's value when it differs, else the keyed.
  IdSource get defaultChoice => differs ? IdSource.fromId : IdSource.keyed;
}

String _norm(String key, String? v) {
  final t = (v ?? '').trim().toLowerCase();
  if (key == 'ic') return t.replaceAll(RegExp(r'[^0-9a-z]'), '');
  return t.replaceAll(RegExp(r'\s+'), ' ');
}

String? _s(Object? v) {
  final t = v == null ? '' : '$v'.trim();
  return t.isEmpty ? null : t;
}

/// The five comparison rows from the keyed [profile] and the [read] map the
/// id-read edge returned ({name, ic, birth, gender, address, ...}). The IC is
/// reduced to its key characters so "800912-01-6837" and "800912016837" match.
List<IdFieldRow> idReviewRows({required Map<String, dynamic> profile, required Map<String, dynamic> read}) {
  final icRead = read['ic'] == null ? null : idKey('${read['ic']}');
  return [
    IdFieldRow(key: 'name', label: 'Name', keyed: _s(profile['name']), read: _s(read['name'])),
    IdFieldRow(key: 'ic', label: 'ID number', keyed: _s(profile['ic']), read: _s(icRead)),
    IdFieldRow(key: 'birth_date', label: 'Date of birth', keyed: _s(profile['birth_date']), read: _s(read['birth'])),
    IdFieldRow(key: 'gender', label: 'Gender', keyed: _s(profile['gender']), read: _s(read['gender'])),
    IdFieldRow(key: 'address', label: 'Address', keyed: _s(profile['address']), read: _s(read['address'])),
  ];
}

/// The fields to write to the profile: for each row the reviewer set to
/// [IdSource.fromId] (and that has a read value), its key → the read value.
/// Empty when nothing was chosen from the ID — then no profile write is needed.
Map<String, dynamic> idReviewChosen(List<IdFieldRow> rows, Map<String, IdSource> choice) => {
  for (final r in rows)
    if (r.hasRead && (choice[r.key] ?? r.defaultChoice) == IdSource.fromId) r.key: r.read,
};
