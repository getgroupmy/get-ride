import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/people/people_logic.dart';
import 'package:get_ride/src/core/partner_onboarding.dart';
import 'package:get_ride/src/core/vehicle_onboarding.dart';

const _photos = {
  'image_front': 'f.png',
  'image_left': 'l.png',
  'image_right': 'r.png',
  'image_back': 'b.png',
};

void main() {
  test('plates are upper-cased with single spaces', () {
    expect(normalizePlate('  wxy   1234 '), 'WXY 1234');
    expect(normalizePlate(''), '');
  });

  group('firstVehicleStep', () {
    test('walks the Expo order: plate, make, year, photos, owner, documents', () {
      expect(firstVehicleStep(null), VehicleStep.plate);
      var v = <String, dynamic>{'plate': 'WXY 1'};
      expect(firstVehicleStep(v), VehicleStep.makeModel);
      v = {...v, 'make': 'Proton', 'model': 'Saga'};
      expect(firstVehicleStep(v), VehicleStep.yearColor);
      v = {...v, 'year': '2020', 'color': 'White'};
      expect(firstVehicleStep(v), VehicleStep.photos);
      v = {...v, ..._photos, 'image_back': ' '};
      expect(firstVehicleStep(v), VehicleStep.photos);
      v = {...v, ..._photos};
      expect(firstVehicleStep(v), VehicleStep.owner);
      v = {...v, 'owner_name': 'Aina', 'owner_phone': '+60123', 'owner_ic': '900101'};
      expect(firstVehicleStep(v), VehicleStep.documents);
      expect(firstVehicleStep({...v, 'documents_ok': true}), VehicleStep.done);
    });

    test('step keys match what the Expo app stores', () {
      expect(VehicleStep.wizard.map((s) => s.key),
          ['plate', 'make-model', 'year-color', 'photos', 'owner', 'documents']);
    });
  });

  test('a new vehicle belongs to the partner and leaves status to the database', () {
    final row = newVehicleStub(
      id: 'v1',
      displayId: 'VH-000001',
      plate: ' wxy 1 ',
      userId: 'u1',
      partner: {'id': 'p1', 'display_id': 'PR-1', 'name': 'Aina', 'phone': '+60123'},
    );
    expect(row['plate'], 'WXY 1');
    expect(row['auth_user_id'], 'u1');
    expect(row['owner_partner_id'], 'p1');
    expect(row['owner_name'], 'Aina');
    expect(row['onboarding_step'], 'make-model');
    // The 0088 insert guard only accepts the defaults (unapproved / pending).
    expect(row.containsKey('status'), isFalse);
    expect(row.containsKey('permit'), isFalse);
  });

  test('"my own vehicle" prefers the partner row, then the profile', () {
    final d = ownOwnerDetails({'name': 'Aina', 'phone': ''}, {'phone': '+60123', 'ic': '900101'});
    expect(d, (name: 'Aina', phone: '+60123', ic: '900101'));
  });

  group('vehicleApproval', () {
    test('blocked and rejected win over everything', () {
      expect(vehicleApproval({'status': 'blocked', 'documents_ok': true}).tone, VehicleApprovalTone.blocked);
      expect(vehicleApproval({'status': 'rejected', 'documents_ok': true}).tone, VehicleApprovalTone.rejected);
    });

    test('approved is an approved status with the documents; the permit column is not a second gate', () {
      final ok = {'status': 'approved', 'permit': 'verified', 'documents_ok': true};
      expect(vehicleApproval(ok).label, 'Approved');
      expect(vehicleApproval({...ok, 'permit': 'pending'}).tone, VehicleApprovalTone.approved);
      expect(vehicleApproval({...ok, 'status': 'permit-verified'}).tone, VehicleApprovalTone.approved);
      expect(vehicleApproval({...ok, 'status': 'permit-pending'}).tone, VehicleApprovalTone.pending);
      expect(vehicleApproval({...ok, 'documents_ok': false}).tone, VehicleApprovalTone.pending);
    });
  });

  group('vehicle documents', () {
    // The live settings: documents tagged with the "Vehicle" document type
    // belong to the vehicle; the rest are the partner's.
    final docTypes = [
      (id: 'type-vehicle', values: <String, dynamic>{'name': 'Vehicle'}),
      (id: 'type-partner', values: <String, dynamic>{'name': 'Partner'}),
    ];
    final entries = [
      (id: 'licence', values: <String, dynamic>{'name': 'Driving License', 'docTypes': '["stale-id"]'}),
      (id: 'puspakom', values: <String, dynamic>{'name': 'Inspection (Puspakom)', 'docTypes': '["type-vehicle"]'}),
      (
        id: 'insurance',
        values: <String, dynamic>{'name': 'Vehicle Insurance', 'docTypes': ['type-vehicle', 'other']}
      ),
      (
        id: 'permit',
        values: <String, dynamic>{'name': 'Driver Permit', 'docTypes': '["type-partner"]', 'partnerTypes': '["Teksi"]'}
      ),
    ];
    final ids = vehicleDocTypeIds(docTypes);
    const area = ServiceArea(countries: ['Malaysia'], states: ['Malaysia|Selangor'], cities: ['Malaysia|Selangor|Ampang']);

    test('the Vehicle document type picks out vehicle documents', () {
      expect(ids, {'type-vehicle'});
      expect(isVehicleDocument(entries[1].values, ids), isTrue);
      expect(isVehicleDocument(entries[2].values, ids), isTrue);
      expect(isVehicleDocument(entries[0].values, ids), isFalse);
      expect(isVehicleDocument(entries[1].values, const {}), isFalse);
    });

    test('vehicle onboarding asks only for vehicle documents', () {
      final docs = vehicleRequiredDocs(
        requiredDocuments: entries,
        vehicleTypeIds: ids,
        partnerTypes: const ['Teksi'],
        area: area,
      );
      expect(docs.map((d) => d.id), unorderedEquals(['puspakom', 'insurance']));
    });

    test('partner onboarding leaves the vehicle documents out', () {
      final docs = requiredDocsFor(
        requiredDocuments: entries,
        partnerTypeValues: const [],
        partnerTypes: const ['Teksi'],
        area: area,
        vehicleTypeIds: ids,
      );
      expect(docs.map((d) => d.id), unorderedEquals(['licence', 'permit']));
    });
  });
}
