// Partner onboarding rules, first ported from the Expo app's
// `utils/partnerOnboardingStore.ts`, reworked for the registration order of
// 0288 (core/partner_registration.dart):
//
//   profile photo (only when missing) -> service area -> Partner Service
//   type -> National ID -> Check your details -> Your company -> Driver
//   permit -> Register vehicle -> Vehicle documents -> Service documents ->
//   Pending admin approval,
//
// each optional step only when the picked services need it there. A step is
// "done" when what it keeps is stored (the photo, the area, the types, the
// ID on the profile) or confirmed (`partners.registration_steps`), so a
// returning partner, also one part-way through the old order, resumes at the
// first step still missing in this one, and nothing is asked twice. An
// application already sent (documents_ok) is done.
//
// The required-document rules themselves are shared with the admin panel
// (`resolveRequiredDocs` in people_logic.dart).
import '../admin/screens/people/people_logic.dart';
import 'partner_registration.dart';
import 'partner_type_rules.dart' show permitRequirements;
import 'vehicle_onboarding.dart';

enum OnboardingStep {
  avatar('avatar', 'Profile photo'),
  serviceArea('service-area', 'Service area'),
  partnerType('partner-type', 'Partner Service type'),
  id('id', 'National ID'),
  details('details', 'Check your details'),
  company('company', 'Your company'),
  driverPermit('driver-permit', 'Driver permit'),
  vehicle('vehicle', 'Register vehicle'),
  vehicleDocs('vehicle-documents', 'Vehicle documents'),
  requirements('requirements', 'Service documents'),
  done('done', 'Pending admin approval');

  const OnboardingStep(this.key, this.label);

  /// The value stored in `partners.onboarding_step`.
  final String key;
  final String label;

  /// Every step a partner may fill in, in order (without [done]).
  static const wizard = [
    avatar,
    serviceArea,
    partnerType,
    id,
    details,
    company,
    driverPermit,
    vehicle,
    vehicleDocs,
    requirements,
  ];

  /// The steps this partner fills in: the optional ones only when [needs]
  /// says so; without [includePhoto] (a photo already taken when the form
  /// opened) the photo step is left out.
  static List<OnboardingStep> stepsFor(RegistrationNeeds needs, {bool includePhoto = true}) => [
        if (includePhoto) avatar,
        serviceArea,
        partnerType,
        id,
        details,
        if (needs.company) company,
        if (needs.driverPermit) driverPermit,
        if (needs.vehicle) ...[vehicle, vehicleDocs],
        requirements,
      ];
}

String _text(Object? v) => '${v ?? ''}'.trim();

int _len(Object? v) => v is List ? v.length : 0;

/// The first step still missing. [profile] is the `profiles` row and
/// [partner] the `partners` row; either may be null. [needs] says which
/// optional steps apply (by default those already confirmed); [onPhone]
/// asks for a live-checked photo.
OnboardingStep firstIncompleteStep(
  Map<String, dynamic>? profile,
  Map<String, dynamic>? partner, {
  RegistrationNeeds? needs,
  bool onPhone = false,
}) {
  if (partner?['documents_ok'] == true) return OnboardingStep.done;
  if (!photoStepDone(profile, partner, onPhone: onPhone)) return OnboardingStep.avatar;
  if (_len(partner?['service_countries']) == 0 ||
      _len(partner?['service_states']) == 0 ||
      _len(partner?['service_cities']) == 0) {
    return OnboardingStep.serviceArea;
  }
  if (_len(partner?['partner_types']) == 0) return OnboardingStep.partnerType;
  if (!idStepDone(profile)) return OnboardingStep.id;
  final done = registrationStepsDone(partner);
  if (!done.contains(regStepDetails)) return OnboardingStep.details;
  final n = needs ?? RegistrationNeeds.fromConfirmed(partner);
  if (n.company && !done.contains(regStepCompany)) return OnboardingStep.company;
  if (n.driverPermit && !done.contains(regStepDriverPermit)) return OnboardingStep.driverPermit;
  if (n.vehicle && !done.contains(regStepVehicle)) return OnboardingStep.vehicle;
  if (n.vehicle && !done.contains(regStepVehicleDocs)) return OnboardingStep.vehicleDocs;
  return OnboardingStep.requirements;
}

/// Where an unfinished application stands: "Step 5 of 8 · National ID", and
/// the share done. Null once it is sent. Without the settings at hand the
/// optional steps count as the partner has confirmed them so far.
({int step, int of, String label, double done})? onboardingProgress(
  Map<String, dynamic>? profile,
  Map<String, dynamic>? partner, {
  RegistrationNeeds? needs,
}) {
  final s = firstIncompleteStep(profile, partner, needs: needs);
  if (s == OnboardingStep.done) return null;
  final steps = OnboardingStep.stepsFor(needs ?? RegistrationNeeds.fromConfirmed(partner));
  final i = steps.indexOf(s);
  final of = steps.length;
  return (step: i + 1, of: of, label: s.label, done: i / of);
}

/// Whether the partner row belongs to someone who has committed to being a
/// partner (Expo `isActivePartner`). Opening the wizard creates a stub row,
/// so the row existing proves nothing; picking a partner type does.
bool isActivePartner(Map<String, dynamic>? partner) {
  if (partner == null) return false;
  if (_len(partner['partner_types']) > 0) return true;
  return partner['documents_ok'] == true;
}

/// Whether the partner still has wizard steps to finish, judged from the
/// partner row alone (the Drive tab has no profile row at hand). Photo, ID
/// and address can also live on the profile, so the wizard itself may skip
/// ahead; it never asks for more than this says.
bool partnerSetupIncomplete(Map<String, dynamic> partner) =>
    _len(partner['partner_types']) == 0 || partner['documents_ok'] != true;

/// The `partners` row created when someone starts the wizard (Expo
/// `findOrCreatePartner`). It satisfies the database's self-insert guard
/// (migration 0088): unapproved, no permit, no rating or rides.
Map<String, dynamic> newPartnerStub({
  required String id,
  required String displayId,
  required String userId,
  required Map<String, dynamic>? profile,
  required String joinedAt,
}) {
  String? opt(Object? v) => _text(v).isEmpty ? null : _text(v);
  return {
    'id': id,
    'display_id': displayId,
    'auth_user_id': userId,
    'name': _text(profile?['name']),
    'phone': _text(profile?['phone']),
    'email': opt(profile?['email']),
    'ic': opt(profile?['ic']),
    'address': opt(profile?['address']),
    'avatar_url': opt(profile?['avatar_url']) ?? opt(profile?['profile_image']),
    'partner_types': const <String>[],
    'service_countries': const <String>[],
    'service_states': const <String>[],
    'service_cities': const <String>[],
    'status': 'unapproved',
    'permit': 'none',
    'documents_ok': false,
    'rating': 0,
    'total_rides': 0,
    'joined_at': joinedAt,
  };
}

/// Every compulsory document has an upload that is neither rejected nor
/// expired (the check that unlocks "Submit for review"). Optional uploads
/// never stand in for a missing compulsory one.
bool compulsoryDocsComplete(List<RequiredDoc> docs, Map<String, Map<String, dynamic>> uploads, {DateTime? now}) =>
    docs.where((d) => d.compulsory).every((d) {
      final u = uploads[d.id];
      if (u == null) return false;
      final s = docDisplayStatus(u, now: now);
      return s != 'Rejected' && s != 'Expired';
    });

/// The documents this partner must provide: the required-document rules
/// applied to their partner types and service area. Documents tagged with
/// the Vehicle document type ([vehicleTypeIds]) are left out: they are
/// uploaded per vehicle in vehicle onboarding, not once for the partner.
///
/// Where Admin → Partner Type → Permit makes a permit required for one of
/// the partner's types in their service area, the permit documents
/// (Required Documents marked "taxi permit") are compulsory, whatever their
/// own rules say ([withRequiredPermit]).
List<RequiredDoc> requiredDocsFor({
  required Iterable<({String id, Map<String, dynamic> values})> requiredDocuments,
  required Iterable<Map<String, dynamic>> partnerTypeValues,
  required List<String> partnerTypes,
  required ServiceArea area,
  Set<String> vehicleTypeIds = const {},
}) {
  final partnerDocs = requiredDocuments.where((e) => !isVehicleDocument(e.values, vehicleTypeIds)).toList();
  final docs = resolveRequiredDocs(
    partnerDocs,
    docTypeIds: partnerTypeDocTypeIds(partnerTypeValues, partnerTypes),
    partnerTypeNames: partnerTypes,
    countries: area.countries,
    states: area.statePairs(),
  );
  return withRequiredPermit(docs, partnerDocs, permitRequirements(partnerTypes, partnerTypeValues, area));
}

/// [docs] with every active permit document of [requiredDocuments]
/// compulsory when [needs] is not empty (added when its own rules left it
/// out). Compulsory first, then by name, as [resolveRequiredDocs] sorts.
List<RequiredDoc> withRequiredPermit(
  List<RequiredDoc> docs,
  Iterable<({String id, Map<String, dynamic> values})> requiredDocuments,
  List<({String type, String region})> needs,
) {
  if (needs.isEmpty) return docs;
  final permits = [
    for (final e in requiredDocuments)
      if (DocFlags.fromValues(e.values).isTaxiPermit &&
          '${e.values['active'] ?? true}' != 'false' &&
          '${e.values['name'] ?? ''}'.trim().isNotEmpty)
        e,
  ];
  if (permits.isEmpty) return docs;
  final need = needs.first;
  final label = need.region.isEmpty ? 'Required for ${need.type}' : 'Required for ${need.type} in ${need.region}';
  final out = [...docs];
  for (final e in permits) {
    final i = out.indexWhere((d) => d.id == e.id);
    final current = i < 0 ? null : out[i];
    final doc = RequiredDoc(
      id: e.id,
      name: current?.name ?? '${e.values['name']}'.trim(),
      description: current?.description ?? '${e.values['description'] ?? ''}'.trim(),
      compulsory: true,
      scope: current?.scope ?? 'global',
      labels: [...?current?.labels, label],
      flags: current?.flags ?? DocFlags.fromValues(e.values),
    );
    if (i < 0) {
      out.add(doc);
    } else {
      out[i] = doc;
    }
  }
  out.sort((a, b) => a.compulsory != b.compulsory ? (a.compulsory ? -1 : 1) : a.name.compareTo(b.name));
  return out;
}

/// The country used to file the photo and ID image in storage: the first
/// service country, else the profile's nationality.
String uploadCountry(Map<String, dynamic>? partner, Map<String, dynamic>? profile) {
  final countries = partner?['service_countries'];
  if (countries is List && countries.isNotEmpty) return _text(countries.first);
  return _text(profile?['nationality']);
}
