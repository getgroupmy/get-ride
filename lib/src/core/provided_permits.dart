// Vehicle permits the country's GET.ride uploads for the partner — never the
// driver (0288, `vehicle_service_status`; see also `my_permits_screen.dart`).
// These are the admin-provided documents the review screen shows as
// "uploaded by GET.ride" (`partner_review.dart`, the `vpermit:*` group). This
// turns the raw status rows into read-only view-models so the same permits
// also appear on the partner's Documents page (onboarding) and, while they are
// still waiting, in the admin Documents "To review" queue — one source, one
// shape, both pages. Pure: the view-models come from the rows.
library;

/// Whether GET.ride has uploaded the permit yet.
enum ProvidedPermitState { waiting, onFile }

/// One vehicle permit GET.ride provides, for a service, with its state and the
/// plate it is for where known.
class ProvidedPermit {
  const ProvidedPermit({
    required this.service,
    required this.name,
    required this.state,
    this.plate,
    this.permitType,
  });

  final String service;
  final String name;
  final ProvidedPermitState state;
  final String? plate;
  final String? permitType;

  bool get waiting => state == ProvidedPermitState.waiting;

  /// What the driver / admin reads beside the permit.
  String get statusLine =>
      waiting ? 'Waiting for GET.ride to upload it' : 'Uploaded by GET.ride';
}

String? _text(Object? v) {
  final t = '${v ?? ''}'.trim();
  return t.isEmpty ? null : t;
}

/// The permits GET.ride provides, read from [serviceStatuses]
/// (`vehicle_service_status` rows). One per row that names a permit
/// (`permit_type` set — the others are plain age checks); `waiting_permit`
/// becomes [ProvidedPermitState.waiting], anything else is on file. [plate] is
/// attached to each when known. Ordered by service for a stable list.
List<ProvidedPermit> providedPermits(
  Iterable<Map<String, dynamic>> serviceStatuses, {
  String? plate,
}) {
  final out = <ProvidedPermit>[];
  for (final s in serviceStatuses) {
    final type = _text(s['permit_type']);
    final waiting = _text(s['status']) == 'waiting_permit';
    // A row names a permit when it has a permit_type; a waiting_permit row is
    // always a permit even on a pre-0301 database that left the type null.
    if (type == null && !waiting) continue;
    out.add(ProvidedPermit(
      service: _text(s['service']) ?? '',
      name: _text(s['permit_name']) ?? 'Vehicle permit',
      state: waiting ? ProvidedPermitState.waiting : ProvidedPermitState.onFile,
      plate: plate,
      permitType: type,
    ));
  }
  out.sort((a, b) => a.service.toLowerCase().compareTo(b.service.toLowerCase()));
  return out;
}

/// Just the permits still waiting for GET.ride to upload — what the admin
/// Documents "To review" queue shows that an uploaded file would not.
List<ProvidedPermit> waitingProvidedPermits(
  Iterable<Map<String, dynamic>> serviceStatuses, {
  String? plate,
}) =>
    providedPermits(serviceStatuses, plate: plate).where((p) => p.waiting).toList();

/// A `waiting_permit` [status] row (vehicle_service_status), with its
/// [vehicle] row and a partner lookup, shaped as a document row for the admin
/// Documents queue — so a permit GET.ride still has to upload shows under
/// "To review" before any file exists. Null unless the row is a permit still
/// waiting. The synthetic `id` (`permit:<vehicle>:<service>`) and the
/// `_providedPermit` flag mark it as having no uploaded file, so the screen
/// opens it read-only (no edit / delete / approve) and routes to the
/// application via `partner_id`.
Map<String, dynamic>? providedPermitDocRow(
  Map<String, dynamic> status, {
  Map<String, dynamic>? vehicle,
  Map<String, Map<String, dynamic>> partners = const {},
}) {
  if (_text(status['status']) != 'waiting_permit') return null;
  final vehicleId = _text(status['vehicle_id']);
  final service = _text(status['service']) ?? '';
  final partnerId = vehicle == null ? null : _text(vehicle['owner_partner_id']);
  final partner = partnerId == null ? null : partners[partnerId];
  return {
    'id': 'permit:${vehicleId ?? ''}:$service',
    'doc_name': _text(status['permit_name']) ?? 'Vehicle permit',
    'status': 'Pending Review',
    'partner_id': partnerId,
    'vehicle_id': vehicleId,
    '_owner': partner == null ? null : (_text(partner['name']) ?? _text(partner['phone'])),
    '_plate': vehicle == null ? null : _text(vehicle['plate']),
    '_service': service,
    '_providedPermit': true,
    'uploaded_at': null,
  };
}
