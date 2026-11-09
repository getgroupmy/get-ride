// My Team — the Edit vehicle form's "Scan ownership certificate" button
// (migration 0388). The scanned make/model are constrained to the catalogue by
// resolveScannedVehicle (pure, tested below), and the button renders in the
// sheet. The pick→read round trip itself isn't widget-tested because the file
// picker isn't injectable, so the mapping logic is unit-tested instead.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/approver_inbox_repository.dart';
import 'package:get_ride/src/data/vehicle_catalog_repository.dart';
import 'package:get_ride/src/features/approver/my_team_screen.dart';
import 'package:get_ride/src/providers.dart' show currentUserIdProvider;
import 'package:supabase_flutter/supabase_flutter.dart';

const _catalog = [
  VehicleCatalogEntry(make: 'Perodua', model: 'Alza', energyType: 'Petrol', vehicleType: 'MPV', seats: 7),
  VehicleCatalogEntry(make: 'Perodua', model: 'Myvi', energyType: 'Petrol', vehicleType: 'Hatchback', seats: 5),
  // Two energies for the same make+model, so energy can't be inferred.
  VehicleCatalogEntry(make: 'Toyota', model: 'Corolla', energyType: 'Petrol', vehicleType: 'Sedan', seats: 5),
  VehicleCatalogEntry(make: 'Toyota', model: 'Corolla', energyType: 'Hybrid', vehicleType: 'Sedan', seats: 5),
];

ApproverGrant _grant() => const ApproverGrant(
      canApprove: true, canUpload: false, canDelete: false, deleteHard: false,
      canCredit: false, canEditProfile: true, canVerifyId: false, canManageVehicle: true,
      scope: 'all', docTypes: [],
    );

const _member = TeamMember(id: 'm1', name: 'Mohd Faizul', status: 'approved');
const _vehicles = MemberVehicles(
  registered: [
    MemberVehicle(id: 'v1', plate: 'AMX9282', status: 'active', ownerSelf: true, ownerName: 'Self'),
  ],
  allowed: [],
);
VehicleDetail _detail() => const VehicleDetail(
      id: 'v1', plate: 'AMX9282', status: 'unapproved', ownerName: 'Self', canManage: true,
    );

class _FakeRepo extends ApproverInboxRepository {
  _FakeRepo()
      : super(SupabaseClient('http://localhost', 'test-anon-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false)));
  @override
  Future<MemberVehicles?> memberVehicles(String memberId) async => _vehicles;
  @override
  Future<VehicleDetail?> vehicleDetail(String vehicleId) async => _detail();
}

Future<void> _openEdit(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 3400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        approverInboxRepositoryProvider.overrideWithValue(_FakeRepo()),
        currentUserIdProvider.overrideWith((ref) => 'me'),
        approverSelfProvider.overrideWith((ref) async => _grant()),
        approverOwnerDocumentsProvider.overrideWith((ref, id) async => const <ApproverDoc>[]),
        approverMemberWalletProvider.overrideWith((ref, id) async => null),
        approverMemberVehiclesProvider.overrideWith((ref, id) async => _vehicles),
        approverVehicleDetailProvider.overrideWith((ref, id) async => _detail()),
        approverVehiclePermitCardProvider.overrideWith((ref, id) async => null),
        approverAddableVehicleDocsProvider.overrideWith((ref, id) async => const <AddableDoc>[]),
        vehicleCatalogProvider.overrideWith((ref) async => _catalog),
      ],
      child: MaterialApp(theme: appTheme(Brightness.light), home: const MyTeamMemberScreen(member: _member)),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('member-tab-vehicle')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('vehicle-view-v1')));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(const ValueKey('vehicle-edit')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('vehicle-edit')));
  await tester.pumpAndSettle();
}

void main() {
  group('resolveScannedVehicle', () {
    test('a known make+model takes make/model/energy, scanned seats winning', () {
      final r = resolveScannedVehicle(_catalog,
          scannedMake: 'perodua', scannedModel: 'alza', scannedSeats: 6);
      expect(r.make, 'Perodua');
      expect(r.model, 'Alza');
      expect(r.energy, 'Petrol');
      expect(r.seats, 6); // the certificate's seats win over the catalogue's 7
    });

    test('no scanned seats falls back to the model count', () {
      final r = resolveScannedVehicle(_catalog, scannedMake: 'Perodua', scannedModel: 'Myvi');
      expect(r.seats, 5);
      expect(r.energy, 'Petrol');
    });

    test('an unknown make yields nothing but keeps scanned seats', () {
      final r = resolveScannedVehicle(_catalog, scannedMake: 'Lamborghini', scannedModel: 'Urus', scannedSeats: 4);
      expect(r.make, isNull);
      expect(r.model, isNull);
      expect(r.energy, isNull);
      expect(r.seats, 4);
    });

    test('a model that is not of the make is dropped, the make kept', () {
      final r = resolveScannedVehicle(_catalog, scannedMake: 'Perodua', scannedModel: 'Vios', scannedSeats: 5);
      expect(r.make, 'Perodua');
      expect(r.model, isNull);
      expect(r.energy, isNull);
      expect(r.seats, 5);
    });

    test('an ambiguous energy (two for one model) is left unset', () {
      final r = resolveScannedVehicle(_catalog, scannedMake: 'Toyota', scannedModel: 'Corolla');
      expect(r.make, 'Toyota');
      expect(r.model, 'Corolla');
      expect(r.energy, isNull); // Petrol and Hybrid both apply
      expect(r.seats, 5);
    });
  });

  testWidgets('the Edit vehicle sheet offers the Scan ownership certificate button', (tester) async {
    await _openEdit(tester);
    expect(find.byKey(const ValueKey('vehicle-edit-scan-cert')), findsOneWidget);
    expect(find.text('Scan ownership certificate'), findsOneWidget);
  });
}
