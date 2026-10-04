// Vehicle onboarding rules, ported from the Expo app's
// `utils/vehicleOnboardingStore.ts` and `app/vehicle-onboarding.tsx`.
//
// A partner registers a vehicle in steps: plate, make & model, year &
// colour, four photos, owner details and the vehicle's documents. As with
// partner onboarding, each step is "done" when its value is stored on the
// `vehicle` row, so a returning partner resumes where they stopped.
import '../admin/screens/people/people_logic.dart';

enum VehicleStep {
  plate('plate', 'Plate'),
  makeModel('make-model', 'Make & model'),
  yearColor('year-color', 'Year & colour'),
  photos('photos', 'Photos'),
  owner('owner', 'Owner'),
  documents('documents', 'Documents'),
  done('done', 'Submitted');

  const VehicleStep(this.key, this.label);

  /// The value stored in `vehicle.onboarding_step` (the Expo keys).
  final String key;
  final String label;

  static const wizard = [plate, makeModel, yearColor, photos, owner, documents];
}

String _text(Object? v) => '${v ?? ''}'.trim();

/// Upper case with single spaces (Expo `normalizePlate`). Plates are unique
/// in the database in this form.
String normalizePlate(String plate) => plate.replaceAll(RegExp(r'\s+'), ' ').trim().toUpperCase();

/// The first step still missing (Expo `computeFirstVehicleStep`).
VehicleStep firstVehicleStep(Map<String, dynamic>? v) {
  if (v == null || _text(v['plate']).isEmpty) return VehicleStep.plate;
  if (_text(v['make']).isEmpty || _text(v['model']).isEmpty) return VehicleStep.makeModel;
  if (_text(v['year']).isEmpty || _text(v['color']).isEmpty) return VehicleStep.yearColor;
  if (vehiclePhotoSlots.any((s) => _text(v['image_$s']).isEmpty)) return VehicleStep.photos;
  if (_text(v['owner_name']).isEmpty || _text(v['owner_phone']).isEmpty || _text(v['owner_ic']).isEmpty) {
    return VehicleStep.owner;
  }
  if (v['documents_ok'] != true) return VehicleStep.documents;
  return VehicleStep.done;
}

/// The `vehicle` row created when a partner enters a new plate (Expo
/// `createVehicleStub`). Status and permit are left to the table defaults
/// (unapproved / pending), which is what the 0088 insert guard requires.
Map<String, dynamic> newVehicleStub({
  required String id,
  required String displayId,
  required String plate,
  required String userId,
  required Map<String, dynamic> partner,
}) =>
    {
      'id': id,
      'display_id': displayId,
      'auth_user_id': userId,
      'owner_partner_id': partner['id'],
      'owner_partner_display_id': partner['display_id'],
      'owner_name': _text(partner['name']),
      'owner_phone': _text(partner['phone']),
      'plate': normalizePlate(plate),
      'onboarding_step': VehicleStep.makeModel.key,
    };

/// Owner fields for "this is my own vehicle": the partner's details, else
/// the profile's.
({String name, String phone, String ic}) ownOwnerDetails(Map<String, dynamic>? partner, Map<String, dynamic>? profile) {
  String pick(String key) {
    final p = _text(partner?[key]);
    return p.isNotEmpty ? p : _text(profile?[key]);
  }

  return (name: pick('name'), phone: pick('phone'), ic: pick('ic'));
}

enum VehicleApprovalTone { approved, pending, rejected, blocked }

/// How a vehicle's review reads to its partner (Expo `approvalState`).
({String label, VehicleApprovalTone tone, String description}) vehicleApproval(Map<String, dynamic> v) {
  final status = _text(v['status']).toLowerCase();
  final permit = _text(v['permit']).toLowerCase();
  if (status == 'blocked') {
    return (
      label: 'Blocked',
      tone: VehicleApprovalTone.blocked,
      description: 'This vehicle has been blocked. Please contact support.',
    );
  }
  if (status == 'rejected' || permit == 'rejected') {
    return (
      label: 'Rejected',
      tone: VehicleApprovalTone.rejected,
      description: 'This vehicle was rejected. Check the documents below and upload any rejected ones again.',
    );
  }
  if (status == 'approved' && (permit == 'approved' || permit == 'verified') && v['documents_ok'] == true) {
    return (
      label: 'Approved',
      tone: VehicleApprovalTone.approved,
      description: 'This vehicle is approved and ready to use.',
    );
  }
  return (
    label: 'Pending review',
    tone: VehicleApprovalTone.pending,
    description: 'An admin is reviewing the vehicle details and documents.',
  );
}

// ---- Which documents belong to the vehicle ---------------------------------

/// Ids of the document types named "Vehicle" (Settings → Document Type).
Set<String> vehicleDocTypeIds(Iterable<({String id, Map<String, dynamic> values})> docTypes) =>
    docTypeIdsNamed(docTypes, 'vehicle').toSet();

/// A required document belongs to the vehicle when it is tagged with the
/// Vehicle document type. Vehicle documents are uploaded per vehicle; every
/// other document is the partner's own.
bool isVehicleDocument(Map<String, dynamic> values, Set<String> vehicleTypeIds) =>
    vehicleTypeIds.isNotEmpty && parseStringList(values['docTypes']).any(vehicleTypeIds.contains);

/// The documents a vehicle needs: required documents tagged Vehicle, for the
/// partner's types and service area.
List<RequiredDoc> vehicleRequiredDocs({
  required Iterable<({String id, Map<String, dynamic> values})> requiredDocuments,
  required Set<String> vehicleTypeIds,
  required List<String> partnerTypes,
  required ServiceArea area,
}) =>
    resolveRequiredDocs(
      requiredDocuments.where((e) => isVehicleDocument(e.values, vehicleTypeIds)),
      partnerTypeNames: partnerTypes,
      countries: area.countries,
      states: area.statePairs(),
    );
