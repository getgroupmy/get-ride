/// The taxi driver permit card (Expo `utils/driverPermitSource.ts` and the
/// permit card + Start Pickup checks in `app/partner-teksi.tsx`).
///
/// The permit is the partner's uploaded `provider_documents` row for the
/// required document the admin tagged "Taxi Driver Permit display"
/// (`required_document.values.isTaxiPermit`), falling back to any upload the
/// AI check read as a taxi permit. Its fields come from that check
/// (`ai_verification.extracted.taxiPermit`), then the row's own columns, then
/// the partner / profile. Unlike Expo, a missing photo is left empty rather
/// than replaced by a stock portrait of a stranger, and an unrelated upload
/// is never shown as the permit.
library;

/// One permit, as drawn on the card.
class DriverPermit {
  const DriverPermit({
    this.name,
    this.driverType,
    this.icNumber,
    this.permitIcNumber,
    this.profileIcCandidates = const [],
    this.permitNumber,
    this.vehiclePlate,
    this.licenceClass,
    this.company = 'TEKSI',
    this.address,
    this.issueDate,
    this.expiryDate,
    this.photoUrl,
    this.documentId,
    this.documentName,
    this.documentStatus,
    this.fileUrl,
  });

  final String? name;
  final String? driverType;

  /// The IC shown on the card: the permit's, else the profile's.
  final String? icNumber;

  /// The IC read off the permit itself, compared with the profile.
  final String? permitIcNumber;
  final List<String> profileIcCandidates;
  final String? permitNumber;
  final String? vehiclePlate;
  final String? licenceClass;
  final String company;
  final String? address;
  final DateTime? issueDate;
  final DateTime? expiryDate;
  final String? photoUrl;

  /// The `provider_documents` row the card was read from, if any.
  final String? documentId;
  final String? documentName;
  final String? documentStatus;
  final String? fileUrl;

  bool get hasDocument => documentId != null;
}

String? _s(Object? v) {
  if (v is! String) return null;
  final t = v.trim();
  return t.isEmpty || t == '—' || t == '-' ? null : t;
}

String? _first(Iterable<Object?> vs) {
  for (final v in vs) {
    final s = _s(v);
    if (s != null) return s;
  }
  return null;
}

DateTime? _date(Object? v) {
  final s = _s(v);
  if (s == null) return null;
  final d = DateTime.tryParse(s);
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : const {};

/// The upload that is this partner's permit: the one for the tagged required
/// document, else one the AI check read as a taxi permit, else none.
Map<String, dynamic>? pickPermitDocument(
  List<({String id, Map<String, dynamic> values})> requiredDocs,
  List<Map<String, dynamic>> uploads,
) {
  final tagged = requiredDocs.where((d) => d.values['isTaxiPermit'] == true).map((d) => d.id).toSet();
  for (final u in uploads) {
    if (tagged.contains(u['doc_id'])) return u;
  }
  for (final u in uploads) {
    final ex = _map(_map(u['ai_verification'])['extracted']);
    if (ex['taxiPermit'] is Map) return u;
  }
  return null;
}

/// Builds the card from the partner and profile rows and the permit upload.
DriverPermit resolveDriverPermit({
  Map<String, dynamic>? profile,
  Map<String, dynamic>? partner,
  Map<String, dynamic>? document,
}) {
  final p = profile ?? const {};
  final pr = partner ?? const {};
  final doc = document ?? const {};
  final ex = _map(_map(doc['ai_verification'])['extracted']);
  final tp = _map(ex['taxiPermit']);
  final numbers = ex['documentNumbers'] is List ? ex['documentNumbers'] as List : const [];

  final candidates = <String>[];
  for (final c in [pr['ic'], p['ic']]) {
    final s = _s(c);
    if (s != null && !candidates.contains(s)) candidates.add(s);
  }
  final permitIc = _s(tp['idNumber']);

  String? up(String? v) => v?.toUpperCase();
  return DriverPermit(
    name: up(_first([tp['name'], pr['name'], p['name']])),
    driverType: up(_s(tp['driverType'])),
    icNumber: permitIc ?? (candidates.isEmpty ? null : candidates.first),
    permitIcNumber: permitIc,
    profileIcCandidates: candidates,
    permitNumber: _first([tp['licenceReferenceNumber'], doc['document_number'], ex['documentNumber'], ...numbers]),
    vehiclePlate: up(_s(tp['vehicleNumber'])),
    licenceClass: up(_first([tp['licenceClass'], ex['documentName'], doc['detected_document_name']])),
    company: up(_s(tp['companyName'])) ?? 'TEKSI',
    address: _first([tp['address'], pr['address'], p['address']]),
    issueDate: _date(tp['validityFrom']) ?? _date(doc['start_date']) ?? _date(ex['startDate']),
    expiryDate: _date(tp['validityTo']) ?? _date(doc['expiry_date']) ?? _date(ex['expiryDate']),
    photoUrl: _first([tp['photoUrl'], pr['avatar_url'], p['avatar_url'], p['profile_image']]),
    documentId: _s(doc['id']),
    documentName: _s(doc['doc_name']),
    documentStatus: _s(doc['status']),
    fileUrl: _s(doc['file_url']),
  );
}

String _norm(String? v) => (v ?? '').replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toLowerCase();

/// Days from [today] to the permit's expiry (negative once expired), or null.
int? daysToExpiry(DriverPermit p, DateTime today) {
  final e = p.expiryDate;
  if (e == null) return null;
  return e.difference(DateTime(today.year, today.month, today.day)).inDays;
}

/// Why a hire should not start on this permit.
enum PermitBlock { icMismatch, expired, plateMismatch }

/// The first check the permit fails before a pickup (Expo
/// `validateIcAndExpiry` + `platesMismatch`), or null. Each check only
/// blocks when both sides are known, so incomplete data never blocks.
PermitBlock? permitStartBlock(DriverPermit p, {required DateTime today, String? vehiclePlate}) {
  final permitIc = _norm(p.permitIcNumber);
  final profile = p.profileIcCandidates.map(_norm).where((c) => c.isNotEmpty).toList();
  if (permitIc.isNotEmpty && profile.isNotEmpty && !profile.contains(permitIc)) return PermitBlock.icMismatch;
  final days = daysToExpiry(p, today);
  if (days != null && days < 0) return PermitBlock.expired;
  final permitPlate = _norm(p.vehiclePlate);
  final plate = _norm(vehiclePlate);
  if (permitPlate.isNotEmpty && plate.isNotEmpty && permitPlate != plate) return PermitBlock.plateMismatch;
  return null;
}

/// What to tell the driver about [block].
String permitBlockMessage(PermitBlock block, DriverPermit p, {String? vehiclePlate}) => switch (block) {
  PermitBlock.icMismatch =>
    'The IC number on your taxi driver permit (${p.permitIcNumber}) does not match your profile '
        '(${p.profileIcCandidates.join(' / ')}). Update your documents so they match.',
  PermitBlock.expired => 'Your taxi driver permit has expired. Renew it and upload the new permit.',
  PermitBlock.plateMismatch =>
    'The vehicle you are driving (${vehiclePlate ?? '—'}) is not the one on your permit '
        '(${p.vehiclePlate}). Choose the matching vehicle.',
};
