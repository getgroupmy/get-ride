/// Permits per country (migration 0254): the permit types an admin keeps for
/// each country (names, issuer, fields, who uploads, shown to passengers,
/// required), the country settings (require permits, bypass days, plate
/// colours), a vehicle's permit status, the plate's colours and the reminder
/// days. Nothing here knows any one country's permits: everything comes
/// from the rows. Pure: see test/permits_test.dart.
library;

import 'dart:ui' show Color;

import 'date_order.dart';

String _s(Object? v) => v is String ? v.trim() : (v == null ? '' : '$v'.trim());
bool _b(Object? v, [bool d = false]) => v is bool ? v : (v is String ? v.toLowerCase() == 'true' : d);
List<String> _list(Object? v) => v is List ? [for (final e in v) if (_s(e).isNotEmpty) _s(e)] : const [];

/// What a field is for, beyond its value.
enum PermitFieldRole {
  none(''),
  number('number'),
  validFrom('valid_from'),
  validUntil('valid_until'),
  plate('plate');

  const PermitFieldRole(this.wire);
  final String wire;

  static PermitFieldRole parse(Object? v) =>
      PermitFieldRole.values.firstWhere((r) => r.wire == _s(v), orElse: () => PermitFieldRole.none);

  String get label => switch (this) {
    PermitFieldRole.none => 'Other',
    PermitFieldRole.number => 'Permit number',
    PermitFieldRole.validFrom => 'Valid from',
    PermitFieldRole.validUntil => 'Valid until (expiry)',
    PermitFieldRole.plate => 'Vehicle plate',
  };
}

/// One field printed on a permit.
class PermitField {
  const PermitField({
    required this.key,
    required this.label,
    this.labelLocal = '',
    this.isDate = false,
    this.role = PermitFieldRole.none,
    this.passenger = false,
  });

  factory PermitField.fromJson(Map<String, dynamic> j) => PermitField(
    key: _s(j['key']),
    label: _s(j['label']),
    labelLocal: _s(j['label_local']),
    isDate: _s(j['kind']) == 'date',
    role: PermitFieldRole.parse(j['role']),
    passenger: _b(j['passenger']),
  );

  final String key;
  final String label;
  final String labelLocal;
  final bool isDate;
  final PermitFieldRole role;

  /// Shown to passengers.
  final bool passenger;

  Map<String, dynamic> toJson() => {
    'key': key,
    'label': label,
    'label_local': labelLocal,
    'kind': isDate ? 'date' : 'text',
    'role': role.wire,
    'passenger': passenger,
  };

  PermitField copyWith({String? key, String? label, String? labelLocal, bool? isDate, PermitFieldRole? role, bool? passenger}) =>
      PermitField(
        key: key ?? this.key,
        label: label ?? this.label,
        labelLocal: labelLocal ?? this.labelLocal,
        isDate: isDate ?? this.isDate,
        role: role ?? this.role,
        passenger: passenger ?? this.passenger,
      );
}

List<PermitField> parsePermitFields(Object? v) => [
  if (v is List)
    for (final f in v)
      if (f is Map) PermitField.fromJson(f.cast<String, dynamic>()),
];

/// A field key from its label: "Permit No. (Sub)" > `permit_no_sub`.
String permitFieldKey(String label) {
  final k = label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
  final cut = k.length > 40 ? k.substring(0, 40) : k;
  return cut.isEmpty ? 'field' : cut;
}

/// Why a field list can't be saved, or null (the same rules as the database).
String? permitFieldsProblem(List<PermitField> fields) {
  if (fields.length > 20) return 'A permit has at most 20 fields.';
  final keys = <String>{};
  final roles = <PermitFieldRole>{};
  for (final f in fields) {
    if (f.label.trim().isEmpty) return 'Every field needs a label.';
    if (f.label.trim().length > 80 || f.labelLocal.length > 80) return 'Keep field labels under 80 characters.';
    if (!RegExp(r'^[a-z0-9_]{1,40}$').hasMatch(f.key)) return 'Field "${f.label}" has no usable key.';
    if (!keys.add(f.key)) return 'Two fields have the key "${f.key}".';
    if (f.role != PermitFieldRole.none && !roles.add(f.role)) return 'Only one field can be "${f.role.label}".';
    if ((f.role == PermitFieldRole.validFrom || f.role == PermitFieldRole.validUntil) && !f.isDate) {
      return '"${f.role.label}" must be a date field.';
    }
  }
  return null;
}

/// Who uploads a permit.
enum PermitUploader {
  admin('admin', 'Admin only'),
  driver('driver', 'Driver only'),
  either('either', 'Driver or admin');

  const PermitUploader(this.wire, this.label);
  final String wire;
  final String label;
  static PermitUploader parse(Object? v) =>
      PermitUploader.values.firstWhere((u) => u.wire == _s(v), orElse: () => PermitUploader.admin);
}

/// A permit type of one country (`permit_types`).
class PermitType {
  const PermitType({
    this.id,
    required this.country,
    required this.key,
    required this.name,
    this.nameLocal = '',
    this.shortName = '',
    this.issuer = '',
    this.forDriver = false,
    this.partnerTypes = const [],
    this.services = const [],
    this.fields = const [],
    this.uploader = PermitUploader.admin,
    this.shownToPassengers = true,
    this.required = false,
    this.documentId,
    this.renewalText = '',
    this.position = 0,
    this.active = true,
  });

  factory PermitType.fromRow(Map<String, dynamic> r) => PermitType(
    id: r['id'] as String?,
    country: _s(r['country']),
    key: _s(r['key']),
    name: _s(r['name']),
    nameLocal: _s(r['name_local']),
    shortName: _s(r['short_name']),
    issuer: _s(r['issuer']),
    forDriver: _s(r['applies_to']) == 'driver',
    partnerTypes: _list(r['partner_types']),
    services: _list(r['services']),
    fields: parsePermitFields(r['fields']),
    uploader: PermitUploader.parse(r['uploader']),
    shownToPassengers: _b(r['shown_to_passengers'], true),
    required: _b(r['required']),
    documentId: _s(r['document_id']).isEmpty ? null : _s(r['document_id']),
    renewalText: _s(r['renewal_text']),
    position: (r['position'] as num?)?.toInt() ?? 0,
    active: _b(r['active'], true),
  );

  final String? id;
  final String country;
  final String key;
  final String name;
  final String nameLocal;
  final String shortName;
  final String issuer;
  final bool forDriver;
  final List<String> partnerTypes;
  final List<String> services;
  final List<PermitField> fields;
  final PermitUploader uploader;
  final bool shownToPassengers;
  final bool required;

  /// The Required Document a driver permit is uploaded as.
  final String? documentId;
  final String renewalText;
  final int position;
  final bool active;

  Map<String, dynamic> toRow() => {
    'country': country,
    'key': key,
    'name': name.trim(),
    'name_local': nameLocal.trim(),
    'short_name': shortName.trim(),
    'issuer': issuer.trim(),
    'applies_to': forDriver ? 'driver' : 'vehicle',
    'partner_types': partnerTypes,
    'services': services,
    'fields': [for (final f in fields) f.toJson()],
    'uploader': uploader.wire,
    'shown_to_passengers': shownToPassengers,
    'required': required,
    'document_id': forDriver ? documentId : null,
    'renewal_text': renewalText.trim(),
    'position': position,
    'active': active,
  };
}

/// A permit type key from its name: "Taxi driver permit" > `taxi-driver-permit`.
String permitTypeKey(String name) {
  final k = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  final cut = k.length > 40 ? k.substring(0, 40).replaceAll(RegExp(r'-+$'), '') : k;
  return cut.isEmpty ? 'permit' : cut;
}

/// Why a permit type can't be saved, or null.
String? permitTypeProblem(PermitType t) {
  if (t.name.trim().isEmpty) return 'Enter the permit name.';
  if (t.country.trim().isEmpty) return 'Choose the country.';
  if (!RegExp(r'^[a-z0-9-]{1,40}$').hasMatch(t.key)) return 'The permit needs a short key (letters, numbers, dashes).';
  if (t.forDriver && t.uploader != PermitUploader.admin && (t.documentId ?? '').isEmpty) {
    return 'Choose the document drivers upload this permit as.';
  }
  return permitFieldsProblem(t.fields);
}

// ---- Status ----------------------------------------------------------------

/// A vehicle's permit status.
enum PermitStatus {
  withPermit('with', 'With permit'),
  without('without', 'Without'),
  bypass('bypass', 'Bypass'),
  expired('expired', 'Expired'),
  none('none', 'Not required');

  const PermitStatus(this.wire, this.label);
  final String wire;
  final String label;

  static PermitStatus parse(Object? v) =>
      PermitStatus.values.firstWhere((s) => s.wire == _s(v), orElse: () => PermitStatus.none);
}

/// One permit's state: `with`, `expired`, `pending` or `without`.
String permitDocState(String? status, DateTime? expiry, DateTime today) {
  final t = DateTime(today.year, today.month, today.day);
  if (status == null || status == 'Rejected') return 'without';
  if (status == 'Expired' || (expiry != null && expiry.isBefore(t))) return 'expired';
  if (status == 'Approved') return 'with';
  return 'pending';
}

/// The vehicle's status from its permits' ([required], state) and its
/// bypass, as the server works it out (vehicle_permit_status).
PermitStatus vehiclePermitStatus(
  List<({bool required, String state})> permits, {
  DateTime? bypassUntil,
  required DateTime now,
}) {
  final req = permits.where((p) => p.required).toList();
  if (req.isEmpty) return PermitStatus.none;
  final expired = req.any((p) => p.state == 'expired');
  final missing = req.any((p) => p.state != 'with' && p.state != 'expired');
  if (!expired && !missing) return PermitStatus.withPermit;
  if (bypassUntil != null && bypassUntil.isAfter(now)) return PermitStatus.bypass;
  return expired ? PermitStatus.expired : PermitStatus.without;
}

/// Days from [today] to [date] (negative once past), or null.
int? daysUntil(DateTime? date, DateTime today) => date == null
    ? null
    : DateTime(date.year, date.month, date.day).difference(DateTime(today.year, today.month, today.day)).inDays;

DateTime? _date(Object? v) {
  final s = _s(v);
  if (s.isEmpty) return null;
  return DateTime.tryParse(s);
}

/// A field with its value on one permit.
class PermitFieldValue {
  const PermitFieldValue({required this.field, this.value});
  factory PermitFieldValue.fromJson(Map<String, dynamic> j) =>
      PermitFieldValue(field: PermitField.fromJson(j), value: _s(j['value']).isEmpty ? null : _s(j['value']));
  final PermitField field;
  final String? value;

  /// The value as shown: a date in the user's order.
  String get shown => value == null ? '—' : (field.isDate ? formatStoredDateForUser(value) : value!);
}

/// One permit as the server hands it out (ride_permits, my_permits, the
/// admin's cards): its type's words, its state, fields and file.
class PermitItem {
  const PermitItem({
    required this.typeId,
    required this.name,
    this.nameLocal = '',
    this.shortName = '',
    this.issuer = '',
    this.forDriver = false,
    this.fields = const [],
    this.bucket,
    this.path,
    this.fileUrl,
    this.state = 'with',
    this.validUntil,
    this.renewalText = '',
    this.uploader = PermitUploader.admin,
    this.required = false,
    this.enforce = false,
    this.warnDays,
    this.documentId,
    this.status,
  });

  factory PermitItem.fromJson(Map<String, dynamic> j) => PermitItem(
    typeId: _s(j['type_id']),
    name: _s(j['name']),
    nameLocal: _s(j['name_local']),
    shortName: _s(j['short_name']),
    issuer: _s(j['issuer']),
    forDriver: _s(j['applies_to']) == 'driver',
    fields: [
      if (j['fields'] is List)
        for (final f in j['fields'] as List)
          if (f is Map) PermitFieldValue.fromJson(f.cast<String, dynamic>()),
    ],
    bucket: _s(j['bucket']).isEmpty ? null : _s(j['bucket']),
    path: _s(j['path']).isEmpty ? null : _s(j['path']),
    fileUrl: _s(j['file_url']).isEmpty ? null : _s(j['file_url']),
    state: _s(j['state']).isEmpty ? 'with' : _s(j['state']),
    validUntil: _date(j['valid_until']),
    renewalText: _s(j['renewal_text']),
    uploader: PermitUploader.parse(j['uploader']),
    required: _b(j['required']),
    enforce: _b(j['enforce']),
    warnDays: (j['warn_days'] as num?)?.toInt(),
    documentId: _s(j['document_id']).isEmpty ? null : _s(j['document_id']),
    status: _s(j['status']).isEmpty ? null : _s(j['status']),
  );

  final String typeId;
  final String name;
  final String nameLocal;
  final String shortName;
  final String issuer;
  final bool forDriver;
  final List<PermitFieldValue> fields;
  final String? bucket;
  final String? path;
  final String? fileUrl;
  final String state;
  final DateTime? validUntil;
  final String renewalText;
  final PermitUploader uploader;
  final bool required;
  final bool enforce;

  /// How many days before expiry the driver is warned (the reminder days).
  final int? warnDays;
  final String? documentId;
  final String? status;

  bool get hasFile => bucket != null && path != null;

  /// The renewal line with the issuer in it ("GET.ride is renewing it with APAD.").
  String get renewalLine => renewalText.replaceAll('{issuer}', issuer).trim();

  String? fieldValue(PermitFieldRole role) => fields.where((f) => f.field.role == role).firstOrNull?.value;
}

/// The small button on a ride's driver card: the permit's short name when
/// there is one permit, "Permits" for several; null for none (a vehicle on
/// bypass shows none).
String? permitButtonLabel(List<PermitItem> items) {
  if (items.isEmpty) return null;
  if (items.length > 1) return 'Permits';
  final p = items.single;
  return p.shortName.isNotEmpty ? p.shortName : p.name;
}

/// The permit sheet's title.
String permitSheetTitle(List<PermitItem> items) =>
    items.length == 1 ? items.single.name : 'Permits';

/// The driver's badge for one permit: its words and how serious it is.
enum PermitBadgeTone { ok, warn, bad }

({String text, PermitBadgeTone tone}) permitBadge(PermitItem p, DateTime today, {DateTime? bypassUntil}) {
  if (p.state == 'with') {
    final d = daysUntil(p.validUntil, today);
    if (d != null && d <= (p.warnDays ?? 0)) {
      return (text: d == 0 ? 'Expires today' : 'Expires in $d ${d == 1 ? 'day' : 'days'}', tone: PermitBadgeTone.warn);
    }
    return (text: 'Permit valid', tone: PermitBadgeTone.ok);
  }
  if (bypassUntil != null && bypassUntil.isAfter(today)) {
    return (text: 'Bypass until ${formatDateForUser(bypassUntil.toLocal())}', tone: PermitBadgeTone.warn);
  }
  return switch (p.state) {
    'expired' => (text: 'Permit expired', tone: PermitBadgeTone.bad),
    'pending' => (text: 'Waiting for review', tone: PermitBadgeTone.warn),
    _ => (text: 'No permit yet', tone: PermitBadgeTone.bad),
  };
}

/// The banner over the driver's permit: expiring soon, or (where the
/// country requires permits) expired / missing; null when all is well.
({String title, String body, bool blocked})? driverPermitBanner(
  PermitItem p,
  DateTime today, {
  DateTime? bypassUntil,
  String? plate,
}) {
  final until = p.validUntil;
  if (p.state == 'with') {
    final d = daysUntil(until, today);
    if (d == null || d > (p.warnDays ?? 0)) return null;
    final renew = p.uploader == PermitUploader.admin ? p.renewalLine : '';
    return (
      title: 'Your ${p.name} expires on ${formatDateForUser(until)}.',
      body: [
        if (renew.isNotEmpty) renew,
        if (p.uploader == PermitUploader.admin) 'The new permit will appear here.' else 'Upload the renewed permit in Documents.',
      ].join(' '),
      blocked: false,
    );
  }
  if (bypassUntil != null && bypassUntil.isAfter(today)) return null;
  if (!p.required || !p.enforce) return null;
  final expired = p.state == 'expired';
  final what = expired ? '${p.name} expired' : 'No ${p.name}';
  final renew = p.uploader == PermitUploader.admin ? p.renewalLine : '';
  return (
    title: "$what: you can't go online for rides${plate == null || plate.isEmpty ? '' : ' with $plate'}.",
    body: [
      if (p.uploader == PermitUploader.admin) ...[
        if (renew.isNotEmpty) renew,
        "You'll be notified when it's uploaded.",
      ] else
        'Upload it in Documents.',
    ].join(' '),
    blocked: true,
  );
}

/// The admin list's note under a vehicle.
({String text, bool highlight}) permitListNote({
  required PermitStatus status,
  required List<PermitItem> permits,
  DateTime? bypassUntil,
  DateTime? joinedAt,
  required DateTime today,
}) {
  final req = permits.where((p) => p.required).toList();
  switch (status) {
    case PermitStatus.withPermit:
      final dates = [for (final p in req) if (p.validUntil != null) p.validUntil!]..sort();
      if (dates.isEmpty) return (text: 'valid', highlight: false);
      final first = dates.first;
      final d = daysUntil(first, today)!;
      final warn = req.firstWhere((p) => p.validUntil == first).warnDays ?? 0;
      if (d <= warn) return (text: d == 0 ? 'expires today' : 'expires in $d ${d == 1 ? 'day' : 'days'}', highlight: true);
      return (text: 'valid until ${formatDateForUser(first)}', highlight: false);
    case PermitStatus.bypass:
      final left = bypassUntil?.difference(today).inHours;
      final days = left == null ? null : (left / 24).ceil();
      return (
        text: 'pass ends ${bypassUntil == null ? '' : formatDateForUser(bypassUntil.toLocal())}'
            '${days == null ? '' : ' ($days ${days == 1 ? 'day' : 'days'} left)'}',
        highlight: true,
      );
    case PermitStatus.expired:
      final e = req.where((p) => p.state == 'expired').map((p) => p.validUntil).whereType<DateTime>().firstOrNull;
      final blocks = req.any((p) => p.enforce);
      return (
        text: 'expired${e == null ? '' : ' ${formatDateForUser(e)}'}${blocks ? ' · cannot take rides' : ''}',
        highlight: true,
      );
    case PermitStatus.without:
      if (req.any((p) => p.state == 'pending')) return (text: 'waiting for review', highlight: false);
      final d = joinedAt == null ? null : -daysUntil(joinedAt, today)!;
      return (
        text: d == null ? 'no permit yet' : 'joined ${d <= 0 ? 'today' : '$d ${d == 1 ? 'day' : 'days'} ago'}',
        highlight: false,
      );
    case PermitStatus.none:
      return (text: 'no permit required', highlight: false);
  }
}

/// Whether the plate read off a permit is the vehicle's (spaces, dashes and
/// case aside); null when either is unknown.
bool? platesMatch(String? onPermit, String? vehicle) {
  String n(String? s) => (s ?? '').replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
  final a = n(onPermit), b = n(vehicle);
  if (a.isEmpty || b.isEmpty) return null;
  return a == b;
}

// ---- Plate colours -----------------------------------------------------------

/// A plate's background and text colour.
typedef PlateColours = ({Color bg, Color fg});

Color? parseHexColour(Object? v) {
  final s = _s(v).replaceFirst('#', '');
  if (!RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(s)) return null;
  return Color(0xFF000000 | int.parse(s, radix: 16));
}

String hexOf(Color c) {
  String two(double x) => (x * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#${two(c.r)}${two(c.g)}${two(c.b)}';
}

/// `{bg, fg}` as stamped on a ride, or null.
PlateColours? plateColoursFromJson(Object? v) {
  if (v is! Map) return null;
  final bg = parseHexColour(v['bg']), fg = parseHexColour(v['fg']);
  return bg == null || fg == null ? null : (bg: bg, fg: fg);
}

/// One line of a country's plate colour list: a partner type or an energy.
class PlateColourRule {
  const PlateColourRule({required this.match, required this.bg, required this.fg});
  final String match;
  final String bg;
  final String fg;
}

/// A country's plate colours: by partner type first (a taxi), then by
/// energy, then [other].
class PlateColourSettings {
  const PlateColourSettings({this.types = const [], this.energies = const [], this.other});

  factory PlateColourSettings.fromJson(Object? v) {
    if (v is! Map) return const PlateColourSettings();
    List<PlateColourRule> rules(Object? l, String key) => [
      if (l is List)
        for (final e in l)
          if (e is Map) PlateColourRule(match: _s(e[key]), bg: _s(e['bg']), fg: _s(e['fg'])),
    ];
    final o = v['other'];
    return PlateColourSettings(
      types: rules(v['types'], 'type'),
      energies: rules(v['energies'], 'energy'),
      other: o is Map ? PlateColourRule(match: '', bg: _s(o['bg']), fg: _s(o['fg'])) : null,
    );
  }

  final List<PlateColourRule> types;
  final List<PlateColourRule> energies;
  final PlateColourRule? other;

  bool get isEmpty => types.isEmpty && energies.isEmpty && other == null;

  Map<String, dynamic> toJson() => {
    'types': [for (final r in types) {'type': r.match, 'bg': r.bg, 'fg': r.fg}],
    'energies': [for (final r in energies) {'energy': r.match, 'bg': r.bg, 'fg': r.fg}],
    if (other != null) 'other': {'bg': other!.bg, 'fg': other!.fg},
  };
}

String _typeKey(String s) => s.toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '');

/// The plate's colours for a vehicle with partner [types] and [energy] under
/// [settings] (permit_plate_colours on the server); null when the country
/// has no colour list, so the plate keeps its plain look.
PlateColours? plateColoursFor(PlateColourSettings settings, {List<String> types = const [], String? energy}) {
  PlateColours? of(PlateColourRule r) {
    final bg = parseHexColour(r.bg), fg = parseHexColour(r.fg);
    return bg == null || fg == null ? null : (bg: bg, fg: fg);
  }

  final keys = {for (final t in types) _typeKey(t)};
  for (final r in settings.types) {
    if (keys.contains(_typeKey(r.match))) return of(r);
  }
  final e = (energy ?? '').trim().toLowerCase();
  if (e.isNotEmpty) {
    for (final r in settings.energies) {
      if (r.match.trim().toLowerCase() == e) return of(r);
    }
  }
  return settings.other == null ? null : of(settings.other!);
}

/// A country's settings (`permit_country_settings`).
class PermitCountrySettings {
  const PermitCountrySettings({
    required this.country,
    this.enforce = false,
    this.bypassDays = 3,
    this.plateColours,
    this.texts = const {},
  });

  factory PermitCountrySettings.fromRow(Map<String, dynamic> r) => PermitCountrySettings(
    country: _s(r['country']),
    enforce: _b(r['enforce']),
    bypassDays: (r['bypass_days'] as num?)?.toInt() ?? 3,
    plateColours: r['plate_colours'] == null ? null : PlateColourSettings.fromJson(r['plate_colours']),
    texts: r['texts'] is Map ? (r['texts'] as Map).map((k, v) => MapEntry('$k', _s(v))) : const {},
  );

  /// The row every country without its own uses.
  static const everyCountry = '*';

  final String country;
  final bool enforce;
  final int bypassDays;

  /// Null: the '*' row's colours.
  final PlateColourSettings? plateColours;
  final Map<String, String> texts;
}

/// [country]'s settings: its own row, else '*', else the defaults.
PermitCountrySettings settingsFor(List<PermitCountrySettings> rows, String? country) {
  final c = (country ?? '').trim().toLowerCase();
  return rows.where((r) => c.isNotEmpty && r.country.trim().toLowerCase() == c).firstOrNull ??
      rows.where((r) => r.country == PermitCountrySettings.everyCountry).firstOrNull ??
      PermitCountrySettings(country: country ?? PermitCountrySettings.everyCountry);
}

/// The colours that apply in [country]: its own list, else '*''s.
PlateColourSettings plateSettingsFor(List<PermitCountrySettings> rows, String? country) =>
    settingsFor(rows, country).plateColours ??
    rows.where((r) => r.country == PermitCountrySettings.everyCountry).firstOrNull?.plateColours ??
    const PlateColourSettings();

// ---- Reminder days ---------------------------------------------------------

/// "45, 30, 15 3,1" > [45, 30, 15, 3, 1]: whole days, largest first, each
/// once; null with a reason when it can't be read.
({List<int>? days, String? error}) parseReminderDays(String text) {
  final parts = text.split(RegExp(r'[\s,;]+')).where((p) => p.isNotEmpty).toList();
  final out = <int>{};
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 400) return (days: null, error: '"$p" is not a number of days from 0 to 400.');
    out.add(n);
  }
  if (out.length > 20) return (days: null, error: 'At most 20 reminder days.');
  return (days: out.toList()..sort((a, b) => b.compareTo(a)), error: null);
}

String reminderDaysText(List<int> days) => days.join(', ');

/// Where a reminder list applies.
enum ReminderScope {
  defaultDays('default', 'Default'),
  country('country', 'Country'),
  permitType('permit_type', 'Permit type'),
  document('document', 'Document');

  const ReminderScope(this.wire, this.label);
  final String wire;
  final String label;
  static ReminderScope parse(Object? v) =>
      ReminderScope.values.firstWhere((s) => s.wire == _s(v), orElse: () => ReminderScope.defaultDays);
}

class ReminderDays {
  const ReminderDays({this.id, required this.scope, this.scopeKey = '', required this.days});
  factory ReminderDays.fromRow(Map<String, dynamic> r) => ReminderDays(
    id: r['id'] as String?,
    scope: ReminderScope.parse(r['scope']),
    scopeKey: _s(r['scope_key']),
    days: [for (final d in (r['days'] as List?) ?? const []) (d as num).toInt()],
  );
  final String? id;
  final ReminderScope scope;
  final String scopeKey;
  final List<int> days;
}

/// The days that apply: the permit type's, else the document's, else the
/// country's, else the default (document_reminder_days_for).
List<int> reminderDaysFor(List<ReminderDays> rows, {String? country, String? permitTypeId, String? documentId}) {
  List<int>? of(ReminderScope s, String? key) {
    if (s != ReminderScope.defaultDays && (key == null || key.isEmpty)) return null;
    return rows
        .where((r) => r.scope == s && (s == ReminderScope.defaultDays ||
            (s == ReminderScope.country ? r.scopeKey.toLowerCase() == key!.toLowerCase() : r.scopeKey == key)))
        .firstOrNull
        ?.days;
  }

  return of(ReminderScope.permitType, permitTypeId) ??
      of(ReminderScope.document, documentId) ??
      of(ReminderScope.country, country) ??
      of(ReminderScope.defaultDays, null) ??
      const [];
}

/// The country Admin → Vehicle permits opens on: the link's, else the
/// admin's own ([homeCode], an ISO code from their profile or phone, see
/// `userDateCountry`) when it is one of [typeCountries] or [countries], else
/// the first with permit types, else the first in the list.
String? permitsStartCountry({
  String? linked,
  required Iterable<String> typeCountries,
  required List<String> countries,
  String? homeCode,
}) {
  if ((linked ?? '').trim().isNotEmpty) return linked;
  final home = (homeCode ?? '').trim().toUpperCase();
  if (home.isNotEmpty) {
    for (final c in [...typeCountries, ...countries]) {
      if (countryCodeFor(c) == home) return c;
    }
  }
  return typeCountries.firstOrNull ?? countries.firstOrNull;
}
