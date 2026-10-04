/// Shapes for the admin-managed settings tables (`settings_entries` and the
/// dedicated tables split out of it in migrations 0019/0020). Every row is
/// `{ id, values: jsonb, position, active }`; `settings_entries` adds a
/// `category` column.
library;

enum FieldKind { text, number, boolean }

class SettingsField {
  const SettingsField(this.key, this.label, this.kind, {this.required = false});
  final String key;
  final String label;
  final FieldKind kind;
  final bool required;
}

class SettingsCategory {
  const SettingsCategory({
    required this.key,
    required this.page,
    required this.title,
    required this.subtitle,
    required this.table,
    required this.fields,
    this.primaryKey,
    this.secondaryKey,
    this.orderKey,
    this.childCategory,
    this.childScopeKey,
    this.nested = false,
  });

  /// `settings_entries.category` value (also the Expo `storageKey`).
  final String key;

  /// Expo route key, used for per-page `admin_access` grants.
  final String page;
  final String title;
  final String subtitle;

  /// Backing table: `settings_entries` or a dedicated table.
  final String table;
  final List<SettingsField> fields;
  final String? primaryKey;
  final String? secondaryKey;

  /// Field that orders rows (shown with up/down controls), if any.
  final String? orderKey;

  /// Drill-down: tapping a row opens [childCategory] scoped to this row via
  /// [childScopeKey] (e.g. insurance provider → its types).
  final String? childCategory;
  final String? childScopeKey;

  /// Only reachable by drilling down from a parent category.
  final bool nested;

  bool get usesCategoryColumn => table == 'settings_entries';

  /// Free-form category with no field schema — edited as raw key/values.
  bool get isRaw => fields.isEmpty;

  String get titleKey =>
      primaryKey ?? fields.where((f) => f.kind == FieldKind.text).map((f) => f.key).firstOrNull ?? 'name';

  String? get subtitleKey =>
      secondaryKey ??
      fields.where((f) => f.kind == FieldKind.text && f.key != titleKey).map((f) => f.key).firstOrNull;
}

class SettingEntry {
  SettingEntry({required this.id, required this.values, this.position = 0, this.active = true});

  factory SettingEntry.fromRow(Map<String, dynamic> r) => SettingEntry(
        id: r['id'] as String,
        values: Map<String, dynamic>.from((r['values'] as Map?) ?? const {}),
        position: (r['position'] as num?)?.toInt() ?? 0,
        active: r['active'] != false,
      );

  final String id;
  final Map<String, dynamic> values;
  final int position;
  final bool active;
}

/// Converts the editor's text input to the stored JSON type, the same way
/// the Expo `AdminCrudList` does (numbers stay numbers, booleans stay
/// booleans). Returns an error string for invalid required input.
({Map<String, dynamic> values, String? error}) coerceValues(
  List<SettingsField> fields,
  Map<String, Object?> input,
) {
  final out = <String, dynamic>{};
  for (final f in fields) {
    final raw = input[f.key];
    switch (f.kind) {
      case FieldKind.boolean:
        out[f.key] = raw == true;
      case FieldKind.number:
        final s = raw?.toString().trim() ?? '';
        if (s.isEmpty) {
          if (f.required) return (values: out, error: '${f.label} is required.');
          continue;
        }
        final n = num.tryParse(s);
        if (n == null) return (values: out, error: '${f.label} must be a number.');
        out[f.key] = n;
      case FieldKind.text:
        final s = raw?.toString().trim() ?? '';
        if (s.isEmpty && f.required) return (values: out, error: '${f.label} is required.');
        out[f.key] = s;
    }
  }
  return (values: out, error: null);
}

/// Rows visible under a drill-down scope (e.g. `{providerId: …}`).
bool matchesScope(SettingEntry e, Map<String, String> scope) =>
    scope.entries.every((s) => '${e.values[s.key] ?? ''}' == s.value);

/// Sorts by the order field (missing values last), then by position.
List<SettingEntry> sortEntries(List<SettingEntry> entries, String? orderKey) {
  final list = [...entries];
  list.sort((a, b) {
    if (orderKey != null) {
      final pa = num.tryParse('${a.values[orderKey] ?? ''}') ?? 9999;
      final pb = num.tryParse('${b.values[orderKey] ?? ''}') ?? 9999;
      final c = pa.compareTo(pb);
      if (c != 0) return c;
    }
    return a.position.compareTo(b.position);
  });
  return list;
}
