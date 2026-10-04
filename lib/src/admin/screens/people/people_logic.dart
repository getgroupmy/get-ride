/// Pure rules for the People add/edit forms and the user ID-document review,
/// ported from the Expo screens (`admin-user-edit`, `admin-partner-add/edit`,
/// `admin-vehicle-add/edit`, `admin-documents-users`) and the components they
/// use (`ServiceAreaPicker`, `PartnerTypePicker`, `RequiredDocsChecklist`,
/// `RequiredDocsUploader`, `VehicleMakeModelPicker`) plus the
/// `providerDocumentsStore` / `vehicleDocumentsStore` helpers.
library;

import 'dart:convert';

/// Token a required-document / partner-type list uses for "every type".
const allToken = '__ALL__';

// ---- Users -----------------------------------------------------------------

/// Status chips on the Expo user edit form (`deleted` is not offered there:
/// `user_status` has no such value).
const userEditStatuses = <String, String>{
  'approved': 'Approved',
  'unapproved': 'Unapproved',
  'blocked': 'Blocked',
  'rejected': 'Rejected',
  'unapproved-docs': 'Docs Pending',
};

const genders = <String, String>{'male': 'Male', 'female': 'Female', 'other': 'Other'};

/// `profiles.profile_status` for an admin UserStatus (Expo `upsertUser`).
String profileStatusFor(String status) => switch (status) {
      'approved' => 'Approved',
      'blocked' => 'Blocked',
      'rejected' => 'Rejected',
      'deleted' => 'Deleted',
      _ => 'Un-Approved',
    };

String? _blankToNull(String? v) {
  final t = v?.trim() ?? '';
  return t.isEmpty ? null : t;
}

/// Validation shared by the Expo user add/edit forms.
String? validateUserForm({required String name, required String phone}) =>
    name.trim().isEmpty || phone.trim().isEmpty ? 'Please fill in name and phone at minimum.' : null;

/// The `profiles` patch the Expo edit form writes through `upsertUser`.
/// An empty email is stored as "-" exactly like Expo.
Map<String, dynamic> userProfilePatch({
  required String name,
  required String phone,
  required String email,
  required String ic,
  required String address,
  required String nationality,
  required String birthDate,
  required String referralCode,
  required String? gender,
  required String? profileImage,
  required String? idImage,
  required String status,
  required bool documentsOk,
}) =>
    {
      'name': name.trim(),
      'phone': phone.trim(),
      'email': email.trim().isEmpty ? '-' : email.trim(),
      'ic': _blankToNull(ic),
      'address': _blankToNull(address),
      'nationality': _blankToNull(nationality),
      'birth_date': _blankToNull(birthDate),
      'referral_code': _blankToNull(referralCode),
      'gender': gender,
      'profile_image': _blankToNull(profileImage),
      'id_image': _blankToNull(idImage),
      // `user_status` has no "deleted"; keep the column valid.
      'status': status == 'deleted' ? 'unapproved' : status,
      'profile_status': profileStatusFor(status),
      'documents_ok': documentsOk,
    };

/// The editable status for a stored profile row (Expo `mapProfileStatus`),
/// restricted to the values the edit form offers.
String editableUserStatus(Map<String, dynamic> row) {
  final ps = '${row['profile_status'] ?? ''}'.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  final s = switch (ps) {
    'approved' => 'approved',
    'un-approved' || 'unapproved' => 'unapproved',
    'blocked' => 'blocked',
    'rejected' => 'rejected',
    'deleted' => 'deleted',
    _ => (row['status'] as String?) ?? 'unapproved',
  };
  if (s == 'unapproved' && row['status'] == 'unapproved-docs') return 'unapproved-docs';
  return s;
}

bool isValidIsoDate(String v) {
  final t = v.trim();
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(t)) return false;
  final d = DateTime.tryParse(t);
  return d != null && d.toIso8601String().startsWith(t);
}

// ---- User ID documents -----------------------------------------------------

const idStatusTabs = ['Pending', 'Verified', 'Failed', 'Expired', 'All'];

/// Expo `displayStatus`: an expired `id_expiry_date` wins over the stored
/// verdict.
String idDisplayStatus(Map<String, dynamic> row, {DateTime? now}) {
  final exp = DateTime.tryParse('${row['id_expiry_date'] ?? ''}');
  final expired = exp != null && exp.isBefore(now ?? DateTime.now());
  final v = row['id_verified'];
  if (v == 'Expired' || expired) return 'Expired';
  if (v == 'Verified') return 'Verified';
  if (v == 'Failed') return 'Failed';
  return 'Pending';
}

bool isPdfUri(String? u) => u != null && u.toLowerCase().split('?').first.endsWith('.pdf');

/// A rejection must carry a reason (Expo `handleDecide`).
String? validateIdDecision(String decision, String notes) =>
    decision == 'Failed' && notes.trim().isEmpty ? 'Please add a short note explaining the rejection.' : null;

Map<String, int> idStatusCounts(Iterable<Map<String, dynamic>> rows, {DateTime? now}) {
  final c = {'Verified': 0, 'Failed': 0, 'Pending': 0, 'Expired': 0};
  for (final r in rows) {
    final s = idDisplayStatus(r, now: now);
    c[s] = c[s]! + 1;
  }
  return c;
}

/// Profile edit from the ID review sheet (blank → null, like Expo).
Map<String, dynamic> idProfilePatch({
  required String name,
  required String phone,
  required String email,
  required String ic,
  required String nationality,
  required bool documentsOk,
  required String idExpiry,
}) =>
    {
      'name': _blankToNull(name),
      'phone': _blankToNull(phone),
      'email': _blankToNull(email),
      'ic': _blankToNull(ic),
      'nationality': _blankToNull(nationality),
      'documents_ok': documentsOk,
      'id_expiry_date': _blankToNull(idExpiry),
    };

// ---- Storage paths ---------------------------------------------------------

/// Expo `edit-profile` `safeSeg`.
String safeSegment(String s) =>
    s.replaceAll(RegExp(r'[^A-Za-z0-9_+\-]'), '_').replaceAll(RegExp(r'_+'), '_');

String _ddmmyyyy(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}${d.month.toString().padLeft(2, '0')}${d.year}';

/// `ID_Image` bucket path: `<Country>/<phone>_<idNumber>_<ddmmyyyy>.<ext>`.
String idImagePath({required String country, required String phone, required String idNumber, required String ext, DateTime? now}) =>
    '${safeSegment(country.trim().isEmpty ? 'Unknown' : country.trim())}/'
    '${safeSegment(phone)}_${safeSegment(idNumber)}_${_ddmmyyyy(now ?? DateTime.now())}.$ext';

/// `avatars` bucket path: `<Country>/<phone>_<name>_<ddmmyyyy>.<ext>`.
String avatarPath({required String country, required String phone, required String name, required String ext, DateTime? now}) {
  final n = safeSegment(name.trim().toLowerCase());
  return '${safeSegment(country.trim().isEmpty ? 'Unknown' : country.trim())}/'
      '${safeSegment(phone)}_${n.isEmpty ? 'user' : n}_${_ddmmyyyy(now ?? DateTime.now())}.$ext';
}

/// `provider-documents` / `vehicle-documents` path:
/// `<ownerId>/<docId>/<side>-<ms>.<ext>`.
String docFilePath(String ownerId, String docId, String side, String ext, {int? ms}) =>
    '$ownerId/$docId/$side-${ms ?? DateTime.now().millisecondsSinceEpoch}.$ext';

/// `vehicle-documents` photo path: `<vehicleId>/photos/<slot>-<ms>.<ext>`.
String vehiclePhotoPath(String vehicleId, String slot, String ext, {int? ms}) =>
    '$vehicleId/photos/$slot-${ms ?? DateTime.now().millisecondsSinceEpoch}.$ext';

/// Expo `guessExt` (unknown → png).
String guessExt(String name) {
  final l = name.toLowerCase().split('?').first;
  if (l.endsWith('.jpg') || l.endsWith('.jpeg')) return 'jpg';
  if (l.endsWith('.webp')) return 'webp';
  if (l.endsWith('.gif')) return 'gif';
  if (l.endsWith('.pdf')) return 'pdf';
  return 'png';
}

String contentTypeFor(String ext) => switch (ext) {
      'jpg' => 'image/jpeg',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'pdf' => 'application/pdf',
      _ => 'image/png',
    };

// ---- Display ids -----------------------------------------------------------

/// `PR-` / `VH-` + the last six digits of the epoch millis (Expo
/// `addPartner` / `addVehicle`).
String newDisplayId(String prefix, {int? ms}) {
  final s = '${ms ?? DateTime.now().millisecondsSinceEpoch}';
  return '$prefix-${s.substring(s.length - 6)}';
}

// ---- Service area ----------------------------------------------------------

/// Encoded keys: countries `country`, states `country|state`, cities
/// `country|state|city` (Expo `ServiceAreaValue`).
class ServiceArea {
  const ServiceArea({this.countries = const [], this.states = const [], this.cities = const []});

  factory ServiceArea.fromRow(Map<String, dynamic>? r) => ServiceArea(
        countries: _strings(r?['service_countries']),
        states: _strings(r?['service_states']),
        cities: _strings(r?['service_cities']),
      );

  final List<String> countries;
  final List<String> states;
  final List<String> cities;

  bool get complete => countries.isNotEmpty && states.isNotEmpty && cities.isNotEmpty;
  bool get isEmpty => countries.isEmpty && states.isEmpty && cities.isEmpty;

  Map<String, dynamic> toRow() => {
        'service_countries': countries,
        'service_states': states,
        'service_cities': cities,
      };

  /// Toggling a country prunes the states/cities outside the selection.
  ServiceArea toggleCountry(String c) {
    final next = countries.contains(c) ? countries.where((x) => x != c).toList() : [...countries, c];
    final ns = states.where((k) => next.contains(k.split('|').first)).toList();
    final nc = cities.where((k) {
      final p = k.split('|');
      return p.length >= 2 && next.contains(p[0]) && ns.contains('${p[0]}|${p[1]}');
    }).toList();
    return ServiceArea(countries: next, states: ns, cities: nc);
  }

  ServiceArea toggleState(String key) {
    final ns = states.contains(key) ? states.where((x) => x != key).toList() : [...states, key];
    final nc = cities.where((k) {
      final p = k.split('|');
      return p.length >= 2 && ns.contains('${p[0]}|${p[1]}');
    }).toList();
    return ServiceArea(countries: countries, states: ns, cities: nc);
  }

  ServiceArea toggleCity(String key) => ServiceArea(
        countries: countries,
        states: states,
        cities: cities.contains(key) ? cities.where((x) => x != key).toList() : [...cities, key],
      );

  /// `{country, state}` pairs for required-document region matching.
  List<({String country, String state})> statePairs() => [
        for (final s in states) splitStateKey(s, fallbackCountry: countries.firstOrNull ?? ''),
      ];
}

/// `country|state` → pair; a bare state takes [fallbackCountry] (Expo
/// partner screens). The Expo vehicle screens split on "," instead, which
/// never matches the stored `|` keys — this port uses `|` everywhere.
({String country, String state}) splitStateKey(String key, {String fallbackCountry = ''}) {
  final i = key.indexOf('|');
  if (i == -1) return (country: fallbackCountry, state: key.trim());
  return (country: key.substring(0, i).trim(), state: key.substring(i + 1).trim());
}

/// Last segment of an encoded key (chip label).
String areaLabel(String key) => key.split('|').last;

List<String> _strings(Object? v) => v is List ? v.map((e) => '$e').where((e) => e.isNotEmpty).toList() : const [];

/// Option lists for the service area picker: the admin geo tables plus any
/// value already in use, so editing never drops a stored selection.
class GeoOptions {
  const GeoOptions({this.countries = const [], this.states = const [], this.cities = const []});
  final List<String> countries;
  final List<String> states; // country|state
  final List<String> cities; // country|state|city

  static GeoOptions build({
    required Iterable<Map<String, dynamic>> countryRows,
    required Iterable<Map<String, dynamic>> stateRows,
    required Iterable<Map<String, dynamic>> cityRows,
    Iterable<ServiceArea> inUse = const [],
  }) {
    final c = <String>{}, s = <String>{}, ci = <String>{};
    String t(Object? v) => '${v ?? ''}'.trim();
    for (final r in countryRows) {
      if (t(r['name']).isNotEmpty) c.add(t(r['name']));
    }
    for (final r in stateRows) {
      if (t(r['country']).isEmpty || t(r['name']).isEmpty) continue;
      c.add(t(r['country']));
      s.add('${t(r['country'])}|${t(r['name'])}');
    }
    for (final r in cityRows) {
      if (t(r['country']).isEmpty || t(r['state']).isEmpty || t(r['name']).isEmpty) continue;
      c.add(t(r['country']));
      s.add('${t(r['country'])}|${t(r['state'])}');
      ci.add('${t(r['country'])}|${t(r['state'])}|${t(r['name'])}');
    }
    for (final a in inUse) {
      c.addAll(a.countries);
      s.addAll(a.states.where((k) => k.contains('|')));
      ci.addAll(a.cities.where((k) => k.split('|').length == 3));
    }
    int cmp(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());
    return GeoOptions(
      countries: c.toList()..sort(cmp),
      states: s.toList()..sort(cmp),
      cities: ci.toList()..sort(cmp),
    );
  }

  /// Adds [a]'s own selections so a stored value is always listed.
  GeoOptions including(ServiceArea a) => GeoOptions.build(
        countryRows: [for (final c in countries) {'name': c}],
        stateRows: const [],
        cityRows: const [],
        inUse: [ServiceArea(states: states, cities: cities), a],
      );

  List<String> statesFor(ServiceArea a) => states.where((k) => a.countries.contains(k.split('|').first)).toList();

  List<String> citiesFor(ServiceArea a) => cities.where((k) {
        final p = k.split('|');
        return a.states.contains('${p[0]}|${p[1]}');
      }).toList();
}

// ---- Partner types ---------------------------------------------------------

/// Expo accepts arrays or JSON-encoded arrays for list-valued settings.
List<String> parseStringList(Object? raw) {
  if (raw is List) return raw.map((e) => '$e').where((e) => e.isNotEmpty).toList();
  if (raw is String && raw.isNotEmpty) {
    try {
      final p = jsonDecode(raw);
      if (p is List) return p.map((e) => '$e').where((e) => e.isNotEmpty).toList();
    } catch (_) {}
  }
  return const [];
}

bool _truthy(Object? v, bool fallback) {
  if (v == null) return fallback;
  if (v is bool) return v;
  if (v is num) return v != 0;
  final s = '$v'.toLowerCase();
  return s == 'true' || s == '1' || s == 'yes';
}

/// Enabled partner types, defaults first then by name (`PartnerTypePicker`).
List<String> partnerTypeOptions(Iterable<Map<String, dynamic>> values) {
  final opts = values
      .map((v) => (name: '${v['name'] ?? ''}'.trim(), enabled: _truthy(v['enabled'], true), def: _truthy(v['isDefault'], false)))
      .where((o) => o.name.isNotEmpty && o.enabled)
      .toList()
    ..sort((a, b) => a.def != b.def ? (a.def ? -1 : 1) : a.name.compareTo(b.name));
  return opts.map((o) => o.name).toList();
}

List<Map<String, dynamic>> _selectedTypes(Iterable<Map<String, dynamic>> typeValues, List<String> selected) {
  final set = selected.map((s) => s.toLowerCase()).toSet();
  return typeValues.where((v) => set.contains('${v['name'] ?? ''}'.toLowerCase())).toList();
}

/// A vehicle is required when any selected partner type asks for one.
bool partnerTypesRequireVehicle(Iterable<Map<String, dynamic>> typeValues, List<String> selected) =>
    _selectedTypes(typeValues, selected).any((v) => _truthy(v['vehicleRequired'], false));

/// Union of the selected types' `docTypes`; null means "no filter".
List<String>? partnerTypeDocTypeIds(Iterable<Map<String, dynamic>> typeValues, List<String> selected) {
  final sel = _selectedTypes(typeValues, selected);
  if (sel.isEmpty) return null;
  final ids = <String>{for (final v in sel) ...parseStringList(v['docTypes'])};
  return ids.isEmpty ? null : ids.toList();
}

/// Expo partner add/edit save validation.
String? validatePartnerForm({
  required bool hasUser,
  required ServiceArea area,
  required List<String> partnerTypes,
  required bool vehicleRequired,
  required bool hasVehicle,
}) {
  if (!hasUser) return 'Please select a user to add as partner.';
  if (!area.complete) {
    return 'Please pick at least one country, state and city of service before choosing a partner type.';
  }
  if (partnerTypes.isEmpty) return 'Please select at least one partner type.';
  if (vehicleRequired && !hasVehicle) {
    return 'The selected partner type requires a vehicle. Pick one from the list or add a new vehicle.';
  }
  return null;
}

/// Vehicle-derived partner columns (Expo partner add/edit).
Map<String, dynamic> partnerVehicleColumns(Map<String, dynamic>? v) => {
      'vehicle': v == null ? '' : '${v['make'] ?? ''} ${v['model'] ?? ''}'.trim(),
      'plate': v == null ? '' : '${v['plate'] ?? ''}',
      'vehicle_type': v?['vehicle_type'],
      'make': v?['make'],
      'model': v?['model'],
    };

Map<String, dynamic> partnerTypeColumns(List<String> types) => {
      'partner_type': types.isEmpty ? null : types.join(','),
      'partner_types': types,
    };

/// Row inserted by Expo `addPartner` → `upsertPartner` (no `auth_user_id`:
/// the back office never owns a partner row).
Map<String, dynamic> newPartnerRow({
  required String id,
  required String displayId,
  required Map<String, dynamic> user,
  required Map<String, dynamic>? vehicle,
  required List<String> partnerTypes,
  required ServiceArea area,
  required bool autoApprove,
  required String joinedAt,
}) {
  String? opt(Object? v) {
    final s = '${v ?? ''}'.trim();
    return s.isEmpty || s == '-' ? null : s;
  }

  return {
    'id': id,
    'display_id': displayId,
    'name': '${user['name'] ?? ''}',
    'phone': '${user['phone'] ?? ''}',
    'email': opt(user['email']),
    'ic': opt(user['ic']),
    ...partnerVehicleColumns(vehicle),
    'energy_type': null,
    'year_from': null,
    'year_to': null,
    ...partnerTypeColumns(partnerTypes),
    ...area.toRow(),
    'permit_number': null,
    'status': autoApprove ? 'approved' : 'unapproved',
    'permit': 'none',
    'documents_ok': false,
    'rating': 0,
    'total_rides': 0,
    'joined_at': joinedAt,
  };
}

/// Users not already partners (matched on phone, Expo `eligibleUsers`).
List<Map<String, dynamic>> eligiblePartnerUsers(
  Iterable<Map<String, dynamic>> users,
  Iterable<Map<String, dynamic>> partners,
) {
  final phones = partners.map((p) => '${p['phone'] ?? ''}'.trim()).toSet();
  return users.where((u) => !phones.contains('${u['phone'] ?? ''}'.trim())).toList();
}

/// Vehicle quick-search (plate/make/model/owner), first 20.
List<Map<String, dynamic>> searchVehicles(Iterable<Map<String, dynamic>> vehicles, String query) {
  final q = query.trim().toLowerCase();
  final list = q.isEmpty
      ? vehicles.toList()
      : vehicles
          .where((v) => ['plate', 'make', 'model', 'owner_name'].any((k) => '${v[k] ?? ''}'.toLowerCase().contains(q)))
          .toList();
  return list.take(20).toList();
}

/// The partner's current vehicle: matched on plate (Expo partner edit).
Map<String, dynamic>? vehicleForPlate(Iterable<Map<String, dynamic>> vehicles, Object? plate) {
  final p = '${plate ?? ''}'.trim().toUpperCase();
  if (p.isEmpty) return null;
  for (final v in vehicles) {
    if ('${v['plate'] ?? ''}'.trim().toUpperCase() == p) return v;
  }
  return null;
}

// ---- Vehicles --------------------------------------------------------------

const permitOptions = <String, String>{
  'none': 'None',
  'pending': 'Pending',
  'non-verified': 'Non-verified',
  'verified': 'Verified',
};

const vehicleStatusOptions = <String, String>{
  'approved': 'Approved',
  'unapproved': 'Unapproved',
  'blocked': 'Blocked',
  'rejected': 'Rejected',
  'unapproved-docs': 'Docs Pending',
  'permit-pending': 'Permit Pending',
  'permit-non-verified': 'Permit Unverified',
  'permit-verified': 'Permit Verified',
};

const vehiclePhotoSlots = ['front', 'left', 'right', 'back'];

/// Status for a newly added vehicle (Expo `admin-vehicle-add`).
String newVehicleStatus({required bool autoApprove, required bool documentsOk, required String permit}) {
  if (autoApprove) return 'approved';
  if (!documentsOk) return 'unapproved-docs';
  return switch (permit) {
    'pending' => 'permit-pending',
    'non-verified' => 'permit-non-verified',
    'verified' => 'permit-verified',
    _ => 'unapproved',
  };
}

String? validateVehicleForm({
  required String plate,
  required String? make,
  required String? model,
  required String ownerName,
  required String ownerPhone,
}) {
  if (plate.trim().isEmpty || (make ?? '').trim().isEmpty || (model ?? '').trim().isEmpty) {
    return 'Please select a vehicle and fill in plate number.';
  }
  if (ownerName.trim().isEmpty || ownerPhone.trim().isEmpty) return "Please fill in the owner's name and phone.";
  return null;
}

/// `vehicle` columns written by Expo `vehicleToRow` (add & edit).
Map<String, dynamic> vehicleColumns({
  required String plate,
  required String make,
  required String model,
  required String? vehicleType,
  required String year,
  required String color,
  required String ownerName,
  required String ownerPhone,
  required String partnerDisplayId,
  required String? ownerPartnerUuid,
  required String status,
  required String permit,
  required bool documentsOk,
  required ServiceArea area,
}) =>
    {
      'plate': plate.trim().toUpperCase(),
      'make': make,
      'model': model,
      'year': _blankToNull(year),
      'color': _blankToNull(color),
      'vehicle_type': _blankToNull(vehicleType),
      'owner_name': ownerName.trim(),
      'owner_phone': ownerPhone.trim(),
      'owner_partner_display_id': _blankToNull(partnerDisplayId),
      'owner_partner_id': _blankToNull(ownerPartnerUuid),
      'status': status,
      'permit': permit,
      'documents_ok': documentsOk,
      ...area.toRow(),
    };

/// Partner owner suggestions for the owner-name field (first 4).
List<Map<String, dynamic>> partnerSuggestions(Iterable<Map<String, dynamic>> partners, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  return partners
      .where((p) => ['name', 'phone', 'display_id'].any((k) => '${p[k] ?? ''}'.toLowerCase().contains(q)))
      .take(4)
      .toList();
}

String _yearRange(String from, String to) {
  final f = from.trim(), t = to.trim();
  if (f.isEmpty && t.isEmpty) return '';
  if (f.isNotEmpty && t.isEmpty) return '($f ~)';
  if (f.isEmpty) return '(~ $t)';
  if (t == '~') return '($f ~)';
  return '($f - $t)';
}

/// Expo `formatVehicleLabel`: "Make Model (from - to)".
String formatVehicleLabel({String? make, String? model, String? yearFrom, String? yearTo}) {
  final parts = [make, model].where((s) => (s ?? '').isNotEmpty).join(' ');
  return [parts, _yearRange(yearFrom ?? '', yearTo ?? '')].where((s) => s.isNotEmpty).join(' ').trim();
}

// ---- Documents -------------------------------------------------------------

/// Expo `computeDisplayStatus`: past expiry reads Expired unless rejected.
String docDisplayStatus(Map<String, dynamic> row, {DateTime? now}) {
  final exp = DateTime.tryParse('${row['expiry_date'] ?? ''}');
  final status = '${row['status'] ?? 'Pending Review'}';
  if (exp != null && exp.isBefore(now ?? DateTime.now()) && status != 'Rejected') return 'Expired';
  return status;
}

class DocsApprovalCheck {
  const DocsApprovalCheck({
    this.total = 0,
    this.approved = 0,
    this.pending = 0,
    this.rejected = 0,
    this.expired = 0,
    this.failed = 0,
  });
  final int total, approved, pending, rejected, expired, failed;
  bool get hasAny => total > 0;
  bool get ok => hasAny && approved == total;

  /// Message when approving a vehicle is blocked, or null when allowed.
  String? blockMessage(String plate) {
    if (ok) return null;
    if (!hasAny) {
      return '$plate has no vehicle documents on file. Upload and approve the required documents first.';
    }
    final parts = [
      if (pending > 0) '$pending pending',
      if (rejected > 0) '$rejected rejected',
      if (expired > 0) '$expired expired',
      if (failed > 0) '$failed failed',
    ];
    final summary = parts.isEmpty ? '' : ' (${parts.join(', ')})';
    return '$approved/$total vehicle documents are approved$summary. Review and approve them before approving the vehicle.';
  }
}

/// Expo `checkVehicleDocsAllApproved` tally.
DocsApprovalCheck vehicleDocsCheck(Iterable<Map<String, dynamic>> rows, {DateTime? now}) {
  var total = 0, approved = 0, pending = 0, rejected = 0, expired = 0, failed = 0;
  for (final r in rows) {
    total++;
    switch (docDisplayStatus(r, now: now)) {
      case 'Approved':
        approved++;
      case 'Rejected':
        rejected++;
      case 'Expired':
        expired++;
      case 'Failed':
        failed++;
      default:
        pending++;
    }
  }
  return DocsApprovalCheck(
      total: total, approved: approved, pending: pending, rejected: rejected, expired: expired, failed: failed);
}

class DocFlags {
  const DocFlags({
    this.requireStartDate = false,
    this.requireExpiryDate = false,
    this.requireDocumentNumber = false,
    this.requireInsuranceProvider = false,
    this.isPwd = false,
    this.requireFrontBack = false,
    this.allowPdfUpload = false,
  });

  factory DocFlags.fromValues(Map<String, dynamic> v) => DocFlags(
        requireStartDate: _truthy(v['requireStartDate'], false),
        requireExpiryDate: _truthy(v['requireExpiryDate'], false),
        requireDocumentNumber: _truthy(v['requireDocumentNumber'], false),
        requireInsuranceProvider: _truthy(v['requireInsuranceProvider'], false),
        isPwd: _truthy(v['isPwd'], false),
        requireFrontBack: _truthy(v['requireFrontBack'], false),
        allowPdfUpload: _truthy(v['allowPdfUpload'], false),
      );

  final bool requireStartDate, requireExpiryDate, requireDocumentNumber, requireInsuranceProvider, isPwd,
      requireFrontBack, allowPdfUpload;
}

class RequiredDoc {
  const RequiredDoc({
    required this.id,
    required this.name,
    required this.description,
    required this.compulsory,
    required this.scope,
    required this.labels,
    required this.flags,
  });
  final String id, name, description;
  final bool compulsory;

  /// global / country / state / mixed
  final String scope;
  final List<String> labels;
  final DocFlags flags;
}

typedef _Region = ({String type, String country, String? state, bool compulsory});

List<_Region> _parseRegions(Object? raw) {
  List<Object?> list = const [];
  if (raw is List) {
    list = raw;
  } else if (raw is String && raw.isNotEmpty) {
    try {
      final p = jsonDecode(raw);
      if (p is List) list = p;
    } catch (_) {}
  }
  final out = <_Region>[];
  for (final r in list) {
    if (r is! Map) continue;
    final type = r['type'] == 'state' ? 'state' : 'country';
    final country = '${r['country'] ?? ''}'.trim();
    final state = '${r['state'] ?? ''}'.trim();
    if (country.isEmpty || (type == 'state' && state.isEmpty)) continue;
    out.add((type: type, country: country, state: type == 'state' ? state : null, compulsory: _truthy(r['compulsory'], true)));
  }
  return out;
}

String _regionsScope(List<_Region> rs) => rs.every((r) => r.type == 'country')
    ? 'country'
    : rs.every((r) => r.type == 'state')
        ? 'state'
        : 'mixed';

List<String> _regionLabels(List<_Region> rs) => [
      for (final r in rs.take(3)) r.type == 'country' ? r.country : '${r.state}, ${r.country}',
      if (rs.length > 3) '+${rs.length - 3} more',
    ];

/// Document-type ids whose name equals [name] (case-insensitive) — the
/// `docTypeFilter` prop of `RequiredDocsChecklist`.
List<String> docTypeIdsNamed(Iterable<({String id, Map<String, dynamic> values})> docTypes, String name) {
  final f = name.trim().toLowerCase();
  return [
    for (final t in docTypes)
      if ('${t.values['name'] ?? ''}'.trim().toLowerCase() == f) t.id,
  ];
}

/// Resolves the required documents that apply (Expo `RequiredDocsChecklist` /
/// `RequiredDocsUploader`, which share these rules). [docTypeIds] null (or
/// containing `__ALL__`) means no doc-type filter; [partnerTypeNames] null
/// means docs tagged by partner type are all shown, as on the admin screens.
List<RequiredDoc> resolveRequiredDocs(
  Iterable<({String id, Map<String, dynamic> values})> entries, {
  List<String>? docTypeIds,
  List<String>? partnerTypeNames,
  List<String> countries = const [],
  List<({String country, String state})> states = const [],
}) {
  final allowedTypes = docTypeIds == null || docTypeIds.isEmpty || docTypeIds.contains(allToken)
      ? null
      : docTypeIds.where((x) => x.isNotEmpty && x != allToken).toSet();
  final allowedPartnerTypes = partnerTypeNames == null || partnerTypeNames.contains(allToken)
      ? null
      : partnerTypeNames.map((x) => x.trim().toLowerCase()).where((x) => x.isNotEmpty).toSet();
  final ctxCountries = countries.map((c) => c.trim()).where((c) => c.isNotEmpty).toSet();
  final ctxStates = {
    for (final s in states)
      if (s.country.trim().isNotEmpty && s.state.trim().isNotEmpty) '${s.country.trim()}|${s.state.trim()}',
  };
  final hasContext = ctxCountries.isNotEmpty || ctxStates.isNotEmpty;

  final out = <RequiredDoc>[];
  for (final e in entries) {
    final v = e.values;
    if (!_truthy(v['active'], true)) continue;
    final name = '${v['name'] ?? ''}'.trim();
    if (name.isEmpty) continue;

    final docPartnerTypes = parseStringList(v['partnerTypes']);
    if (docPartnerTypes.isNotEmpty) {
      if (!docPartnerTypes.contains(allToken) && allowedPartnerTypes != null) {
        if (!docPartnerTypes.map((x) => x.trim().toLowerCase()).any(allowedPartnerTypes.contains)) continue;
      }
    } else if (allowedTypes != null) {
      final types = parseStringList(v['docTypes']);
      if (!types.contains(allToken) && !types.any(allowedTypes.contains)) continue;
    }

    final description = '${v['description'] ?? ''}'.trim();
    final isGlobal = _truthy(v['regionsGlobal'], true);
    final globalCompulsory = _truthy(v['regionsGlobalCompulsory'] ?? v['required'], true);
    final regions = _parseRegions(v['regions']);
    final flags = DocFlags.fromValues(v);
    RequiredDoc doc(bool compulsory, String scope, List<String> labels) => RequiredDoc(
        id: e.id, name: name, description: description, compulsory: compulsory, scope: scope, labels: labels, flags: flags);

    if (isGlobal) {
      out.add(doc(globalCompulsory, 'global', const ['Global']));
      continue;
    }
    if (!hasContext) {
      if (regions.isEmpty) continue;
      out.add(doc(regions.any((r) => r.compulsory), _regionsScope(regions), _regionLabels(regions)));
      continue;
    }
    final matches = regions
        .where((r) => r.type == 'country' ? ctxCountries.contains(r.country) : ctxStates.contains('${r.country}|${r.state}'))
        .toList();
    if (matches.isEmpty) continue;
    out.add(doc(matches.any((r) => r.compulsory), _regionsScope(matches), _regionLabels(matches)));
  }
  out.sort((a, b) => a.compulsory != b.compulsory ? (a.compulsory ? -1 : 1) : a.name.compareTo(b.name));
  return out;
}

/// Newest upload per `doc_id` (rows arrive newest first).
Map<String, Map<String, dynamic>> latestUploadByDoc(Iterable<Map<String, dynamic>> rows) {
  final m = <String, Map<String, dynamic>>{};
  for (final r in rows) {
    m.putIfAbsent('${r['doc_id']}', () => r);
  }
  return m;
}

/// "N uploaded · M compulsory left" (Expo uploader subtitle).
({int uploaded, int compulsoryLeft}) uploadProgress(List<RequiredDoc> docs, Map<String, Map<String, dynamic>> uploads) {
  bool counts(RequiredDoc d) {
    final u = uploads[d.id];
    if (u == null) return false;
    final s = docDisplayStatus(u);
    return s != 'Expired' && s != 'Rejected';
  }

  final compulsory = docs.where((d) => d.compulsory).length;
  final uploaded = docs.where(counts).length;
  return (uploaded: uploaded, compulsoryLeft: (compulsory - uploaded).clamp(0, compulsory));
}

/// Fields a document upload must collect, and whether they are filled
/// (Expo `DocumentUploadModal` steps).
String? validateDocUpload(
  DocFlags f, {
  required bool hasFront,
  required bool hasBack,
  required bool frontIsPdf,
  required String documentNumber,
  required String startDate,
  required String expiryDate,
  required String? insuranceProviderId,
}) {
  if (!hasFront) return 'Please upload the document image first.';
  if (f.requireFrontBack && !frontIsPdf && !hasBack) return 'Please upload the back of the document.';
  if (f.requireDocumentNumber && documentNumber.trim().isEmpty) return 'Please enter the document number.';
  if (f.requireStartDate && !isValidIsoDate(startDate)) return 'Please enter a valid start date (YYYY-MM-DD).';
  if (f.requireExpiryDate && !isValidIsoDate(expiryDate)) return 'Please enter a valid expiry date (YYYY-MM-DD).';
  if (f.requireInsuranceProvider && (insuranceProviderId ?? '').isEmpty) return 'Please choose the insurance provider.';
  return null;
}

/// `provider_documents` payload (Expo `upsertProviderDocument`): every fresh
/// upload resets the review to Pending Review.
Map<String, dynamic> providerDocPayload({
  required String partnerId,
  required String? authUserId,
  required String docId,
  required String docName,
  required DocFlags flags,
  required String documentNumber,
  required String? insuranceProviderId,
  required String? insuranceProviderName,
  required bool isPwd,
  required String startDate,
  required String expiryDate,
  required String fileUrl,
  required String? fileUrlBack,
  required String uploadedAt,
}) =>
    {
      'partner_id': partnerId,
      'auth_user_id': authUserId,
      'doc_id': docId,
      'doc_name': docName,
      'document_number': flags.requireDocumentNumber ? documentNumber.trim() : null,
      'insurance_provider_id': flags.requireInsuranceProvider ? insuranceProviderId : null,
      'insurance_provider_name': flags.requireInsuranceProvider ? insuranceProviderName : null,
      'is_pwd': flags.isPwd && isPwd,
      'start_date': flags.requireStartDate ? _blankToNull(startDate) : null,
      'expiry_date': flags.requireExpiryDate ? _blankToNull(expiryDate) : null,
      'file_url': fileUrl,
      'file_url_back': flags.requireFrontBack ? fileUrlBack : null,
      'ai_verification': null,
      'ai_verified': null,
      'issuance_country': null,
      'detected_document_name': null,
      'status': 'Pending Review',
      'reviewer_notes': null,
      'reviewed_at': null,
      'uploaded_at': uploadedAt,
    };
