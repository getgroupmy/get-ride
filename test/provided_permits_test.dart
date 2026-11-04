// The permits GET.ride provides, built from vehicle_service_status rows
// (provided_permits.dart). Made-up vehicles and services only.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/provided_permits.dart';

Map<String, dynamic> _row(String service, String status, {String? type, String? name}) => {
      'service': service,
      'status': status,
      'permit_type': type,
      'permit_name': name,
    };

void main() {
  group('providedPermits', () {
    test('keeps rows that name a permit, and waiting rows even without a type', () {
      final out = providedPermits([
        _row('eHailing', 'waiting_permit', type: 'evp', name: 'eVP'),
        _row('City', 'waiting_permit'), // legacy: waiting with no permit_type still counts
        _row('Teksi', 'paused_age'), // a plain age check, not a permit
        _row('Courier', 'active'), // active with no permit_type
      ]);
      expect(out.map((p) => p.service), ['City', 'eHailing']);
    });

    test('maps waiting_permit to waiting and anything else to onFile', () {
      final out = providedPermits([
        _row('eHailing', 'waiting_permit', type: 'evp', name: 'eVP'),
        _row('Teksi', 'active', type: 'psv', name: 'PSV'),
      ]);
      final byService = {for (final p in out) p.service: p};
      expect(byService['eHailing']!.state, ProvidedPermitState.waiting);
      expect(byService['eHailing']!.waiting, isTrue);
      expect(byService['Teksi']!.state, ProvidedPermitState.onFile);
      expect(byService['Teksi']!.waiting, isFalse);
    });

    test('falls back to a generic name and attaches the plate', () {
      final out = providedPermits([
        _row('eHailing', 'waiting_permit', type: 'evp'),
      ], plate: 'ABC 1234');
      expect(out.single.name, 'Vehicle permit');
      expect(out.single.plate, 'ABC 1234');
      expect(out.single.permitType, 'evp');
    });

    test('is ordered by service, case-insensitively, and stable', () {
      final out = providedPermits([
        _row('Teksi', 'active', type: 'psv', name: 'PSV'),
        _row('eHailing', 'waiting_permit', type: 'evp', name: 'eVP'),
      ]);
      expect(out.map((p) => p.service), ['eHailing', 'Teksi']);
    });

    test('status line reads for the driver', () {
      final out = providedPermits([
        _row('eHailing', 'waiting_permit', type: 'evp', name: 'eVP'),
        _row('Teksi', 'active', type: 'psv', name: 'PSV'),
      ]);
      final byService = {for (final p in out) p.service: p};
      expect(byService['eHailing']!.statusLine, 'Waiting for GET.ride to upload it');
      expect(byService['Teksi']!.statusLine, 'Uploaded by GET.ride');
    });

    test('empty when there are no permit rows', () {
      expect(providedPermits(const []), isEmpty);
      expect(providedPermits([_row('Courier', 'active')]), isEmpty);
    });
  });

  group('waitingProvidedPermits', () {
    test('returns only the permits still waiting for GET.ride', () {
      final out = waitingProvidedPermits([
        _row('eHailing', 'waiting_permit', type: 'evp', name: 'eVP'),
        _row('Teksi', 'active', type: 'psv', name: 'PSV'),
      ], plate: 'ABC 1234');
      expect(out.map((p) => p.service), ['eHailing']);
      expect(out.single.plate, 'ABC 1234');
    });
  });

  group('providedPermitDocRow', () {
    final status = {
      'vehicle_id': 'veh-1',
      'service': 'eHailing',
      'status': 'waiting_permit',
      'permit_type': 'evp',
      'permit_name': 'eVP',
    };
    const vehicle = {'id': 'veh-1', 'plate': 'ABC 1234', 'owner_partner_id': 'p-1'};
    const partners = {
      'p-1': {'id': 'p-1', 'name': 'Nizam', 'phone': '+60123'},
    };

    test('shapes a waiting permit into a To-review document row', () {
      final row = providedPermitDocRow(status, vehicle: vehicle, partners: partners)!;
      expect(row['id'], 'permit:veh-1:eHailing');
      expect(row['doc_name'], 'eVP');
      expect(row['status'], 'Pending Review');
      expect(row['partner_id'], 'p-1');
      expect(row['vehicle_id'], 'veh-1');
      expect(row['_owner'], 'Nizam');
      expect(row['_plate'], 'ABC 1234');
      expect(row['_providedPermit'], true);
      expect(row['uploaded_at'], isNull);
    });

    test('falls back to the phone when the partner has no name', () {
      final row = providedPermitDocRow(status, vehicle: vehicle, partners: {
        'p-1': {'id': 'p-1', 'phone': '+60123'},
      })!;
      expect(row['_owner'], '+60123');
    });

    test('tolerates a missing vehicle / partner lookup', () {
      final row = providedPermitDocRow(status)!;
      expect(row['partner_id'], isNull);
      expect(row['_owner'], isNull);
      expect(row['_plate'], isNull);
      expect(row['doc_name'], 'eVP');
    });

    test('includes a legacy waiting row with no permit_type', () {
      final row = providedPermitDocRow(_row('Courier', 'waiting_permit'))!;
      expect(row['_providedPermit'], true);
      expect(row['doc_name'], 'Vehicle permit');
    });

    test('is null for a row that is not waiting (uploaded file shows on its own)', () {
      expect(providedPermitDocRow(_row('Teksi', 'active', type: 'psv', name: 'PSV')), isNull);
      expect(providedPermitDocRow(_row('eHailing', 'paused_age')), isNull);
    });
  });
}
