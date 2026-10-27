// Partner application review (0289): every detail and document of an
// application as a line the admin approves, rejects (with a reason) or
// edits (with a note and the new value), and what the driver sees of it on
// "Changes needed". Pure: the lines come from the rows, the decisions from
// `partner_review_items`.
//
// A line's key says what it is and where it lives on the server
// (partner_review_value / partner_review_apply, migration 0289):
//   details.photo / name / birth_date / address / nationality / id_number,
//   id.front / id.back, company.document / name / reg_no / type / reg_date /
//   address, permit.photos / card_no / valid_until, services, vehicle.grant /
//   photos / authorisation / agreement / plate / make / model / year / color /
//   engine_number / vin / registration_date / engine_cc / owner,
//   doc:provider:<required document id>, doc:vehicle:<required document id>,
//   vpermit:<permit type id>.
library;

import '../admin/screens/people/people_logic.dart' show parseStringList;
import 'date_order.dart' show formatStoredDateForUser;
import 'document_text.dart' show IdDocType;
import 'partner_onboarding.dart' show OnboardingStep;

/// The groups, in the order the admin and the driver read them.
enum ReviewGroup {
  details('details', 'Your details'),
  nationalId('national_id', 'National ID'),
  company('company', 'Your company'),
  driverPermit('driver_permit', 'Driver permit'),
  services('services', 'Partner Service type'),
  vehicle('vehicle', 'Vehicle'),
  vehicleDocs('vehicle_documents', 'Vehicle documents'),
  serviceDocs('service_documents', 'Service documents'),
  vehiclePermits('vehicle_permits', 'Vehicle permits');

  const ReviewGroup(this.key, this.label);

  /// The value kept in `partner_review_items.item_group`.
  final String key;
  final String label;

  static ReviewGroup? parse(Object? v) => values.where((g) => g.key == '$v').firstOrNull;
}

enum ReviewState {
  approved,
  rejected,
  edited;

  static ReviewState? parse(Object? v) => values.where((s) => s.name == '$v').firstOrNull;
}

/// How an admin edits a line (partner_review_edit_type on the server).
enum ReviewEdit { none, text, date, integer, services, note }

const _textKeys = {
  'details.name', 'details.address', 'details.nationality', 'details.id_number',
  'company.name', 'company.reg_no', 'company.type', 'company.address', 'permit.card_no',
  'vehicle.plate', 'vehicle.make', 'vehicle.model', 'vehicle.year', 'vehicle.color',
  'vehicle.engine_number', 'vehicle.vin', 'vehicle.owner',
};
const _dateKeys = {'details.birth_date', 'company.reg_date', 'permit.valid_until', 'vehicle.registration_date'};

ReviewEdit reviewEditFor(String key) {
  if (_textKeys.contains(key)) return ReviewEdit.text;
  if (_dateKeys.contains(key)) return ReviewEdit.date;
  if (key == 'vehicle.engine_cc') return ReviewEdit.integer;
  if (key == 'services') return ReviewEdit.services;
  if (key.startsWith('vpermit:')) return ReviewEdit.note;
  return ReviewEdit.none;
}

/// A vehicle permit is GET.ride's upload: the driver can't fix it, so it is
/// never rejected back to them.
bool reviewCanReject(String key) => !key.startsWith('vpermit:');

/// The admin's decision on one line, as stored.
class ReviewItem {
  const ReviewItem({
    required this.key,
    required this.group,
    required this.label,
    required this.state,
    this.note,
    this.oldValue,
    this.newValue,
    this.sentAt,
    this.fixedAt,
    this.keptAt,
  });

  factory ReviewItem.fromRow(Map<String, dynamic> r) => ReviewItem(
        key: '${r['item_key'] ?? ''}',
        group: ReviewGroup.parse(r['item_group']) ?? ReviewGroup.details,
        label: '${r['label'] ?? ''}'.trim(),
        state: ReviewState.parse(r['state']) ?? ReviewState.approved,
        note: _text(r['note']),
        oldValue: r['old_value'],
        newValue: r['new_value'],
        sentAt: DateTime.tryParse('${r['sent_at'] ?? ''}'),
        fixedAt: DateTime.tryParse('${r['fixed_at'] ?? ''}'),
        keptAt: DateTime.tryParse('${r['kept_at'] ?? ''}'),
      );

  final String key;
  final ReviewGroup group;
  final String label;
  final ReviewState state;
  final String? note;
  final Object? oldValue;
  final Object? newValue;
  final DateTime? sentAt;

  /// The driver changed it since it was sent back (the server's).
  final DateTime? fixedAt;

  /// The driver kept the admin's edit as it is.
  final DateTime? keptAt;

  bool get fixed => fixedAt != null;

  /// A rejected line the driver still has to fix.
  bool get blocking => state == ReviewState.rejected && !fixed;
}

String? _text(Object? v) {
  final t = v is String ? v.trim() : (v == null ? '' : '$v'.trim());
  return t.isEmpty || t == 'null' ? null : t;
}

/// A value from the server (a jsonb: text, a date, a number, a list of
/// services or of files) as the line shows it.
String reviewValueText(String key, Object? value) {
  if (value == null) return '—';
  if (value is List) {
    final parts = [for (final v in value) if (_text(v) != null) _text(v)!];
    if (key == 'services') return parts.isEmpty ? '—' : parts.join(', ');
    return '${parts.length} of ${value.length} added';
  }
  if (value is Map) {
    final number = _text(value['document_number']);
    final expiry = _text(value['expiry_date']);
    return [
      ?number,
      if (expiry != null) 'valid until ${formatStoredDateForUser(expiry)}',
    ].join(' · ').ifEmpty(_text(value['file_url']) == null ? 'Not uploaded' : 'Uploaded');
  }
  final t = _text(value);
  if (t == null) return '—';
  if (_dateKeys.contains(key)) return formatStoredDateForUser(t);
  if (key == 'vehicle.engine_cc') return '$t cc';
  return t;
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// One line of an application, built from its rows.
class ReviewLine {
  const ReviewLine({
    required this.key,
    required this.group,
    required this.label,
    this.value,
    this.editValue,
    this.files = const [],
    this.faceKey,
    this.liveness,
    this.docStatus,
    this.flag,
  });

  final String key;
  final ReviewGroup group;
  final String label;

  /// What it says now, for reading.
  final String? value;

  /// What an edit starts from (a stored date as yyyy-mm-dd, the services).
  final Object? editValue;

  /// Photos and files to open.
  final List<String> files;

  /// The document_face_checks row to show (`doc_kind:doc_id`).
  final String? faceKey;

  /// How the profile photo was taken (partners.selfie_liveness).
  final String? liveness;

  /// The document's own status (Approved / Pending Review / Rejected).
  final String? docStatus;

  /// Something for the admin to look at (an ID number that doesn't match).
  final String? flag;

  ReviewEdit get edit => reviewEditFor(key);
}

String? _url(Object? v) {
  final t = _text(v);
  return t != null && (t.startsWith('http') || t.contains('/')) ? t : null;
}

/// The newest row of each document (by `doc_id`), in name order.
List<Map<String, dynamic>> _newestDocs(Iterable<Map<String, dynamic>> rows) {
  final byDoc = <String, Map<String, dynamic>>{};
  for (final r in rows) {
    final id = '${r['doc_id'] ?? ''}';
    if (id.isEmpty) continue;
    final had = byDoc[id];
    if (had == null || '${r['uploaded_at'] ?? ''}'.compareTo('${had['uploaded_at'] ?? ''}') > 0) byDoc[id] = r;
  }
  return byDoc.values.toList()..sort((a, b) => '${a['doc_name']}'.compareTo('${b['doc_name']}'));
}

String _docValue(Map<String, dynamic> d) => reviewValueText('doc', {
      'document_number': d['document_number'],
      'expiry_date': d['expiry_date'],
      'file_url': d['file_url'],
    });

/// The review's flag for an ID number other accounts share: "Same ID as
/// another account: U0012" (or "as other accounts: U0012, U0040").
String sameIdFlag(List<String> displayIds) => displayIds.length == 1
    ? 'Same ID as another account: ${displayIds.single}'
    : 'Same ID as other accounts: ${displayIds.join(', ')}';

/// Every line of the application: [profile] and [partner] rows, the
/// registration [vehicle] (or null), the partner's [providerDocs], the
/// vehicle's [vehicleDocs] (vehicle permits among them, by
/// `permit_type_id`) and its [serviceStatuses] (vehicle_service_status).
/// [sameIdAccounts] are the display ids of other accounts with the same ID
/// number (0299 `admin_same_ic_accounts`), flagged on the ID number.
List<ReviewLine> applicationReviewLines({
  required Map<String, dynamic>? profile,
  required Map<String, dynamic> partner,
  Map<String, dynamic>? vehicle,
  List<Map<String, dynamic>> providerDocs = const [],
  List<Map<String, dynamic>> vehicleDocs = const [],
  List<Map<String, dynamic>> serviceStatuses = const [],
  List<String> sameIdAccounts = const [],
}) {
  String? p(String k) => _text(profile?[k]);
  String? a(String k) => _text(partner[k]);
  String? v(String k) => _text(vehicle?[k]);
  ReviewLine field(ReviewGroup g, String key, String label, String? raw, {String? flag}) => ReviewLine(
        key: key,
        group: g,
        label: label,
        value: reviewValueText(key, raw),
        editValue: raw,
        flag: flag,
      );

  final idType = IdDocType.parse(profile?['id_type']);
  final sides = (idType ?? IdDocType.mykad).photoSides;
  final idName = idType?.label ?? 'ID';
  final photo = _url(profile?['avatar_url']) ?? _url(partner['avatar_url']);
  final typed = p('id_number_typed'), read = p('id_number_read');
  final idFlags = [
    if (profile?['id_mismatch'] == true) 'Typed ${typed ?? '—'}, read off the ID ${read ?? '—'}: they differ',
    if (sameIdAccounts.isNotEmpty) sameIdFlag(sameIdAccounts),
  ];

  final lines = <ReviewLine>[
    ReviewLine(
      key: 'details.photo',
      group: ReviewGroup.details,
      label: 'Profile photo',
      value: photo == null ? 'No photo yet' : null,
      files: [?photo],
      liveness: a('selfie_liveness'),
    ),
    field(ReviewGroup.details, 'details.name', 'Full name', p('name') ?? a('name'),
        flag: p('id_name') != null && p('id_name')!.toUpperCase() != (p('name') ?? '').toUpperCase()
            ? 'Name on the ID: ${p('id_name')}'
            : null),
    field(ReviewGroup.details, 'details.birth_date', 'Date of birth', p('birth_date')),
    field(ReviewGroup.details, 'details.address', 'Address', p('address') ?? a('address')),
    field(ReviewGroup.details, 'details.nationality', 'Nationality', p('nationality')),
    field(ReviewGroup.details, 'details.id_number', '$idName number', p('ic') ?? a('ic'),
        flag: idFlags.isEmpty ? null : idFlags.join(' · ')),
    ReviewLine(
      key: 'id.front',
      group: ReviewGroup.nationalId,
      label: '$idName ${sides.$1.toLowerCase()} photo',
      value: _url(profile?['id_image']) == null ? 'Not added' : null,
      files: [?_url(profile?['id_image'])],
      faceKey: profile?['id'] == null ? null : 'national_id:${profile!['id']}',
    ),
    ReviewLine(
      key: 'id.back',
      group: ReviewGroup.nationalId,
      label: '$idName ${sides.$2.toLowerCase()} photo',
      value: _url(profile?['id_image_back']) == null ? 'Not added' : null,
      files: [?_url(profile?['id_image_back'])],
    ),
  ];

  if (a('company_document_url') != null || a('company_name') != null) {
    final director = partner['company_driver_is_director'];
    lines.addAll([
      ReviewLine(
        key: 'company.document',
        group: ReviewGroup.company,
        label: 'Company registration document',
        files: [?_url(partner['company_document_url'])],
        value: _url(partner['company_document_url']) == null ? 'Not added' : null,
        flag: director == false ? 'The driver is not listed as a director or owner' : null,
      ),
      field(ReviewGroup.company, 'company.name', 'Company name', a('company_name')),
      field(ReviewGroup.company, 'company.reg_no', 'Registration no.', a('company_reg_no')),
      field(ReviewGroup.company, 'company.type', 'Company type', a('company_type')),
      field(ReviewGroup.company, 'company.reg_date', 'Registration date', a('company_reg_date')),
      field(ReviewGroup.company, 'company.address', 'Business address', a('company_address')),
    ]);
  }

  if (a('driver_permit_front_url') != null || a('driver_permit_card_no') != null) {
    final flags = parseStringList(partner['driver_permit_flags']);
    lines.addAll([
      ReviewLine(
        key: 'permit.photos',
        group: ReviewGroup.driverPermit,
        label: 'Driver permit photos',
        files: [?_url(partner['driver_permit_front_url']), ?_url(partner['driver_permit_back_url'])],
        faceKey: 'driver_permit:${partner['id']}',
        flag: flags.isEmpty ? null : 'Checks the driver confirmed although they failed: ${flags.join(', ')}',
      ),
      field(ReviewGroup.driverPermit, 'permit.card_no', 'Permit number', a('driver_permit_card_no')),
      field(ReviewGroup.driverPermit, 'permit.valid_until', 'Valid until', a('driver_permit_valid_until')),
    ]);
  }

  final types = parseStringList(partner['partner_types']);
  lines.add(ReviewLine(
    key: 'services',
    group: ReviewGroup.services,
    label: 'Services',
    value: types.isEmpty ? '—' : types.join(', '),
    editValue: types,
  ));

  if (vehicle != null) {
    final owner = v('owner_match');
    lines.addAll([
      ReviewLine(
        key: 'vehicle.grant',
        group: ReviewGroup.vehicle,
        label: 'Vehicle grant',
        files: [?_url(vehicle['grant_front_url']), ?_url(vehicle['grant_back_url'])],
        value: _url(vehicle['grant_front_url']) == null ? 'Not added' : null,
      ),
      field(ReviewGroup.vehicle, 'vehicle.plate', 'Plate', v('plate')),
      field(ReviewGroup.vehicle, 'vehicle.make', 'Make', v('make')),
      field(ReviewGroup.vehicle, 'vehicle.model', 'Model', v('model')),
      field(ReviewGroup.vehicle, 'vehicle.year', 'Year made', v('year')),
      field(ReviewGroup.vehicle, 'vehicle.color', 'Colour', v('color')),
      field(ReviewGroup.vehicle, 'vehicle.engine_number', 'Engine no.', v('engine_number')),
      field(ReviewGroup.vehicle, 'vehicle.vin', 'Chassis no.', v('vin')),
      field(ReviewGroup.vehicle, 'vehicle.registration_date', 'Registration date', v('registration_date')),
      field(ReviewGroup.vehicle, 'vehicle.engine_cc', 'Engine capacity', v('engine_cc')),
      field(ReviewGroup.vehicle, 'vehicle.owner', 'Registered owner', v('grant_owner_name'),
          flag: owner == 'other' ? 'Owned by someone else' : null),
      ReviewLine(
        key: 'vehicle.photos',
        group: ReviewGroup.vehicle,
        label: 'Vehicle photos',
        files: [
          for (final k in const ['image_front', 'image_left', 'image_right', 'image_back']) ?_url(vehicle[k]),
        ],
      ),
      if (owner == 'other' || _url(vehicle['authorisation_letter_url']) != null)
        ReviewLine(
          key: 'vehicle.authorisation',
          group: ReviewGroup.vehicle,
          label: 'Authorisation letter from the owner',
          files: [?_url(vehicle['authorisation_letter_url'])],
          value: _url(vehicle['authorisation_letter_url']) == null ? 'Not added' : null,
        ),
      if (_url(vehicle['hire_agreement_url']) != null)
        ReviewLine(
          key: 'vehicle.agreement',
          group: ReviewGroup.vehicle,
          label: 'Rental / hire-purchase agreement',
          files: [_url(vehicle['hire_agreement_url'])!],
        ),
    ]);
  }

  ReviewLine doc(String kind, ReviewGroup g, Map<String, dynamic> d) => ReviewLine(
        key: 'doc:$kind:${d['doc_id']}',
        group: g,
        label: _text(d['doc_name']) ?? 'Document',
        value: _docValue(d),
        files: [?_url(d['file_url']), ?_url(d['file_url_back'])],
        faceKey: '${kind}_document:${d['id']}',
        docStatus: _text(d['status']),
      );

  lines.addAll([
    for (final d in _newestDocs(vehicleDocs.where((d) => _text(d['permit_type_id']) == null)))
      doc('vehicle', ReviewGroup.vehicleDocs, d),
    for (final d in _newestDocs(providerDocs)) doc('provider', ReviewGroup.serviceDocs, d),
  ]);

  // Vehicle permits: what each service waits for, and GET.ride's uploads.
  final permits = <String, ReviewLine>{};
  for (final s in serviceStatuses) {
    final type = _text(s['permit_type']);
    if (type == null) continue;
    permits['vpermit:$type'] = ReviewLine(
      key: 'vpermit:$type',
      group: ReviewGroup.vehiclePermits,
      label: '${_text(s['permit_name']) ?? 'Vehicle permit'} · uploaded by GET.ride',
      value: s['status'] == 'waiting_permit' ? 'Waiting for GET.ride to upload it' : 'Uploaded',
    );
  }
  for (final d in _newestByPermit(vehicleDocs)) {
    final key = 'vpermit:${d['permit_type_id']}';
    permits[key] = ReviewLine(
      key: key,
      group: ReviewGroup.vehiclePermits,
      label: '${_text(d['doc_name']) ?? 'Vehicle permit'} · uploaded by GET.ride',
      value: _docValue(d),
      files: [?_url(d['file_url'])],
      docStatus: _text(d['status']),
    );
  }
  lines.addAll(permits.values);
  return lines;
}

List<Map<String, dynamic>> _newestByPermit(Iterable<Map<String, dynamic>> rows) {
  final by = <String, Map<String, dynamic>>{};
  for (final r in rows) {
    final t = _text(r['permit_type_id']);
    if (t == null) continue;
    final had = by[t];
    if (had == null || '${r['uploaded_at'] ?? ''}'.compareTo('${had['uploaded_at'] ?? ''}') > 0) by[t] = r;
  }
  return by.values.toList();
}

/// The lines by group, in the groups' order (empty groups left out).
List<(ReviewGroup, List<T>)> reviewGroups<T>(Iterable<T> lines, ReviewGroup Function(T) groupOf) => [
      for (final g in ReviewGroup.values)
        if (lines.where((l) => groupOf(l) == g).toList() case final list when list.isNotEmpty) (g, list),
    ];

/// How the admin's side of the application stands.
class ReviewTally {
  const ReviewTally({this.approved = 0, this.rejected = 0, this.edited = 0, this.open = 0});
  final int approved, rejected, edited, open;

  /// Every line decided and none rejected: the application can be approved.
  bool get canApprove => rejected == 0 && open == 0;

  /// At least one line rejected: it goes back to the driver.
  bool get canSendBack => rejected > 0;

  String get summary => [
        '$approved approved',
        if (rejected > 0) '$rejected rejected',
        if (edited > 0) '$edited edited',
        if (open > 0) '$open to check',
      ].join(' · ');
}

/// [lines] against the decisions in [items] (a line changed by the driver
/// since it was decided counts as still to check).
ReviewTally reviewTally(List<ReviewLine> lines, Map<String, ReviewItem> items) {
  var approved = 0, rejected = 0, edited = 0, open = 0;
  for (final l in lines) {
    final i = items[l.key];
    if (i == null || i.fixed) {
      open++;
      continue;
    }
    switch (i.state) {
      case ReviewState.approved:
        approved++;
      case ReviewState.rejected:
        rejected++;
      case ReviewState.edited:
        edited++;
    }
  }
  return ReviewTally(approved: approved, rejected: rejected, edited: edited, open: open);
}

/// The admin's line status: "Approved", "Rejected: reason", "Edited: note",
/// "Not checked yet".
String reviewAdminStatus(ReviewItem? i) => switch (i?.state) {
      null => 'Not checked yet',
      _ when i!.fixed => 'Changed by the driver: check it again',
      ReviewState.approved => 'Approved',
      ReviewState.rejected => 'Rejected: ${i.note ?? ''}',
      ReviewState.edited => 'Edited: ${i.note ?? ''}',
    };

// ---- The driver's side --------------------------------------------------------------------------

/// The driver's line status, as on "Changes needed".
String reviewDriverStatus(ReviewItem i) {
  if (i.fixed) return 'Fixed · will be sent with your application';
  return switch (i.state) {
    ReviewState.approved => 'Approved',
    ReviewState.rejected => 'Rejected: ${i.note ?? ''}',
    ReviewState.edited => 'Changed by admin: ${i.note ?? ''}',
  };
}

/// How many rejected lines are left to fix.
int reviewItemsLeft(Iterable<ReviewItem> items) => items.where((i) => i.blocking).length;

/// "Send for review again" unlocks once every rejected line is fixed.
bool reviewCanResend(Iterable<ReviewItem> items) => reviewItemsLeft(items) == 0;

/// What the driver does about a line: the button's words, whether it takes
/// a photo, and the registration step that does it (null: nothing to open).
typedef ReviewFix = ({String label, bool photo, OnboardingStep? step});

ReviewFix reviewFixFor(String key) {
  if (key == 'details.photo') return (label: 'Retake photo', photo: true, step: OnboardingStep.avatar);
  if (key.startsWith('details.')) return (label: 'Edit', photo: false, step: OnboardingStep.details);
  if (key.startsWith('id.')) return (label: 'Retake photo', photo: true, step: OnboardingStep.id);
  if (key == 'company.document') return (label: 'Upload again', photo: false, step: OnboardingStep.company);
  if (key.startsWith('company.')) return (label: 'Edit', photo: false, step: OnboardingStep.company);
  if (key == 'permit.photos') return (label: 'Retake photo', photo: true, step: OnboardingStep.driverPermit);
  if (key.startsWith('permit.')) return (label: 'Edit', photo: false, step: OnboardingStep.driverPermit);
  if (key == 'services') return (label: 'Change services', photo: false, step: OnboardingStep.partnerType);
  if (key == 'vehicle.photos') return (label: 'Retake photo', photo: true, step: OnboardingStep.vehicle);
  if (const {'vehicle.grant', 'vehicle.authorisation', 'vehicle.agreement'}.contains(key)) {
    return (label: 'Upload again', photo: false, step: OnboardingStep.vehicle);
  }
  if (key.startsWith('vehicle.')) return (label: 'Edit', photo: false, step: OnboardingStep.vehicle);
  if (key.startsWith('doc:vehicle:')) return (label: 'Upload again', photo: false, step: OnboardingStep.vehicleDocs);
  if (key.startsWith('doc:provider:')) return (label: 'Upload again', photo: false, step: OnboardingStep.requirements);
  return (label: 'View', photo: false, step: null);
}

/// Where the fix opens in the app.
String? reviewFixRoute(String key) {
  final step = reviewFixFor(key).step;
  return step == null ? null : '/drive/onboarding?step=${step.key}';
}

// ---- Who viewed and decided what (0296) ---------------------------------------------------------

/// One row of `partner_review_log`: a view of a line's document, a
/// decision, a return to pending, or the partner approved.
class ReviewLogEntry {
  const ReviewLogEntry({required this.itemKey, required this.action, this.actorId, required this.at});

  final String itemKey;

  /// viewed, approved, rejected, edited, pending or partner_approved.
  final String action;
  final String? actorId;
  final DateTime at;

  static ReviewLogEntry? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final at = DateTime.tryParse('${raw['at'] ?? ''}');
    final key = '${raw['item_key'] ?? ''}';
    final action = '${raw['action'] ?? ''}';
    if (at == null || key.isEmpty || action.isEmpty) return null;
    final actor = raw['actor_id'];
    return ReviewLogEntry(itemKey: key, action: action, actorId: actor == null ? null : '$actor', at: at.toLocal());
  }

  /// "Viewed", "Passed", "Rejected", "Edited", "Back to pending".
  String get label => switch (action) {
        'viewed' => 'Viewed',
        'approved' => 'Passed',
        'rejected' => 'Rejected',
        'edited' => 'Edited',
        'pending' => 'Back to pending',
        'partner_approved' => 'Partner approved',
        _ => action,
      };
}

/// What the log says about one line: how many times its document was
/// viewed, the last viewer, and whether [me] viewed it since it last went
/// back to pending (what deciding it needs).
typedef ReviewViews = ({int count, String? lastBy, DateTime? lastAt, bool mine});

ReviewViews reviewViewsFor(String key, List<ReviewLogEntry> log, String? me) {
  final mineLine = [for (final e in log) if (e.itemKey == key) e];
  final views = [for (final e in mineLine) if (e.action == 'viewed') e];
  DateTime? since;
  for (final e in mineLine) {
    if (e.action == 'pending' && (since == null || e.at.isAfter(since))) since = e.at;
  }
  final mine = me != null && views.any((e) => e.actorId == me && (since == null || e.at.isAfter(since)));
  final last = views.isEmpty ? null : views.last;
  return (count: views.length, lastBy: last?.actorId, lastAt: last?.at, mine: mine);
}

/// Whether a line is decided only once its document has been opened: one
/// with something to view.
bool reviewNeedsView(ReviewLine l) => l.files.isNotEmpty;
