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

/// The first step still missing (Expo `computeFirstVehicleStep`). A vehicle
/// an admin has approved is complete: the registration flow (0288) leaves
/// the owner's phone or ID out where the grant has none, and that must not
/// stop the driver taking the car they registered.
VehicleStep firstVehicleStep(Map<String, dynamic>? v) {
  if (v == null || _text(v['plate']).isEmpty) return VehicleStep.plate;
  if (approvedVehicleStatuses.contains(_text(v['status']).toLowerCase())) return VehicleStep.done;
  if (_text(v['make']).isEmpty || _text(v['model']).isEmpty) return VehicleStep.makeModel;
  if (_text(v['year']).isEmpty || _text(v['color']).isEmpty) return VehicleStep.yearColor;
  if (vehiclePhotoSlots.any((s) => _text(v['image_$s']).isEmpty)) return VehicleStep.photos;
  if (_text(v['owner_name']).isEmpty || _text(v['owner_phone']).isEmpty || _text(v['owner_ic']).isEmpty) {
    return VehicleStep.owner;
  }
  if (v['documents_ok'] != true) return VehicleStep.documents;
  return VehicleStep.done;
}

/// Whether [v] looks like a draft its owner may still remove (0229's
/// "vehicle own draft delete"): never submitted, approved or permitted, the
/// wizard not finished. The server checks the rest (no document sent, no
/// driver, session or ride on it), so a delete can still come back empty.
bool vehicleLooksLikeDraft(Map<String, dynamic> v) =>
    (v['status'] ?? 'unapproved') == 'unapproved' &&
    (v['permit'] ?? 'pending') == 'pending' &&
    v['documents_ok'] != true &&
    v['onboarding_step'] != 'done' &&
    firstVehicleStep(v) != VehicleStep.done;

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

/// The oldest model year a vehicle can be registered with.
const vehicleMinYear = 1950;

/// Why the year & colour step can't be saved, or null: both are needed, and
/// the year is four digits from [vehicleMinYear] to next year's models.
String? vehicleYearColorProblem(String year, String color, {DateTime? now}) {
  final y = year.trim();
  if (y.isEmpty || color.trim().isEmpty) return 'Please enter both the year and the colour.';
  final max = (now ?? DateTime.now()).year + 1;
  final n = RegExp(r'^\d{4}$').hasMatch(y) ? int.parse(y) : null;
  if (n == null || n < vehicleMinYear || n > max) {
    return 'Enter the year as 4 digits, from $vehicleMinYear to $max.';
  }
  return null;
}

/// Why the owner step can't be saved, or null (Expo `onSaveOwner`): "Is
/// this your own vehicle?" must be answered, and every owner field filled.
String? vehicleOwnerProblem({required bool? ownVehicle, required String name, required String phone, required String ic}) {
  if (ownVehicle == null) return 'Please tell us whether this is your own vehicle.';
  if (name.trim().isEmpty || phone.trim().isEmpty || ic.trim().isEmpty) {
    return "Please enter the owner's name, phone and ID number.";
  }
  return null;
}

/// Owner fields for "this is my own vehicle": the partner's details, else
/// the profile's.
({String name, String phone, String ic}) ownOwnerDetails(Map<String, dynamic>? partner, Map<String, dynamic>? profile) {
  String pick(String key) {
    final p = _text(partner?[key]);
    return p.isNotEmpty ? p : _text(profile?[key]);
  }

  return (name: pick('name'), phone: pick('phone'), ic: pick('ic'));
}

/// The owner's ID and phone saved with a registered vehicle: the ID read off
/// the grant when there is one and, when the driver owns it ([driverOwns]),
/// their own ID (the profile's, else the partner's) and phone (the
/// partner's, else the profile's). Blanks are left out, so what is stored
/// stays.
Map<String, String> registeredOwnerContact({
  required bool driverOwns,
  required String grantOwnerId,
  Map<String, dynamic>? partner,
  Map<String, dynamic>? profile,
}) {
  String first(String key, List<Map<String, dynamic>?> rows) =>
      rows.map((r) => _text(r?[key])).firstWhere((t) => t.isNotEmpty, orElse: () => '');
  final ic = grantOwnerId.trim().isNotEmpty ? grantOwnerId.trim() : (driverOwns ? first('ic', [profile, partner]) : '');
  final phone = driverOwns ? first('phone', [partner, profile]) : '';
  return {
    if (ic.isNotEmpty) 'owner_ic': ic,
    if (phone.isNotEmpty) 'owner_phone': phone,
  };
}

enum VehicleApprovalTone { approved, pending, rejected, blocked }

/// The vehicle statuses an admin has approved: `approved`, and
/// `permit-verified` (the admin's "Permit Verified" on an approved vehicle).
/// The `permit-pending` / `permit-non-verified` statuses are still the
/// review queue. The `permit` column is not a second approval: a vehicle
/// keeps its default `pending` permit when the admin approves the status, so
/// reading it as one left approved vehicles "Pending review" for good.
const approvedVehicleStatuses = {'approved', 'permit-verified'};

/// The statuses that lock a vehicle; the driver contacts an admin.
const lockedVehicleStatuses = {'blocked', 'deleted', 'rejected'};

/// Whether [v] is approved to drive: an approved status with its documents
/// complete.
bool vehicleApproved(Map<String, dynamic> v) =>
    approvedVehicleStatuses.contains(_text(v['status']).toLowerCase()) && v['documents_ok'] == true;

/// How a vehicle's review reads to its partner (Expo `approvalState`), in
/// step with what the vehicle picker lets them drive.
({String label, VehicleApprovalTone tone, String description}) vehicleApproval(Map<String, dynamic> v) {
  final status = _text(v['status']).toLowerCase();
  if (status == 'blocked' || status == 'deleted') {
    return (
      label: 'Blocked',
      tone: VehicleApprovalTone.blocked,
      description: 'This vehicle has been blocked. Please contact support.',
    );
  }
  if (status == 'rejected') {
    return (
      label: 'Rejected',
      tone: VehicleApprovalTone.rejected,
      description: 'This vehicle was rejected. Check the documents below and upload any rejected ones again.',
    );
  }
  if (vehicleApproved(v)) {
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

/// Where "Done" goes once the vehicle is registered (Expo
/// `onPendingContinue`): an approved vehicle straight to the Drive tab to
/// take jobs; anything still in review back where the partner came from
/// (null).
String? vehicleFinishRoute(Map<String, dynamic> v) => vehicleApproved(v) ? '/drive' : null;

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

/// The service a vehicle is registered for (migration 0249): the one its make
/// & model maps to, else the driver's choice; a problem when neither is set.
({String? serviceId, String? problem}) vehicleServiceChoice({required String mapped, required String chosen}) {
  if (mapped.trim().isNotEmpty) return (serviceId: mapped.trim(), problem: null);
  if (chosen.trim().isNotEmpty) return (serviceId: chosen.trim(), problem: null);
  return (serviceId: null, problem: 'Choose the service type of this vehicle.');
}
