// Partner registration (0288): the rules behind the new registration order,
// pure so they are tested without a database or a camera.
//
//   profile photo (if missing) -> service area -> Partner Service type ->
//   National ID -> Check your details -> Your company (if a picked service
//   needs a registered business there) -> Driver permit (if one needs it) ->
//   Register vehicle and Vehicle documents (for a vehicle service) ->
//   Service documents -> Pending admin approval.
//
// Which of the optional steps apply comes from the picked Partner Service
// types and the service area (core/partner_type_rules.dart). What a step
// keeps is on the profile (the ID), the partner row (details, company,
// driver permit, the confirmed steps) and the vehicle row (the grant), with
// a status per vehicle and service (vehicle_service_status).
library;

import '../admin/screens/people/people_logic.dart';
import 'document_text.dart';
import 'partner_type_rules.dart';

// ---- Which steps apply -----------------------------------------------------------------------------

/// The optional steps a partner's picks need.
class RegistrationNeeds {
  const RegistrationNeeds({this.company = false, this.driverPermit = false, this.vehicle = false});

  /// From the picked [types] in [area] with the Partner Service type
  /// settings [entries].
  factory RegistrationNeeds.of(List<String> types, Iterable<Map<String, dynamic>> entries, ServiceArea area) =>
      RegistrationNeeds(
        company: needsBusinessRegistration(types, entries, area),
        driverPermit: driverPermitFor(types, entries, area).isNotEmpty,
        vehicle: vehicleServicesOf(types, entries).isNotEmpty,
      );

  /// Where the settings aren't at hand (the Drive tab's progress line): the
  /// steps the partner has already confirmed count as needed.
  factory RegistrationNeeds.fromConfirmed(Map<String, dynamic>? partner) {
    final done = registrationStepsDone(partner);
    return RegistrationNeeds(
      company: done.contains(regStepCompany),
      driverPermit: done.contains(regStepDriverPermit),
      vehicle: done.contains(regStepVehicle),
    );
  }

  static const none = RegistrationNeeds();

  final bool company, driverPermit, vehicle;

  @override
  bool operator ==(Object other) =>
      other is RegistrationNeeds &&
      other.company == company &&
      other.driverPermit == driverPermit &&
      other.vehicle == vehicle;

  @override
  int get hashCode => Object.hash(company, driverPermit, vehicle);
}

/// Of [types], the vehicle services ("Vehicle service: partners must
/// register a vehicle"), as their settings name them.
List<String> vehicleServicesOf(List<String> types, Iterable<Map<String, dynamic>> entries) => [
      for (final t in types)
        if (t.trim().isNotEmpty)
          if (EffectiveTypeRules.of(t, entries) case final r when r.vehicleRequired) r.name.isEmpty ? t : r.name,
    ];

/// The steps confirmed with their button, kept in `partners.registration_steps`.
const regStepDetails = 'details';
const regStepCompany = 'company';
const regStepDriverPermit = 'driver-permit';
const regStepVehicle = 'vehicle';
const regStepVehicleDocs = 'vehicle-documents';

String _t(Object? v) => '${v ?? ''}'.trim();

List<String> registrationStepsDone(Map<String, dynamic>? partner) => parseStringList(partner?['registration_steps']);

/// The partner patch that records [step] as confirmed.
Map<String, dynamic> withRegistrationStep(Map<String, dynamic>? partner, String step) => {
      'registration_steps': {...registrationStepsDone(partner), step}.toList(),
    };

/// The National ID step is done: the ID type, its number and both photos.
bool idStepDone(Map<String, dynamic>? profile) =>
    IdDocType.parse(profile?['id_type']) != null &&
    _t(profile?['ic']).isNotEmpty &&
    _t(profile?['id_image']).isNotEmpty &&
    _t(profile?['id_image_back']).isNotEmpty;

/// The profile photo step is done: a photo, taken with the live check on a
/// phone ([onPhone]). Elsewhere any photo will do (the admin sees it was not
/// checked).
bool photoStepDone(Map<String, dynamic>? profile, Map<String, dynamic>? partner, {bool onPhone = false}) {
  final photo = [partner?['avatar_url'], profile?['avatar_url'], profile?['profile_image']].map(_t);
  if (photo.every((s) => s.isEmpty)) return false;
  return !onPhone || partner?['selfie_liveness'] == 'passed';
}

// ---- Service area from where the phone is --------------------------------------------------------

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

bool _sameArea(String a, String b) {
  final x = _norm(a), y = _norm(b);
  return x.isNotEmpty && y.isNotEmpty && (x == y || x.contains(y) || y.contains(x));
}

/// The service area for a place ([country], [state], [city] as the
/// geocoder names them), matched against the areas the admin set up
/// ([options]; "Wilayah Persekutuan Kuala Lumpur" finds "Kuala Lumpur").
/// Null when the country isn't one of them.
ServiceArea? areaFromPlace({String? country, String? state, String? city, required GeoOptions options}) {
  final c = options.countries.where((o) => _sameArea(o, country ?? '')).firstOrNull;
  if (c == null) return null;
  final s = options.states
      .where((k) => k.split('|').first == c && _sameArea(k.split('|').last, state ?? ''))
      .firstOrNull;
  if (s == null) return ServiceArea(countries: [c]);
  final ci = options.cities
      .where((k) => k.startsWith('$s|') && _sameArea(k.split('|').last, city ?? ''))
      .firstOrNull;
  return ServiceArea(countries: [c], states: [s], cities: [?ci]);
}

// ---- Partner Service type cards and the citizens-only notice -----------------------------------

/// What a Partner Service type's card says under its name: its age limit
/// and its documents.
String serviceCardText({
  required String type,
  required Iterable<Map<String, dynamic>> entries,
  required ServiceArea area,
  required List<String> documents,
  String? driverPermit,
}) {
  final r = EffectiveTypeRules.of(type, entries);
  final parts = <String>[];
  if (r.vehicleRequired) {
    final limit = effectiveMaxVehicleAge(type, [type], entries, area);
    parts.add(limit == null ? 'Vehicle service' : 'Vehicle up to ${limit.maxYears} years old');
  }
  final needs = [...documents, ?driverPermit];
  parts.add(needs.isEmpty ? 'No service documents set up yet' : 'Needs: ${needs.join(', ')}');
  return parts.join(' · ');
}

/// "You may not be eligible to join some services": who is asked, what is
/// citizens-only in the area, which of those were picked, and what is open.
typedef EligibilityNotice = ({List<String> citizensOnly, List<String> picked, List<String> open});

/// The notice for someone registering with [idType] (or a non-citizen
/// [nationality] read off the ID), or null when it doesn't apply: a citizen,
/// or no service is citizens-only in [area]. [offered] are the types offered
/// there; [picked] the ones chosen.
EligibilityNotice? eligibilityNotice({
  required IdDocType? idType,
  String? nationality,
  required List<String> offered,
  required List<String> picked,
  required Iterable<Map<String, dynamic>> entries,
  required ServiceArea area,
}) {
  if (!idShowsNonCitizen(idType, nationality)) return null;
  final only = citizensOnlyTypes(offered, entries, area);
  if (only.isEmpty) return null;
  final keys = {for (final t in only) partnerTypeNameKey(t)};
  return (
    citizensOnly: only,
    picked: [for (final t in picked) if (keys.contains(partnerTypeNameKey(t))) EffectiveTypeRules.of(t, entries).name],
    open: openToEveryoneTypes(offered, entries, area),
  );
}

/// The line that opens the notice.
String eligibilityLead(IdDocType? idType) => switch (idType) {
      IdDocType.passport => 'You are registering with a passport.',
      IdDocType.mypr => 'You are registering as a permanent resident.',
      _ => 'Your ID shows you are not a citizen.',
    };

// ---- Details read from the ID ------------------------------------------------------------------------

/// Why "Confirm details" can't go ahead yet, or null. A MyKad's date of
/// birth must be the date its number starts with.
String? detailsProblem({
  required IdDocType? idType,
  required String number,
  required String name,
  required DateTime? dateOfBirth,
  required String address,
}) {
  if (number.trim().isEmpty) return 'Enter your ID number.';
  if (name.trim().isEmpty) return 'Enter your full name as it is on your ID.';
  if (dateOfBirth == null) return 'Enter your date of birth.';
  if (address.trim().isEmpty) return 'Enter your address as it is on your ID.';
  if ((idType == IdDocType.mykad || idType == IdDocType.mypr) && !myKadDobMatches(number, dateOfBirth)) {
    return 'For a ${idType!.label}, the date of birth must match the first six digits of the number.';
  }
  return null;
}

// ---- The vehicle's owner -----------------------------------------------------------------------------

enum OwnerMatch {
  driver('driver'),
  company('company'),
  other('other');

  const OwnerMatch(this.key);
  final String key;

  static OwnerMatch? parse(Object? v) => values.where((m) => m.key == '$v').firstOrNull;
}

/// Who the grant's registered owner is: the driver (by ID number, else by
/// name), their company (by registration number, else by name), or
/// someone else. Someone else needs the owner's authorisation letter.
OwnerMatch ownerMatchFor({
  required String owner,
  String? ownerId,
  required String driverName,
  String? driverId,
  String? companyName,
  String? companyRegNo,
}) {
  if (sameIdNumber(ownerId, driverId) || namesMatch(owner, driverName)) return OwnerMatch.driver;
  final reg = idKey(companyRegNo);
  final oid = idKey(ownerId);
  if (oid.isNotEmpty && reg.isNotEmpty && reg.contains(oid)) return OwnerMatch.company;
  if (companyNamesMatch(owner, companyName)) return OwnerMatch.company;
  return OwnerMatch.other;
}

// ---- Driver permit checks ------------------------------------------------------------------------------

/// One check on the driver permit: passed, or failed ([blocking] ones stop
/// the step; the others can be confirmed anyway and are flagged for the
/// admin under [key]).
class PermitCheck {
  const PermitCheck({required this.key, required this.ok, required this.text, this.blocking = false});
  final String key;
  final bool ok;
  final bool blocking;
  final String text;
}

/// Days before a driver permit ends that the driver is reminded.
const driverPermitRemindDays = 30;

/// The checks on a driver permit read (and edited) as [p]: name and ID
/// number against the ID, the operator against the company, the plate
/// (checked again when the vehicle is registered), the driver's place for
/// that vehicle, and the expiry (an expired permit can't be submitted).
List<PermitCheck> driverPermitChecks({
  required DriverPermitRead p,
  required String idName,
  required String idNumber,
  String? companyName,
  String? companyRegNo,
  String? vehiclePlate,
  DateTime? now,
}) {
  final today = now ?? DateTime.now();
  final out = <PermitCheck>[];
  final nameOk = namesMatch(p.name, idName);
  final icOk = sameIdNumber(p.idNumber, idNumber);
  out.add(PermitCheck(
    key: 'name_id',
    ok: nameOk && icOk,
    text: nameOk && icOk
        ? 'Name and ID number match your ID'
        : !nameOk && !icOk
            ? "The name and ID number on the permit don't match your ID"
            : !nameOk
                ? "The name on the permit doesn't match your ID"
                : "The ID number on the permit doesn't match your ID",
  ));
  if (_t(companyName).isNotEmpty) {
    final ok = companyNamesMatch(p.operatorName, companyName);
    final reg = _t(companyRegNo).isEmpty ? '' : ' (SSM ${_t(companyRegNo).split(' ').first})';
    out.add(PermitCheck(
      key: 'operator',
      ok: ok,
      text: ok ? 'Operator matches your company$reg' : "The operator on the permit isn't your company$reg",
    ));
  }
  if (_t(p.plate).isNotEmpty) {
    final has = _t(vehiclePlate).isNotEmpty;
    final ok = !has || plateKey(p.plate) == plateKey(vehiclePlate);
    out.add(PermitCheck(
      key: 'plate',
      ok: ok,
      text: !has
          ? 'Plate ${p.plate} is checked against the vehicle you register next'
          : ok
              ? 'Plate matches your vehicle'
              : "The plate on the permit (${p.plate}) isn't your vehicle's ($vehiclePlate)",
    ));
    if (p.position != null) {
      out.add(PermitCheck(
        key: 'position',
        ok: true,
        text: p.position == 1
            ? 'You are the 1st driver for ${p.plate}.'
            : 'You are the ${driverPositionLabel(p.position!)} for ${p.plate}. The taxi is shared, not handed over.',
      ));
    }
  }
  final until = p.validUntil;
  if (until == null) {
    out.add(const PermitCheck(key: 'expiry', ok: false, blocking: true, text: 'Enter the date the permit is valid until.'));
  } else {
    final day = DateTime(today.year, today.month, today.day);
    final left = DateTime(until.year, until.month, until.day).difference(day).inDays;
    if (left < 0) {
      out.add(const PermitCheck(
        key: 'expiry',
        ok: false,
        blocking: true,
        text: "This permit has expired. Renew it, then upload the new one: an expired permit can't be submitted.",
      ));
    } else if (left <= driverPermitRemindDays) {
      out.add(PermitCheck(
        key: 'expiry',
        ok: true,
        text: 'Valid for $left more day${left == 1 ? '' : 's'}. Renew it soon: we remind you before it ends.',
      ));
    } else {
      final months = (left / 30.4).floor();
      out.add(PermitCheck(
        key: 'expiry',
        ok: true,
        text: months >= 1
            ? 'Valid for $months more month${months == 1 ? '' : 's'}. We remind you $driverPermitRemindDays days before it ends.'
            : 'Valid for $left more days. We remind you $driverPermitRemindDays days before it ends.',
      ));
    }
  }
  return out;
}

/// The failed checks that can be confirmed anyway: kept on the partner for
/// the admin (`driver_permit_flags`).
List<String> permitFlags(List<PermitCheck> checks) => [for (final c in checks) if (!c.ok && !c.blocking) c.key];

// ---- Each picked vehicle service on this vehicle -------------------------------------------------

enum VehicleServiceState {
  active('active'),
  pausedAge('paused_age'),
  waitingPermit('waiting_permit');

  const VehicleServiceState(this.key);
  final String key;
}

class VehicleServiceStatus {
  const VehicleServiceStatus({
    required this.service,
    required this.state,
    this.limit,
    this.permit,
    this.activeUntil,
    this.remindSoon = false,
    this.coveredBy,
  });

  final String service;
  final VehicleServiceState state;

  /// The age limit that applies, or null for none.
  final VehicleAgeLimit? limit;

  /// The vehicle permit GET.ride uploads, or null for none.
  final PermitNeed? permit;

  /// The last day the vehicle is within [limit].
  final DateTime? activeUntil;

  /// Within a year of [activeUntil].
  final bool remindSoon;

  /// The registered type whose limit covers this service (a taxi doing
  /// eHailing), or null.
  final String? coveredBy;

  /// The `vehicle_service_status` row for [vehicleId].
  Map<String, dynamic> toRow(String vehicleId) => {
        'vehicle_id': vehicleId,
        'service': service,
        'status': state.key,
        'max_age_years': limit?.maxYears,
        'limit_type': limit?.type,
        'permit_name': permit?.name,
        'permit_type': (permit?.permitType ?? '').isEmpty ? null : permit!.permitType,
      };
}

/// How each of the picked vehicle [services] stands with a vehicle
/// registered on [registered], in [area]: over its age limit (with the
/// limits a registered type covers it with, `ageLimitCovers`) it is paused
/// for this vehicle; needing a vehicle permit it waits for GET.ride to upload
/// it; else it is active. Never a refusal: the others still work.
List<VehicleServiceStatus> vehicleServiceStatuses({
  required List<String> services,
  required Iterable<Map<String, dynamic>> entries,
  required ServiceArea area,
  DateTime? registered,
  DateTime? now,
}) {
  final today = now ?? DateTime.now();
  return [
    for (final s in services)
      () {
        final limit = effectiveMaxVehicleAge(s, services, entries, area);
        final permit = vehiclePermitFor(s, services, entries, area);
        DateTime? until;
        var over = false;
        var soon = false;
        if (limit != null && registered != null) {
          over = overVehicleAgeLimit(registered, limit, now: today);
          until = DateTime(registered.year + limit.maxYears + 1, registered.month, registered.day)
              .subtract(const Duration(days: 1));
          soon = !over && until.difference(today).inDays <= 365;
        }
        final own = EffectiveTypeRules.of(s, entries).name;
        return VehicleServiceStatus(
          service: own.isEmpty ? s : own,
          state: over
              ? VehicleServiceState.pausedAge
              : permit != null
                  ? VehicleServiceState.waitingPermit
                  : VehicleServiceState.active,
          limit: limit,
          permit: permit,
          activeUntil: until,
          remindSoon: soon,
          coveredBy: limit != null && partnerTypeNameKey(limit.type) != partnerTypeNameKey(own) ? limit.type : null,
        );
      }(),
  ];
}

String _monthYear(DateTime d) => '${d.month.toString().padLeft(2, '0')}/${d.year}';

/// The age line for one service: "eHailing: limit 15 years. Active until
/// 03/2036." and the like.
String vehicleAgeLine(VehicleServiceStatus s) {
  final l = s.limit;
  if (l == null) return '${s.service}: no age limit.';
  final limit = s.coveredBy == null
      ? 'limit ${l.maxYears} years'
      : 'this vehicle is registered for ${s.coveredBy}, so its limit of ${l.maxYears} years applies';
  if (s.state == VehicleServiceState.pausedAge) return '${s.service}: $limit. Not active until you add a newer vehicle.';
  final until = s.activeUntil;
  return until == null ? '${s.service}: $limit.' : '${s.service}: $limit. Active until ${_monthYear(until)}.';
}

/// The vehicle permit line for one service.
String vehiclePermitLine(VehicleServiceStatus s) {
  final p = s.permit;
  if (p == null) return "${s.service}: no vehicle permit needed here.";
  final by = p.issuer.isEmpty ? '' : ' (${p.issuer})';
  return '${s.service}: needs ${p.name.isEmpty ? 'a vehicle permit' : p.name}$by. GET.ride applies and uploads it for '
      'this vehicle after approval. ${s.service} turns on once it is uploaded.';
}

// ---- Service documents --------------------------------------------------------------------------------

/// The service documents left once the Driver permit step has read the
/// permit: documents tagged as the taxi driver permit are not asked again.
List<RequiredDoc> serviceDocsAfterPermitStep(List<RequiredDoc> docs, {required bool permitStep}) =>
    permitStep ? [for (final d in docs) if (!d.flags.isTaxiPermit) d] : docs;

// ---- Needs a closer look -----------------------------------------------------------------------------------

/// Why an application needs a closer look, in words (`closer_look_reasons`).
String closerLookReasonText(String key) => switch (key) {
      'selfie_not_live' => 'Selfie taken without the live check',
      'id_number_mismatch' => "The ID number typed doesn't match the one on the ID",
      'driver_permit_checks' => 'A driver permit check failed and was confirmed anyway',
      'face_low' => 'Low face match between the selfie and a document photo',
      _ => key,
    };

// ---- Make and model from the grant ---------------------------------------------------------------------

/// The Vehicle Make & Model row for a grant's [make] and [model] (the
/// service type comes from it, as when picked from the list): the same
/// make, and the catalogue's model at the start of the grant's (BEZZA for
/// "BEZZA 1.3 AV"), the longest such. Null when none fits.
Map<String, dynamic>? matchMakeModel(List<Map<String, dynamic>> rows, String make, String model) {
  String k(Object? v) => '${v ?? ''}'.trim().toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
  final mk = k(make), md = k(model);
  if (mk.isEmpty || md.isEmpty) return null;
  Map<String, dynamic>? best;
  for (final r in rows) {
    final rm = k(r['model']);
    if (k(r['make']) != mk || rm.isEmpty) continue;
    if (md == rm || md.startsWith('$rm ')) {
      if (best == null || rm.length > k(best['model']).length) best = r;
    }
  }
  return best;
}
