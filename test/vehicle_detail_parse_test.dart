// VehicleDetail.fromJson (migration 0366): parses the vehicle, its drivers
// (with their state) and its documents from the approver_vehicle_detail shape.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/approver_inbox_repository.dart';

void main() {
  test('parses vehicle, drivers and documents', () {
    final v = VehicleDetail.fromJson({
      'id': 'veh1',
      'plate': 'VAC7679',
      'make': 'Toyota',
      'model': 'Innova',
      'color': 'Black',
      'year': '2021',
      'status': 'approved',
      'owner_name': 'Nurul Shahida',
      'can_manage': true,
      'drivers': [
        {'assignment_id': 'a1', 'name': 'Mohd Faizul', 'driver_no': '182', 'state': 'active'},
        {'assignment_id': 'a2', 'name': 'Rajesh A/L Kumar', 'driver_no': '221', 'state': 'pending'},
        {'assignment_id': 'a3', 'name': 'Old Driver', 'driver_no': '99', 'state': 'revoked'},
      ],
      'documents': [
        {'id': 'd1', 'doc_name': 'Vehicle Insurance', 'status': 'Approved', 'expiry_date': '2027-02-04', 'provider': 'Etiqa General', 'has_file': true},
      ],
    });

    expect(v.plate, 'VAC7679');
    expect(v.descriptor, 'Toyota · Innova · Black · 2021');
    expect(v.canManage, isTrue);
    expect(v.drivers.length, 3);
    expect(v.drivers[0].state, 'active');
    expect(v.drivers[1].state, 'pending');
    expect(v.drivers[1].driverNo, '221');
    expect(v.documents.single.name, 'Vehicle Insurance');
    expect(v.documents.single.status, 'Approved');
    expect(v.documents.single.expiry, '2027-02-04');
  });

  test('tolerates missing optional fields', () {
    final v = VehicleDetail.fromJson({'id': 'v', 'plate': 'ABC1', 'drivers': null, 'documents': null});
    expect(v.descriptor, isNull);
    expect(v.drivers, isEmpty);
    expect(v.documents, isEmpty);
    expect(v.canManage, isFalse);
  });
}
