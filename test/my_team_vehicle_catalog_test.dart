// My Team — the Edit vehicle form's catalogue pickers (migration 0387): Make /
// Model / Energy are chosen from vehicle_make_models, models are filtered by the
// chosen make, picking a model suggests its seats, and Save sends them. Widget
// test over the Vehicle sheet with a fake repository and an overridden
// catalogue.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/approver_inbox_repository.dart';
import 'package:get_ride/src/data/vehicle_catalog_repository.dart';
import 'package:get_ride/src/features/approver/my_team_screen.dart';
import 'package:get_ride/src/providers.dart' show currentUserIdProvider;
import 'package:supabase_flutter/supabase_flutter.dart';

ApproverGrant _grant() => const ApproverGrant(
      canApprove: true, canUpload: false, canDelete: false, deleteHard: false,
      canCredit: false, canEditProfile: true, canVerifyId: false, canManageVehicle: true,
      scope: 'all', docTypes: [],
    );

const _member = TeamMember(id: 'm1', name: 'Mohd Faizul', status: 'approved');

// A fresh vehicle with no make/model yet, so the pickers start empty.
const _vehicles = MemberVehicles(
  registered: [
    MemberVehicle(id: 'v1', plate: 'AMX9282', status: 'active', ownerSelf: true, ownerName: 'Self'),
  ],
  allowed: [],
);

VehicleDetail _detail() => const VehicleDetail(
      id: 'v1', plate: 'AMX9282', status: 'unapproved', ownerName: 'Self', canManage: true,
    );

const _catalog = [
  VehicleCatalogEntry(make: 'Perodua', model: 'Alza', energyType: 'Petrol', vehicleType: 'MPV', seats: 7),
  VehicleCatalogEntry(make: 'Perodua', model: 'Myvi', energyType: 'Petrol', vehicleType: 'Hatchback', seats: 5),
  VehicleCatalogEntry(make: 'Toyota', model: 'Vios', energyType: 'Petrol', vehicleType: 'Sedan', seats: 5),
];

class _FakeRepo extends ApproverInboxRepository {
  _FakeRepo()
      : super(SupabaseClient('http://localhost', 'test-anon-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false)));

  Map<String, String?>? updatedPatch;

  @override
  Future<void> updateVehicle(String vehicleId, Map<String, String?> patch) async => updatedPatch = patch;

  @override
  Future<MemberVehicles?> memberVehicles(String memberId) async => _vehicles;

  @override
  Future<VehicleDetail?> vehicleDetail(String vehicleId) async => _detail();
}

Future<_FakeRepo> _openEdit(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 3400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repo = _FakeRepo();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        approverInboxRepositoryProvider.overrideWithValue(repo),
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
  return repo;
}

void main() {
  testWidgets('make drives the model list, model suggests seats, and Save sends them', (tester) async {
    final repo = await _openEdit(tester);

    expect(find.byKey(const ValueKey('vehicle-edit-seats')), findsOneWidget);

    // Pick make → the model list is Perodua's.
    await tester.tap(find.byKey(const ValueKey('vehicle-edit-make')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Perodua').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('vehicle-edit-model-Perodua')));
    await tester.pumpAndSettle();
    expect(find.text('Alza'), findsWidgets);
    expect(find.text('Vios'), findsNothing); // a Toyota model is not offered
    await tester.tap(find.text('Alza').last);
    await tester.pumpAndSettle();

    // Alza's seats prefilled.
    expect(find.widgetWithText(TextFormField, '7'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('vehicle-edit-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('vehicle-edit-save')));
    await tester.pumpAndSettle();

    final p = repo.updatedPatch;
    expect(p?['make'], 'Perodua');
    expect(p?['model'], 'Alza');
    expect(p?['energy_type'], 'Petrol');
    expect(p?['seats'], '7');
  });
}
