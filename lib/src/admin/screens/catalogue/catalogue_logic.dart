/// Pure logic for the Services & catalogue admin screens, ported from the Expo
/// screens `admin-settings-{service,vehicle-services,partner-type,
/// document-type,required-documents,vehicle-make-model,assign-service*}.tsx`
/// and `utils/serviceAssignmentsStore.ts` / `utils/apiKeysStore.ts`.
///
/// Every value shape written here matches what the Expo app writes, so both
/// apps edit the same rows.
library;

import 'dart:convert';

import '../../admin_settings_models.dart';

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// The "All" token used by doc-type / partner-type multi-selects.
const allToken = '__ALL__';

/// JavaScript `Boolean(v ?? fallback)` semantics for loosely typed JSON.
bool jsBool(Object? v, [bool fallback = false]) {
  if (v == null) return fallback;
  if (v is bool) return v;
  if (v is num) return v != 0 && !v.isNaN;
  if (v is String) return v.isNotEmpty;
  return true;
}

/// `String(v ?? "")`.
String str(Object? v) => v == null ? '' : '$v';

/// `Number(v ?? 9999)` for sorting by display priority.
num priorityOf(Map<String, dynamic> values) {
  final v = values['displayPriority'];
  if (v == null) return 9999;
  if (v is num) return v;
  final s = '$v'.trim();
  if (s.isEmpty) return 0; // Number("") === 0
  return num.tryParse(s) ?? double.nan;
}

int _cmpNum(num a, num b) {
  if (a.isNaN && b.isNaN) return 0;
  if (a.isNaN) return 1;
  if (b.isNaN) return -1;
  return a.compareTo(b);
}

/// Sorts by `displayPriority` (missing last); ties by name when [byName].
List<SettingEntry> sortByPriority(List<SettingEntry> entries, {bool byName = false}) {
  final list = [...entries];
  list.sort((a, b) {
    final c = _cmpNum(priorityOf(a.values), priorityOf(b.values));
    if (c != 0 || !byName) return c;
    return str(a.values['name']).compareTo(str(b.values['name']));
  });
  return list;
}

/// Moves the entry at [from] by [dir] and returns the new `displayPriority`
/// (1-based) of every entry whose priority changed, keyed by id.
Map<String, int> reorderPriorities(List<SettingEntry> sorted, int from, int dir) {
  final to = from + dir;
  if (from < 0 || from >= sorted.length || to < 0 || to >= sorted.length) return {};
  final next = [...sorted];
  final m = next.removeAt(from);
  next.insert(to, m);
  final out = <String, int>{};
  for (var i = 0; i < next.length; i++) {
    final p = next[i].values['displayPriority'];
    final current = p is num ? p : num.tryParse('${p ?? ''}');
    if (current != i + 1) out[next[i].id] = i + 1;
  }
  return out;
}

/// Case-insensitive search over every value of an entry.
bool entryMatches(SettingEntry e, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return e.values.values.any((v) => _jsString(v).toLowerCase().contains(q));
}

String _jsString(Object? v) {
  if (v is List) return v.map(_jsString).join(',');
  return '$v';
}

/// Toggles [id] in a multi-select that has an "All" token.
List<String> toggleWithAll(List<String> current, String id) {
  if (id == allToken) return current.contains(allToken) ? [] : [allToken];
  final next = current.where((x) => x != allToken).toList();
  if (next.contains(id)) return next.where((x) => x != id).toList();
  return [...next, id];
}

bool hasDuplicateName(List<SettingEntry> entries, String name, {String? exceptId}) {
  final n = name.trim().toLowerCase();
  return entries.any((e) => str(e.values['name']).toLowerCase() == n && e.id != exceptId);
}

typedef ValuesResult = ({Map<String, dynamic> values, String? error});

// ---------------------------------------------------------------------------
// Service Settings (`service-settings`)
// ---------------------------------------------------------------------------

const serviceSettingsKey = 'service-settings';

ValuesResult buildServiceValues({
  required String name,
  required String description,
  required String iconUri,
  required String priorityText,
  required bool active,
  required int entryCount,
  Map<String, dynamic>? editing,
}) {
  if (name.trim().isEmpty) return (values: const {}, error: 'Please fill in Service Name.');
  final p = num.tryParse(priorityText.trim());
  return (
    values: {
      'name': name.trim(),
      'description': description.trim(),
      'iconUri': iconUri,
      'displayPriority': (p != null && p.isFinite) ? p : entryCount + 1,
      'active': active,
      'isDefault': editing == null ? false : jsBool(editing['isDefault']),
    },
    error: null,
  );
}

// ---------------------------------------------------------------------------
// Vehicle Services (`vehicle-services`)
// ---------------------------------------------------------------------------

const vehicleServicesKey = 'vehicle-services';

class NumField {
  const NumField(this.key, this.label, {this.suffix, this.required = false});
  final String key;
  final String label;
  final String? suffix;
  final bool required;
}

const vehicleServiceNumberFields = [
  NumField('costPerKm', 'Cost Per Km', required: true),
  NumField('costPerMin', 'Cost Per Min', required: true),
  NumField('minOfferFarePct', 'Minimum Offer Fare Amount', suffix: '%'),
  NumField('maxBidPct', 'Max Bid Amount', suffix: '%'),
  NumField('maxBidOfferScreenPct', 'Max Bid Amount Offer Screen', suffix: '%'),
  NumField('maxBidDriverPct', 'Max Bid Amount Driver Bid', suffix: '%'),
  NumField('minFareAmount', 'Minimum Fare Amount', required: true),
  NumField('displayPriority', 'Display Priority'),
  NumField('maxPax', 'Max Pax'),
  NumField('maxLuggage', 'Max Luggage'),
  NumField('maxWeight', 'Max Weight', suffix: 'kg'),
  NumField('maxSize', 'Max Size', suffix: 'L'),
  NumField('maxVehicleAge', 'Max Vehicle Age', suffix: 'yrs'),
];

const fuelTypes = ['Petrol', 'Diesel', 'Electric'];

const mapIconPalette = [
  '#EF4444', '#F97316', '#F59E0B', '#EAB308', '#84CC16', '#22C55E', '#10B981',
  '#14B8A6', '#06B6D4', '#0EA5E9', '#3B82F6', '#6366F1', '#8B5CF6', '#A855F7',
  '#D946EF', '#EC4899', '#F43F5E', '#111827', '#6B7280', '#FFFFFF',
];

List<String> stringList(Object? v) => v is List ? v.map((e) => '$e').toList() : <String>[];

/// Service names offered as "Service Type Allowed" (from Service Settings).
List<String> serviceTypeOptions(List<SettingEntry> serviceSettings) => sortByPriority(serviceSettings)
    .map((e) => str(e.values['name']).trim())
    .where((n) => n.isNotEmpty)
    .toList();

ValuesResult buildVehicleServiceValues({
  required Map<String, String> text, // name, description, shortDescription, iconUri, heroImageUri, mapIconUri, mapIconColor
  required Map<String, String> numbers,
  required List<String> serviceTypes,
  required List<String> fuel,
  required bool status,
}) {
  final name = (text['name'] ?? '').trim();
  if (name.isEmpty) return (values: const {}, error: 'Please fill in Service Name.');
  for (final f in vehicleServiceNumberFields) {
    if (f.required && (numbers[f.key] ?? '').trim().isEmpty) {
      return (values: const {}, error: 'Please fill in ${f.label}.');
    }
  }
  final values = <String, dynamic>{
    'iconUri': text['iconUri'] ?? '',
    'heroImageUri': text['heroImageUri'] ?? '',
    'mapIconUri': text['mapIconUri'] ?? '',
    'mapIconColor': text['mapIconColor'] ?? '',
    'name': name,
    'description': (text['description'] ?? '').trim(),
    'shortDescription': (text['shortDescription'] ?? '').trim(),
    'serviceTypes': serviceTypes,
    'fuelTypes': fuel,
    'status': status,
  };
  for (final f in vehicleServiceNumberFields) {
    final n = num.tryParse((numbers[f.key] ?? '').trim());
    values[f.key] = (n != null && n.isFinite) ? n : 0;
  }
  return (values: values, error: null);
}

String vehicleServiceMeta(Map<String, dynamic> v) {
  bool has(String k) => v[k] != null && '${v[k]}' != '';
  return [
    if (has('costPerKm')) 'Km ${v['costPerKm']}',
    if (has('costPerMin')) 'Min ${v['costPerMin']}',
    if (has('minFareAmount')) 'Min Fare ${v['minFareAmount']}',
  ].join(' • ');
}

// ---------------------------------------------------------------------------
// Partner Type (`partner-type`)
// ---------------------------------------------------------------------------

const partnerTypeKey = 'partner-type';
const partnerTypeIconsBucket = 'partner-type-icons';
const maxSubServiceDepth = 3;
const shortInfoMax = 140;

class SubService {
  const SubService({required this.id, required this.name, this.enabled = true, this.children = const []});
  final String id;
  final String name;
  final bool enabled;
  final List<SubService> children;

  SubService copyWith({String? name, bool? enabled, List<SubService>? children}) => SubService(
        id: id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        children: children ?? this.children,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'enabled': enabled,
        'children': children.map((c) => c.toJson()).toList(),
      };
}

/// `S-<base36 ms>-<4 random>` like Expo's `newId`.
String newSubServiceId([DateTime? now, String? rand]) =>
    'S-${(now ?? DateTime.now()).millisecondsSinceEpoch.toRadixString(36)}-${rand ?? _rand36(4)}';

String _rand36(int n) {
  final r = DateTime.now().microsecondsSinceEpoch;
  final s = (r * 2654435761 % 0x7fffffff).toRadixString(36).padLeft(n, '0');
  return s.substring(s.length - n);
}

/// Parses `subServicesJson` (a JSON string), dropping nameless nodes.
List<SubService> parseSubServiceTree(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) return [];
  Object? parsed;
  try {
    parsed = jsonDecode(raw);
  } catch (_) {
    return [];
  }
  if (parsed is! List) return [];
  SubService? sanitize(Object? n) {
    if (n is! Map) return null;
    final name = n['name'] is String ? n['name'] as String : '';
    if (name.trim().isEmpty) return null;
    final children = (n['children'] is List ? n['children'] as List : const [])
        .map(sanitize)
        .whereType<SubService>()
        .toList();
    return SubService(
      id: n['id'] is String ? n['id'] as String : newSubServiceId(),
      name: name,
      enabled: n['enabled'] is bool ? n['enabled'] as bool : true,
      children: children,
    );
  }

  return parsed.map(sanitize).whereType<SubService>().toList();
}

String encodeSubServiceTree(List<SubService> tree) => jsonEncode(tree.map((n) => n.toJson()).toList());

int countSubServices(List<SubService> tree) =>
    tree.fold(0, (n, s) => n + 1 + countSubServices(s.children));

bool subServiceTreeMatches(List<SubService> tree, String q) =>
    tree.any((s) => s.name.toLowerCase().contains(q) || subServiceTreeMatches(s.children, q));

/// Applies [mutator] to the children list at [parentPath] (empty = root).
List<SubService> _updateChildren(
    List<SubService> tree, List<int> parentPath, List<SubService> Function(List<SubService>) mutator) {
  if (parentPath.isEmpty) return mutator([...tree]);
  final i = parentPath.first;
  return [
    for (var k = 0; k < tree.length; k++)
      k == i ? tree[k].copyWith(children: _updateChildren(tree[k].children, parentPath.sublist(1), mutator)) : tree[k],
  ];
}

/// A node at [path] may take children while its path is shorter than the
/// maximum depth (so the deepest level is 3).
bool canAddSubServiceChild(List<int> path) => path.length < maxSubServiceDepth;

List<SubService> addSubService(List<SubService> tree, List<int> parentPath, String name, {String? id}) {
  if (parentPath.length >= maxSubServiceDepth) return tree;
  final v = name.trim();
  if (v.isEmpty) return tree;
  return _updateChildren(tree, parentPath, (l) => [...l, SubService(id: id ?? newSubServiceId(), name: v)]);
}

List<SubService> renameSubService(List<SubService> tree, List<int> path, String name) {
  final v = name.trim();
  if (v.isEmpty || path.isEmpty) return tree;
  final idx = path.last;
  return _updateChildren(tree, path.sublist(0, path.length - 1),
      (l) => [for (var i = 0; i < l.length; i++) i == idx ? l[i].copyWith(name: v) : l[i]]);
}

List<SubService> removeSubService(List<SubService> tree, List<int> path) {
  if (path.isEmpty) return tree;
  final idx = path.last;
  return _updateChildren(
      tree, path.sublist(0, path.length - 1), (l) => [for (var i = 0; i < l.length; i++) if (i != idx) l[i]]);
}

List<SubService> toggleSubService(List<SubService> tree, List<int> path) {
  if (path.isEmpty) return tree;
  final idx = path.last;
  return _updateChildren(tree, path.sublist(0, path.length - 1),
      (l) => [for (var i = 0; i < l.length; i++) i == idx ? l[i].copyWith(enabled: !l[i].enabled) : l[i]]);
}

/// Partner type `docTypes`: a JSON string array (strict — non-strings dropped).
List<String> parsePartnerDocTypes(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) return [];
  try {
    final p = jsonDecode(raw);
    return p is List ? p.whereType<String>().toList() : [];
  } catch (_) {
    return [];
  }
}

bool partnerTypeMatches(SettingEntry e, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  if (str(e.values['name']).toLowerCase().contains(q)) return true;
  return subServiceTreeMatches(parseSubServiceTree(e.values['subServicesJson']), q);
}

ValuesResult buildPartnerTypeValues({
  required List<SettingEntry> entries,
  SettingEntry? editing,
  required String name,
  required String shortInfo,
  required String iconUrl,
  required bool enabled,
  required bool subServicesEnabled,
  required bool vehicleRequired,
  required List<SubService> tree,
  required List<String> docTypes,
}) {
  final n = name.trim();
  if (n.isEmpty) return (values: const {}, error: 'Please enter a partner type name.');
  if (hasDuplicateName(entries, n, exceptId: editing?.id)) {
    return (values: const {}, error: 'A partner type with this name already exists.');
  }
  final values = <String, dynamic>{
    'name': n,
    'shortInfo': shortInfo.trim(),
    'iconUrl': iconUrl.trim(),
    'isDefault': jsBool(editing?.values['isDefault']),
    'enabled': enabled,
    'subServicesEnabled': subServicesEnabled,
    'vehicleRequired': vehicleRequired,
    'subServicesJson': encodeSubServiceTree(tree),
    'docTypes': jsonEncode(docTypes),
  };
  if (editing != null) {
    final prev = editing.values['displayPriority'];
    values['displayPriority'] = prev == null ? entries.length : (prev is num ? prev : num.tryParse('$prev') ?? 0);
  } else {
    values['displayPriority'] = entries.length + 1;
  }
  return (values: values, error: null);
}

/// Storage path for an uploaded partner-type icon (`icon-<ms>-<6>.<ext>`).
String partnerTypeIconPath(String ext, {DateTime? now, String? rand}) =>
    'icon-${(now ?? DateTime.now()).millisecondsSinceEpoch}-${rand ?? _rand36(6)}.$ext';

/// Extension / content type as `uploadPartnerTypeIcon` guesses them.
String iconExt(String fileName) {
  final l = fileName.toLowerCase().split('?').first;
  if (l.endsWith('.jpg') || l.endsWith('.jpeg')) return 'jpg';
  if (l.endsWith('.webp')) return 'webp';
  if (l.endsWith('.gif')) return 'gif';
  if (l.endsWith('.svg')) return 'svg';
  return 'png';
}

String imageContentType(String fileName) => switch (iconExt(fileName)) {
      'jpg' => 'image/jpeg',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'svg' => 'image/svg+xml',
      _ => 'image/png',
    };

/// `data:<mime>;base64,<...>` — how the Expo pickers store service images.
String toDataUrl(List<int> bytes, String fileName) =>
    'data:${imageContentType(fileName)};base64,${base64Encode(bytes)}';

// ---------------------------------------------------------------------------
// Document Type (`document_type` table, category `document-type`)
// ---------------------------------------------------------------------------

const documentTypeKey = 'document-type';

const defaultDocumentTypes = [
  (name: 'Partner', description: 'Documents shown to partners (partner-documents). Narrow further via Partner Types.'),
  (name: 'User', description: 'Documents shown to end users'),
  (name: 'Vehicle', description: 'Documents tied to a vehicle'),
  (name: 'Admin-Partner', description: 'Admin-side partner documents'),
  (name: 'Admin-User', description: 'Admin-side user documents'),
  (name: 'Admin-Vehicle', description: 'Admin-side vehicle documents'),
];

/// Defaults first, then by name.
List<SettingEntry> sortDocumentTypes(List<SettingEntry> entries) {
  final list = [...entries];
  list.sort((a, b) {
    final ad = jsBool(a.values['isDefault']) ? 0 : 1;
    final bd = jsBool(b.values['isDefault']) ? 0 : 1;
    if (ad != bd) return ad - bd;
    return str(a.values['name']).compareTo(str(b.values['name']));
  });
  return list;
}

/// What the Expo screen's one-time seeding does: remove legacy *default*
/// types not in the fixed set, and add any missing fixed defaults.
({List<String> removeIds, List<Map<String, dynamic>> add}) documentTypeDefaultsPlan(List<SettingEntry> entries) {
  final defaultsLc = defaultDocumentTypes.map((d) => d.name.toLowerCase()).toSet();
  final remove = [
    for (final e in entries)
      if (jsBool(e.values['isDefault']) && !defaultsLc.contains(str(e.values['name']).trim().toLowerCase())) e.id,
  ];
  final existing = entries.map((e) => str(e.values['name']).trim().toLowerCase()).where((n) => n.isNotEmpty).toSet();
  final add = [
    for (final d in defaultDocumentTypes)
      if (!existing.contains(d.name.toLowerCase()))
        {'name': d.name, 'description': d.description, 'isDefault': true, 'enabled': true},
  ];
  return (removeIds: remove, add: add);
}

ValuesResult buildDocumentTypeValues({
  required List<SettingEntry> entries,
  SettingEntry? editing,
  required String name,
  required String description,
  required bool enabled,
}) {
  final n = name.trim();
  if (n.isEmpty) return (values: const {}, error: 'Please enter a document type name.');
  if (hasDuplicateName(entries, n, exceptId: editing?.id)) {
    return (values: const {}, error: 'A document type with this name already exists.');
  }
  return (
    values: {
      'name': n,
      'description': description.trim(),
      'isDefault': jsBool(editing?.values['isDefault']),
      'enabled': enabled,
    },
    error: null,
  );
}

/// Enabled document types, by name.
List<SettingEntry> enabledDocumentTypes(List<SettingEntry> docTypes) {
  final list = docTypes.where((d) => jsBool(d.values['enabled'], true)).toList();
  list.sort((a, b) => str(a.values['name']).compareTo(str(b.values['name'])));
  return list;
}

// ---------------------------------------------------------------------------
// Required Documents (`required_document` table, category `required-documents`)
// ---------------------------------------------------------------------------

const requiredDocumentsKey = 'required-documents';

/// Required-documents `docTypes` / `partnerTypes`: array, JSON string, or
/// (legacy) comma list.
List<String> parseLooseList(Object? raw) {
  if (raw is List) return raw.map((x) => '$x').toList();
  if (raw is String && raw.isNotEmpty) {
    try {
      final p = jsonDecode(raw);
      if (p is List) return p.map((x) => '$x').toList();
      return [];
    } catch (_) {
      return raw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    }
  }
  return [];
}

class RegionSelection {
  const RegionSelection({required this.type, required this.country, this.state, this.compulsory = true});
  final String type; // 'country' | 'state'
  final String country;
  final String? state;
  final bool compulsory;

  String get key => type == 'country' ? 'country:$country' : 'state:$country|$state';
  String get label => type == 'country' ? country : '$state, $country';

  RegionSelection withCompulsory(bool v) => RegionSelection(type: type, country: country, state: state, compulsory: v);

  Map<String, dynamic> toJson() => {'type': type, 'country': country, 'state': state ?? '', 'compulsory': compulsory};

  @override
  bool operator ==(Object other) => other is RegionSelection && other.key == key && other.compulsory == compulsory;

  @override
  int get hashCode => Object.hash(key, compulsory);
}

List<RegionSelection> parseRegions(Object? raw) {
  List<RegionSelection> fromList(List l) => [
        for (final r in l)
          if (r is Map)
            ...() {
              final type = r['type'] == 'state' ? 'state' : 'country';
              final country = str(r['country']).trim();
              final state = str(r['state']).trim();
              if (country.isEmpty || (type == 'state' && state.isEmpty)) return const <RegionSelection>[];
              return [
                RegionSelection(
                  type: type,
                  country: country,
                  state: type == 'state' ? state : null,
                  compulsory: jsBool(r['compulsory'], true),
                ),
              ];
            }(),
      ];
  if (raw is List) return fromList(raw);
  if (raw is String && raw.isNotEmpty) {
    try {
      final p = jsonDecode(raw);
      if (p is List) return fromList(p);
    } catch (_) {}
  }
  return [];
}

String regionSummary(Map<String, dynamic> v) {
  final global = v['regionsGlobal'];
  if (global == true || (global == null && !jsBool(v['regions']))) return 'Global';
  final list = parseRegions(v['regions']);
  if (list.isEmpty) return 'Global';
  return '${list.length} region${list.length == 1 ? '' : 's'}';
}

/// Boolean option flags on a required document, in display order.
const requiredDocOptions = [
  (key: 'requireStartDate', title: 'Start Date', desc: 'Partner enters the document start date'),
  (key: 'requireExpiryDate', title: 'Expiry Date', desc: 'Recorded with document — expired docs require re-upload'),
  (key: 'requireDocumentNumber', title: 'Document Number', desc: 'Required at every upload'),
  (
    key: 'requireInsuranceProvider',
    title: 'Select Insurance Provider',
    desc: 'Partner picks from Insurance Providers at every upload'
  ),
  (key: 'isPwd', title: 'For PWD (People with Disability)', desc: 'Mark this document as a PWD document'),
  (key: 'requireFrontBack', title: 'Front & Back Required', desc: 'Partner must upload both sides of the document'),
  (
    key: 'allowPdfUpload',
    title: 'Allow PDF Upload',
    desc: 'Partners can upload PDF documents — AI analyses them like images'
  ),
];

class RequiredDocForm {
  RequiredDocForm({
    this.name = '',
    this.description = '',
    List<String>? docTypes,
    List<String>? partnerTypes,
    this.required = true,
    this.active = true,
    this.regionsGlobal = true,
    this.regionsGlobalCompulsory = true,
    List<RegionSelection>? regions,
    Map<String, bool>? options,
    this.isTaxiPermit = false,
  })  : docTypes = docTypes ?? [],
        partnerTypes = partnerTypes ?? [],
        regions = regions ?? [],
        options = options ?? {for (final o in requiredDocOptions) o.key: false};

  factory RequiredDocForm.fromValues(Map<String, dynamic> v) {
    final regions = parseRegions(v['regions']);
    return RequiredDocForm(
      name: str(v['name']),
      description: str(v['description']),
      docTypes: parseLooseList(v['docTypes']),
      partnerTypes: parseLooseList(v['partnerTypes']),
      required: jsBool(v['required'], true),
      active: jsBool(v['active'], true),
      regionsGlobal: v.containsKey('regionsGlobal') && v['regionsGlobal'] != null
          ? jsBool(v['regionsGlobal'])
          : regions.isEmpty,
      regionsGlobalCompulsory: jsBool(v['regionsGlobalCompulsory'] ?? v['required'], true),
      regions: regions,
      options: {for (final o in requiredDocOptions) o.key: jsBool(v[o.key])},
      isTaxiPermit: jsBool(v['isTaxiPermit']),
    );
  }

  String name;
  String description;
  List<String> docTypes;
  List<String> partnerTypes;
  bool required;
  bool active;
  bool regionsGlobal;
  bool regionsGlobalCompulsory;
  List<RegionSelection> regions;
  Map<String, bool> options;
  bool isTaxiPermit;

  void toggleRegion(RegionSelection r) {
    regions = regions.any((x) => x.key == r.key)
        ? regions.where((x) => x.key != r.key).toList()
        : [...regions, r.withCompulsory(true)];
  }

  void cycleRegionCompulsory(String key) {
    regions = [for (final r in regions) r.key == key ? r.withCompulsory(!r.compulsory) : r];
  }
}

ValuesResult buildRequiredDocValues({
  required List<SettingEntry> entries,
  SettingEntry? editing,
  required RequiredDocForm form,
}) {
  final n = form.name.trim();
  if (n.isEmpty) return (values: const {}, error: 'Please enter a document name.');
  if (!form.regionsGlobal && form.regions.isEmpty) {
    return (values: const {}, error: 'Select at least one country/state or enable Global.');
  }
  if (hasDuplicateName(entries, n, exceptId: editing?.id)) {
    return (values: const {}, error: 'A document with this name already exists.');
  }
  final values = <String, dynamic>{
    'name': n,
    'description': form.description.trim(),
    'docTypes': jsonEncode(form.docTypes),
    'partnerTypes': jsonEncode(form.partnerTypes),
    'required': form.required,
    'active': form.active,
    'regionsGlobal': form.regionsGlobal,
    'regionsGlobalCompulsory': form.regionsGlobalCompulsory,
    'regions': jsonEncode(form.regions.map((r) => r.toJson()).toList()),
    for (final o in requiredDocOptions) o.key: form.options[o.key] ?? false,
    'isTaxiPermit': form.isTaxiPermit,
  };
  // Expo merges onto the existing values so unknown keys survive.
  return (values: {...?editing?.values, ...values}, error: null);
}

/// Enabled partner type names (`enabled ?? active ?? true`), sorted.
List<String> enabledPartnerTypeNames(List<SettingEntry> partnerTypes) {
  final names = partnerTypes
      .where((d) => jsBool(d.values['enabled'] ?? d.values['active'], true))
      .map((d) => str(d.values['name']).trim())
      .where((n) => n.isNotEmpty)
      .toList()
    ..sort();
  return names;
}

/// Labels for a required document's doc types (ids → names).
List<String> docTypeLabels(List<String> ids, List<SettingEntry> docTypes) {
  if (ids.contains(allToken)) return ['All'];
  return [
    for (final id in ids) str(docTypes.where((d) => d.id == id).firstOrNull?.values['name'] ?? 'Unknown'),
  ];
}

// ---------------------------------------------------------------------------
// Vehicle Make & Model (`vehicle_make_models` table)
// ---------------------------------------------------------------------------

class VehicleMakeModel {
  const VehicleMakeModel({
    required this.id,
    this.vehicleType = '',
    this.energyType = '',
    this.make = '',
    this.model = '',
    this.yearFrom = '',
    this.yearTo = '',
    this.iconUri = '',
    this.status = true,
    this.isDefault = false,
    this.position = 0,
  });

  factory VehicleMakeModel.fromRow(Map<String, dynamic> r) => VehicleMakeModel(
        id: '${r['id']}',
        vehicleType: str(r['vehicle_type']).trim(),
        energyType: str(r['energy_type']).trim(),
        make: str(r['make']).trim(),
        model: str(r['model']).trim(),
        yearFrom: str(r['year_from']).trim(),
        yearTo: str(r['year_to']).trim(),
        iconUri: str(r['icon_uri']),
        status: r['status'] == null ? true : jsBool(r['status']),
        isDefault: jsBool(r['is_default']),
        position: (r['position'] as num?)?.toInt() ?? 0,
      );

  final String id;
  final String vehicleType;
  final String energyType;
  final String make;
  final String model;
  final String yearFrom;

  /// Empty = unknown; `~` = ongoing.
  final String yearTo;
  final String iconUri;
  final bool status;
  final bool isDefault;
  final int position;

  /// The row `upsertVehicleMakeModel` writes.
  Map<String, dynamic> toRow() => {
        'id': id,
        'vehicle_type': vehicleType,
        'energy_type': energyType,
        'make': make,
        'model': model,
        'year_from': yearFrom,
        'year_to': yearTo,
        'icon_uri': iconUri,
        'status': status,
        'is_default': isDefault,
        'position': position,
      };
}

String formatYearRange(String from, String to) {
  final f = from.trim();
  final t = to.trim();
  if (f.isEmpty && t.isEmpty) return '';
  if (f.isNotEmpty && t.isEmpty) return '($f ~)';
  if (f.isEmpty) return '(~ $t)';
  return '($f - $t)';
}

/// Drill-down path: vehicle type → energy type → make → models.
class VmmPath {
  const VmmPath({this.vehicleType, this.energyType, this.make});
  final String? vehicleType;
  final String? energyType;
  final String? make;

  /// 0 = vehicle types, 1 = energy types, 2 = makes, 3 = models.
  int get level => make != null ? 3 : energyType != null ? 2 : vehicleType != null ? 1 : 0;

  VmmPath get parent => switch (level) {
        3 => VmmPath(vehicleType: vehicleType, energyType: energyType),
        2 => VmmPath(vehicleType: vehicleType),
        _ => const VmmPath(),
      };

  VmmPath child(String name) => switch (level) {
        0 => VmmPath(vehicleType: name),
        1 => VmmPath(vehicleType: vehicleType, energyType: name),
        _ => VmmPath(vehicleType: vehicleType, energyType: energyType, make: name),
      };

  /// Replaces the [level]'s name if it is [from].
  VmmPath renamed(int level, String from, String to) => VmmPath(
        vehicleType: level == 0 && vehicleType == from ? to : vehicleType,
        energyType: level == 1 && energyType == from ? to : energyType,
        make: level == 2 && make == from ? to : make,
      );
}

String _norm(String s) => s.trim().toLowerCase();

bool _inPath(VehicleMakeModel p, VmmPath path, int depth) =>
    (depth < 1 || p.vehicleType == path.vehicleType) &&
    (depth < 2 || p.energyType == path.energyType) &&
    (depth < 3 || p.make == path.make);

String _levelField(VehicleMakeModel p, int level) => switch (level) {
      0 => p.vehicleType,
      1 => p.energyType,
      _ => p.make,
    };

bool _deepMatch(VehicleMakeModel p, String q, int fromLevel) {
  final fields = [
    if (fromLevel <= 0) p.vehicleType,
    if (fromLevel <= 1) p.energyType,
    if (fromLevel <= 2) p.make,
    p.model,
    p.yearFrom,
    p.yearTo,
    formatYearRange(p.yearFrom, p.yearTo),
  ];
  return fields.any((f) => f.toLowerCase().contains(q));
}

/// Names (with model counts) at a category [path.level] < 3, filtered by
/// [query] across everything beneath them.
List<({String name, int count})> vmmCategories(List<VehicleMakeModel> all, VmmPath path, {String query = ''}) {
  final level = path.level;
  final q = query.trim().toLowerCase();
  final counts = <String, int>{};
  final allowed = <String>{};
  for (final p in all) {
    if (!_inPath(p, path, level)) continue;
    final name = _levelField(p, level);
    if (name.isEmpty) continue;
    counts[name] = (counts[name] ?? 0) + (p.model.isNotEmpty ? 1 : 0);
    if (q.isEmpty || _deepMatch(p, q, level)) allowed.add(name);
  }
  final out = [
    for (final e in counts.entries)
      if (allowed.contains(e.key)) (name: e.key, count: e.value),
  ]..sort((a, b) => a.name.compareTo(b.name));
  return out;
}

/// Models under a full path, filtered by model / years.
List<VehicleMakeModel> vmmModels(List<VehicleMakeModel> all, VmmPath path, {String query = ''}) {
  final q = query.trim().toLowerCase();
  return all
      .where((p) => _inPath(p, path, 3) && p.model.isNotEmpty && (q.isEmpty || _deepMatch(p, q, 3)))
      .toList()
    ..sort((a, b) => a.model.compareTo(b.model));
}

/// With a query above the model level, the list becomes a search for models
/// anywhere under the current path.
List<VehicleMakeModel> vmmGlobalSearch(List<VehicleMakeModel> all, VmmPath path, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return [];
  return all
      .where((p) => p.model.isNotEmpty && _inPath(p, path, path.level) && _deepMatch(p, q, 0))
      .toList()
    ..sort((a, b) => a.model.compareTo(b.model));
}

/// Validates adding (or renaming [renameFrom] to) a category named [name] at
/// [level] under [parents]; returns an error message or null.
String? vmmCategoryError(
  List<VehicleMakeModel> all, {
  required int level,
  required String name,
  required VmmPath parents,
  String? renameFrom,
}) {
  final n = name.trim();
  if (n.isEmpty) return 'Please enter a name.';
  final vt = (parents.vehicleType ?? '').trim();
  final et = (parents.energyType ?? '').trim();
  if (renameFrom == null) {
    if (level >= 1 && vt.isEmpty) return 'Please select or enter a Vehicle Type.';
    if (level >= 2 && et.isEmpty) return 'Please select or enter an Energy Type.';
  }
  if (renameFrom != null && _norm(renameFrom) == _norm(n)) return null;
  final dup = all.any((p) => switch (level) {
        0 => _norm(p.vehicleType) == _norm(n),
        1 => _norm(p.vehicleType) == _norm(vt) && _norm(p.energyType) == _norm(n),
        2 => _norm(p.vehicleType) == _norm(vt) && _norm(p.energyType) == _norm(et) && _norm(p.make) == _norm(n),
        _ => false,
      });
  if (!dup) return null;
  return renameFrom == null
      ? '"$n" already exists. Tap it from the suggestions to open the existing one.'
      : '"$n" already exists at this level.';
}

/// Rows under the category [name] at [level] within [path] (rename/delete).
List<VehicleMakeModel> vmmCategoryRows(List<VehicleMakeModel> all, VmmPath path, int level, String name) => all
    .where((p) => switch (level) {
          0 => p.vehicleType == name,
          1 => p.vehicleType == path.vehicleType && p.energyType == name,
          2 => p.vehicleType == path.vehicleType && p.energyType == path.energyType && p.make == name,
          _ => false,
        })
    .toList();

/// The placeholder row a new category is stored as.
Map<String, dynamic> vmmCategoryPlaceholder(int level, String name, VmmPath parents, String id) => VehicleMakeModel(
      id: id,
      vehicleType: level == 0 ? name.trim() : (parents.vehicleType ?? '').trim(),
      energyType: level == 1 ? name.trim() : (level > 1 ? (parents.energyType ?? '').trim() : ''),
      make: level == 2 ? name.trim() : '',
    ).toRow();

/// Existing names offered while typing a category name.
List<String> vmmCategorySuggestions(List<VehicleMakeModel> all, int level, VmmPath parents, String typed) {
  final vt = (parents.vehicleType ?? '').trim();
  final et = (parents.energyType ?? '').trim();
  final set = <String>{};
  for (final p in all) {
    final name = _levelField(p, level);
    if (name.isEmpty) continue;
    if (level >= 1 && p.vehicleType != vt) continue;
    if (level >= 2 && p.energyType != et) continue;
    set.add(name);
  }
  if (level >= 1 && vt.isEmpty) return [];
  if (level >= 2 && et.isEmpty) return [];
  final list = set.toList()..sort();
  final q = _norm(typed);
  return (q.isEmpty ? list : list.where((n) => _norm(n).contains(q)).toList()).take(12).toList();
}

class ModelForm {
  ModelForm({
    this.vehicleType = '',
    this.energyType = '',
    this.make = '',
    this.model = '',
    this.yearFrom = '',
    this.yearTo = '',
    this.ongoing = false,
    this.iconUri = '',
    this.status = true,
  });

  factory ModelForm.fromRecord(VehicleMakeModel p) => ModelForm(
        vehicleType: p.vehicleType,
        energyType: p.energyType,
        make: p.make,
        model: p.model,
        yearFrom: p.yearFrom,
        yearTo: p.yearTo == '~' ? '' : p.yearTo,
        ongoing: p.yearTo == '~',
        iconUri: p.iconUri,
        status: p.status,
      );

  String vehicleType, energyType, make, model, yearFrom, yearTo, iconUri;
  bool ongoing, status;
}

/// Validates the model form and returns the row to upsert.
({Map<String, dynamic>? row, String? error}) buildModelRow(
  List<VehicleMakeModel> all,
  ModelForm f, {
  VehicleMakeModel? editing,
  required String newId,
}) {
  for (final (v, label) in [
    (f.vehicleType, 'Vehicle Type'),
    (f.energyType, 'Energy Type'),
    (f.make, 'Make'),
    (f.model, 'Model'),
  ]) {
    if (v.trim().isEmpty) return (row: null, error: 'Please fill in $label.');
  }
  final yearTo = f.ongoing ? '~' : f.yearTo.trim();
  final dup = all.any((p) =>
      (editing == null || p.id != editing.id) &&
      _norm(p.vehicleType) == _norm(f.vehicleType) &&
      _norm(p.energyType) == _norm(f.energyType) &&
      _norm(p.make) == _norm(f.make) &&
      _norm(p.model) == _norm(f.model) &&
      p.yearFrom.trim() == f.yearFrom.trim() &&
      p.yearTo.trim() == yearTo);
  if (dup) {
    return (
      row: null,
      error: '"${f.model.trim()}" already exists for ${f.make.trim()} '
          '(${f.energyType.trim()} · ${f.vehicleType.trim()}). Tap it from the suggestions to edit the existing one.'
    );
  }
  return (
    row: VehicleMakeModel(
      id: editing?.id ?? newId,
      vehicleType: f.vehicleType.trim(),
      energyType: f.energyType.trim(),
      make: f.make.trim(),
      model: f.model.trim(),
      yearFrom: f.yearFrom.trim(),
      yearTo: yearTo,
      iconUri: f.iconUri,
      status: f.status,
      isDefault: editing?.isDefault ?? false,
      position: editing?.position ?? 0,
    ).toRow(),
    error: null,
  );
}

// ---------------------------------------------------------------------------
// Assign Service (`serviceAssignmentsStore.ts`; device-local in Expo)
// ---------------------------------------------------------------------------

const serviceAssignmentsPrefsKey = 'admin-settings:service-assignments-v1';
const documentSourcePrefsKey = 'admin-settings:document-source-assignments-v1';

class MappingPage {
  const MappingPage(this.id, this.label, this.description, this.route, this.capabilities);
  final String id;
  final String label;
  final String description;
  final String route;
  final List<String> capabilities;
}

const capabilityLabels = {
  'maps': 'Maps SDK / Tiles',
  'geocoding': 'Geocoding',
  'places': 'Places',
  'autocomplete': 'Autocomplete',
  'directions': 'Directions / Routing',
  'distance_matrix': 'Distance Matrix',
  'boundaries': 'Boundaries / Polygons',
  'tiles': 'Tiles',
  'ip_geolocation': 'IP Geolocation',
};

const mappingPages = [
  MappingPage('map-picker', 'Map Picker', 'Pick locations on map', '/map-picker',
      ['maps', 'geocoding', 'places', 'autocomplete']),
  MappingPage('navigation', 'Navigation', 'Turn-by-turn routing', '/navigation',
      ['maps', 'directions', 'distance_matrix']),
  MappingPage('distances', 'Distances', 'Distance & ETA calculations', '/distances', ['distance_matrix', 'directions']),
  MappingPage('rider-home', 'Rider Home', 'Main rider map screen', '/',
      ['maps', 'places', 'autocomplete', 'geocoding', 'directions']),
  MappingPage('partner-ehailing', 'Driver E-Hailing', 'E-hailing driver map', '/partner-ehailing',
      ['maps', 'directions', 'geocoding']),
  MappingPage('partner-teksi', 'Driver Teksi', 'Street-hail driver map', '/partner-teksi',
      ['maps', 'directions', 'geocoding']),
  MappingPage('offer-fare', 'Offer Fare', 'Fare offer & route preview', '/offer-fare', ['directions', 'distance_matrix']),
  MappingPage('country-states-cities', 'Country / States / Cities', 'Region hierarchy & boundaries',
      '/admin-settings-country-states-cities', ['geocoding', 'boundaries', 'places']),
  MappingPage('geo-fencing', 'Geo Fencing', 'Operating zone polygons', '/admin-settings-geo-fencing',
      ['maps', 'boundaries']),
  MappingPage('multi-gate-places', 'Multi-Gate Places', 'Multi-gate venues', '/admin-settings-multi-gate-places',
      ['maps', 'places']),
  MappingPage('airport-areas', 'Airport Areas', 'Airport pickup zones', '/admin-settings-airport-areas',
      ['maps', 'places', 'boundaries']),
  MappingPage('multi-gate-place-gates', 'Multi-Gate Place Gates', 'Gates within a multi-gate place',
      '/admin-settings-multi-gate-place-gates', ['maps', 'places', 'geocoding']),
  MappingPage('search', 'Search', 'Rider destination search', '/search', ['places', 'autocomplete', 'geocoding']),
  MappingPage('ride-confirm', 'Ride Confirm', 'Ride confirmation & route preview', '/ride-confirm',
      ['maps', 'directions', 'distance_matrix']),
  MappingPage('ride-running', 'Ride Running', 'Live ride tracking', '/ride-running', ['maps', 'directions', 'geocoding']),
  MappingPage('ride-detail', 'Ride Detail', 'Ride detail static map preview', '/ride-detail', ['maps', 'tiles']),
];

const documentSourceFeatures = [
  (
    id: 'driver-permit',
    label: 'Driver Permit',
    description: "Choose which required document's uploaded image is used as the driver permit source."
  ),
];

/// pageId → capability → {providerId, serviceId}.
typedef AssignmentsMap = Map<String, Map<String, Map<String, String>>>;

AssignmentsMap parseAssignments(String? raw) {
  if (raw == null || raw.isEmpty) return {};
  try {
    final p = jsonDecode(raw);
    if (p is! Map) return {};
    return {
      for (final page in p.entries)
        if (page.value is Map)
          '${page.key}': {
            for (final cap in (page.value as Map).entries)
              if (cap.value is Map)
                '${cap.key}': {
                  'providerId': str((cap.value as Map)['providerId']),
                  'serviceId': str((cap.value as Map)['serviceId']),
                },
          },
    };
  } catch (_) {
    return {};
  }
}

/// Renames legacy `driver-*` page ids to `partner-*`.
({AssignmentsMap next, bool changed}) migrateLegacyPageIds(AssignmentsMap map) {
  const legacy = {'driver-ehailing': 'partner-ehailing', 'driver-teksi': 'partner-teksi'};
  var changed = false;
  final next = {...map};
  legacy.forEach((oldId, newId) {
    if (next.containsKey(oldId)) {
      final old = next.remove(oldId)!;
      next.putIfAbsent(newId, () => old);
      changed = true;
    }
  });
  return (next: next, changed: changed);
}

AssignmentsMap setAssignment(AssignmentsMap map, String pageId, String capability, ({String providerId, String serviceId})? a) {
  final page = {...?map[pageId]};
  if (a == null) {
    page.remove(capability);
  } else {
    page[capability] = {'providerId': a.providerId, 'serviceId': a.serviceId};
  }
  return {...map, pageId: page};
}

({int assigned, int total}) assignmentTotals(AssignmentsMap map) {
  var assigned = 0, total = 0;
  for (final page in mappingPages) {
    total += page.capabilities.length;
    assigned += page.capabilities.where((c) => map[page.id]?[c] != null).length;
  }
  return (assigned: assigned, total: total);
}

List<MappingPage> filterMappingPages(String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return mappingPages;
  return mappingPages
      .where((p) =>
          p.label.toLowerCase().contains(q) || p.description.toLowerCase().contains(q) || p.route.toLowerCase().contains(q))
      .toList();
}

Map<String, String> parseDocumentSources(String? raw) {
  if (raw == null || raw.isEmpty) return {};
  try {
    final p = jsonDecode(raw);
    return p is Map ? {for (final e in p.entries) '${e.key}': '${e.value}'} : {};
  } catch (_) {
    return {};
  }
}

// ---------------------------------------------------------------------------
// API providers (read-only, secrets stripped) — `apiKeysStore.ts`
// ---------------------------------------------------------------------------

class ApiServiceInfo {
  const ApiServiceInfo(this.id, this.name, this.description, this.keyCount);
  final String id;
  final String name;
  final String description;

  /// Number of keys configured; the key values themselves are never kept.
  final int keyCount;
}

class ApiProviderInfo {
  const ApiProviderInfo(this.id, this.name, this.category, this.services);
  final String id;
  final String name;
  final String category;
  final List<ApiServiceInfo> services;
}

const _defaultProviders = <(String, String, String, List<(String, String, String)>)>[
  ('google', 'Google', 'Mapping', [
    ('maps', 'Maps SDK', 'Maps SDK, tiles & static maps'),
    ('places', 'Places', 'Place search, autocomplete & details'),
    ('geocoding', 'Geocoding', 'Forward & reverse geocoding'),
    ('directions', 'Directions', 'Routing, ETAs & navigation'),
    ('distance_matrix', 'Distance Matrix', 'Travel time & distance between points'),
    ('roads', 'Roads', 'Snap-to-roads & speed limits'),
  ]),
  ('openstreetmap', 'OpenStreetMap', 'Mapping', [
    ('nominatim', 'Nominatim', 'Geocoding & boundary lookup'),
    ('overpass', 'Overpass API', 'Custom Overpass server URL'),
    ('osrm', 'OSRM Routing', 'Open Source Routing Machine'),
  ]),
  ('mapbox', 'Mapbox', 'Mapping', [
    ('tiles', 'Tiles & Geocoding', 'Maps & geocoding access token'),
    ('navigation', 'Navigation', 'Turn-by-turn navigation SDK'),
  ]),
  ('here', 'HERE', 'Mapping', [
    ('api', 'HERE API', 'Maps, geocoding, routing & traffic'),
    ('app_id', 'HERE App ID', 'Legacy HERE App ID'),
  ]),
  ('tomtom', 'TomTom', 'Mapping', [('api', 'TomTom API', 'Maps, search, routing & traffic')]),
  ('microsoft', 'Microsoft', 'Mapping', [
    ('azure_maps', 'Azure Maps', 'Microsoft Azure Maps services'),
    ('bing_maps', 'Bing Maps', 'Bing Maps tiles, geocoding & routes'),
  ]),
  ('apple', 'Apple', 'Mapping', [('mapkit_token', 'MapKit JS Token', 'MapKit JS auth token (JWT)')]),
  ('esri', 'Esri', 'Mapping', [('arcgis', 'ArcGIS API', 'ArcGIS basemaps, geocoding & routing')]),
  ('tiles', 'Tile Providers', 'Tiles', [
    ('maptiler', 'MapTiler', 'Vector tiles & geocoding'),
    ('stadia_maps', 'Stadia Maps', 'Tiles, geocoding & routing'),
    ('thunderforest', 'Thunderforest', 'OSM-based styled tiles'),
  ]),
  ('routing', 'Routing', 'Routing', [('graphhopper', 'GraphHopper', 'Routing, matrix & geocoding')]),
  ('geocoding', 'Geocoding', 'Geocoding', [
    ('locationiq', 'LocationIQ', 'Geocoding & maps (Nominatim-based)'),
    ('opencage', 'OpenCage', 'Forward & reverse geocoding'),
    ('geoapify', 'Geoapify', 'Geocoding, places, routing & isolines'),
    ('positionstack', 'Positionstack', 'Forward & reverse geocoding'),
    ('what3words', 'what3words', '3-word address conversion'),
  ]),
  ('geofencing', 'Geofencing', 'Geofencing', [('radar', 'Radar', 'Geofencing, geocoding & tracking')]),
  ('places', 'Places', 'Places', [('foursquare', 'Foursquare', 'Places search & venue data')]),
  ('google_gemini', 'Google Gemini', 'AI', [
    ('generative_language', 'Generative Language API', 'Gemini text, chat & multimodal generation'),
    ('vision', 'Vision', 'Image understanding & OCR via Gemini'),
    ('embeddings', 'Embeddings', 'Text embeddings (text-embedding-004)'),
  ]),
  ('ip_geolocation', 'IP Geolocation', 'IP Geolocation', [
    ('ipinfo', 'IPinfo', 'IP geolocation lookups'),
    ('ipgeolocation', 'ipgeolocation.io', 'IP-based geolocation service'),
  ]),
];

/// Parses the stored providers list (`app_settings.api_providers`) into
/// secret-free summaries and merges in the built-in defaults the same way
/// `mergeDefaultProviders` does (defaults first, custom after). Key values
/// are dropped here and never leave this function.
List<ApiProviderInfo> providersFromStored(Object? stored) {
  ApiProviderInfo parse(Map p) => ApiProviderInfo(
        str(p['id']),
        str(p['name']),
        str(p['category']),
        [
          for (final s in (p['services'] is List ? p['services'] as List : const []))
            if (s is Map)
              ApiServiceInfo(str(s['id']), str(s['name']), str(s['description']),
                  s['keys'] is List ? (s['keys'] as List).length : 0),
        ],
      );
  final list = [
    for (final p in (stored is List ? stored : const []))
      if (p is Map) parse(p),
  ];
  final byId = {for (final p in list) p.id: p};
  final defaults = <ApiProviderInfo>[];
  for (final (id, name, category, services) in _defaultProviders) {
    final existing = byId[id];
    if (existing == null) {
      defaults.add(ApiProviderInfo(id, name, category, [for (final s in services) ApiServiceInfo(s.$1, s.$2, s.$3, 0)]));
      continue;
    }
    final have = existing.services.map((s) => s.id).toSet();
    defaults.add(ApiProviderInfo(existing.id, existing.name, existing.category, [
      ...existing.services,
      for (final s in services)
        if (!have.contains(s.$1)) ApiServiceInfo(s.$1, s.$2, s.$3, 0),
    ]));
  }
  final defaultIds = _defaultProviders.map((d) => d.$1).toSet();
  return [...defaults, ...list.where((p) => !defaultIds.contains(p.id))];
}
