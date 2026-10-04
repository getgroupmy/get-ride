// Partner onboarding rules, ported from the Expo app's
// `utils/partnerOnboardingStore.ts` and `app/partner-onboarding.tsx`.
//
// Someone becomes a partner in six steps: profile photo, ID number, address,
// service area, partner type, and the required documents. Each step is
// "done" when its value is stored, on the partner row or (for the photo, ID
// and address) on the profile, so a returning partner resumes at the first
// step that is still missing, and nothing is asked twice.
//
// The required-document rules themselves are shared with the admin panel
// (`resolveRequiredDocs` in people_logic.dart).
import '../admin/screens/people/people_logic.dart';
import 'vehicle_onboarding.dart';

enum OnboardingStep {
  avatar('avatar', 'Profile photo'),
  id('id', 'ID number'),
  address('address', 'Address'),
  serviceArea('service-area', 'Service area'),
  partnerType('partner-type', 'Partner type'),
  requirements('requirements', 'Documents'),
  done('done', 'Submitted');

  const OnboardingStep(this.key, this.label);

  /// The value stored in `partners.onboarding_step` (the Expo keys).
  final String key;
  final String label;

  /// The steps a partner fills in, in order (without [done]).
  static const wizard = [avatar, id, address, serviceArea, partnerType, requirements];
}

String _text(Object? v) => '${v ?? ''}'.trim();

int _len(Object? v) => v is List ? v.length : 0;

/// The first step still missing (Expo `computeFirstStep`). [profile] is the
/// `profiles` row and [partner] the `partners` row; either may be null.
OnboardingStep firstIncompleteStep(Map<String, dynamic>? profile, Map<String, dynamic>? partner) {
  final avatar = [partner?['avatar_url'], profile?['avatar_url'], profile?['profile_image']].map(_text);
  if (avatar.every((s) => s.isEmpty)) return OnboardingStep.avatar;
  if (_text(partner?['ic']).isEmpty && _text(profile?['ic']).isEmpty) return OnboardingStep.id;
  if (_text(partner?['address']).isEmpty && _text(profile?['address']).isEmpty) return OnboardingStep.address;
  if (_len(partner?['service_countries']) == 0 ||
      _len(partner?['service_states']) == 0 ||
      _len(partner?['service_cities']) == 0) {
    return OnboardingStep.serviceArea;
  }
  if (_len(partner?['partner_types']) == 0) return OnboardingStep.partnerType;
  if (partner?['documents_ok'] != true) return OnboardingStep.requirements;
  return OnboardingStep.done;
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
List<RequiredDoc> requiredDocsFor({
  required Iterable<({String id, Map<String, dynamic> values})> requiredDocuments,
  required Iterable<Map<String, dynamic>> partnerTypeValues,
  required List<String> partnerTypes,
  required ServiceArea area,
  Set<String> vehicleTypeIds = const {},
}) =>
    resolveRequiredDocs(
      requiredDocuments.where((e) => !isVehicleDocument(e.values, vehicleTypeIds)),
      docTypeIds: partnerTypeDocTypeIds(partnerTypeValues, partnerTypes),
      partnerTypeNames: partnerTypes,
      countries: area.countries,
      states: area.statePairs(),
    );

/// The country used to file the photo and ID image in storage: the first
/// service country, else the profile's nationality.
String uploadCountry(Map<String, dynamic>? partner, Map<String, dynamic>? profile) {
  final countries = partner?['service_countries'];
  if (countries is List && countries.isNotEmpty) return _text(countries.first);
  return _text(profile?['nationality']);
}
