// My Team → Vehicle detail sheet actions (migration 0369): an approver who can
// manage the vehicle sees Assign driver / Edit vehicle; the Edit form pre-fills
// from the vehicle and sends a trimmed patch to approver_update_vehicle. Widget
// tests over MyTeamMemberScreen with a fake repository, so nothing hits the net.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/approver_inbox_repository.dart';
import 'package:get_ride/src/data/permits_repository.dart' show VehiclePermits;
import 'package:get_ride/src/features/approver/my_team_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

ApproverGrant _grant() => const ApproverGrant(
      canApprove: true, canUpload: false, canDelete: false, deleteHard: false,
      canCredit: false, canEditProfile: true, canVerifyId: false, canManageVehicle: true,
      scope: 'all', docTypes: [],
    );

const _member = TeamMember(id: 'm1', name: 'Mohd Faizul', status: 'approved');

const _vehicles = MemberVehicles(
  registered: [
    MemberVehicle(
      id: 'v1', plate: 'BMT4420', make: 'Perodua', model: 'Myvi', color: 'Silver', year: '2021',
      status: 'active', ownerSelf: true, ownerName: 'Self',
    ),
  ],
  allowed: [],
);

VehicleDetail _detail({required bool canManage}) => VehicleDetail(
      id: 'v1', plate: 'BMT4420', make: 'Perodua', model: 'Myvi', color: 'Silver', year: '2021',
      descriptor: 'Perodua · Myvi · Silver · 2021', status: 'approved', ownerName: 'Self',
      canManage: canManage,
    );

class _FakeRepo extends ApproverInboxRepository {
  _FakeRepo()
      : super(SupabaseClient('http://localhost', 'test-anon-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false)));

  Map<String, String?>? updatedPatch;
  String? updatedVehicle;
  (String, String)? assigned;

  @override
  Future<void> updateVehicle(String vehicleId, Map<String, String?> patch) async {
    updatedVehicle = vehicleId;
    updatedPatch = patch;
  }

  @override
  Future<void> assignVehicleDriver(String vehicleId, String memberId) async {
    assigned = (vehicleId, memberId);
  }

  (String, String)? accessSet; // (assignmentId, action)

  @override
  Future<void> setVehicleAccess(String assignmentId, String action) async {
    accessSet = (assignmentId, action);
  }

  VehiclePlateHit? plateHit;
  String? searchedPlate;

  @override
  Future<VehiclePlateHit?> findVehicleByPlate(String plate) async {
    searchedPlate = plate;
    return plateHit;
  }

  @override
  Future<VehiclePermits?> vehiclePermitCard(String vehicleId) async => null;

  (String, String)? createdVehicleDoc; // (vehicleId, docId)

  @override
  Future<({String id, String ownerId})> createVehicleDocument(String vehicleId, String docId, String docName) async {
    createdVehicleDoc = (vehicleId, docId);
    return (id: 'new-veh-doc', ownerId: 'm1');
  }

  @override
  Future<List<ApproverDoc>> ownerDocuments(String ownerId) async => const <ApproverDoc>[];

  @override
  Future<TeamPage> coveredPartners({String? query, TeamMember? after, int limit = ApproverInboxRepository.teamPageSize}) async =>
      const TeamPage(members: [TeamMember(id: 'm2', displayId: 'GR-0002', name: 'Rajesh')], hasMore: false);
}

Future<_FakeRepo> _openSheet(WidgetTester tester, {required bool canManage}) async {
  final repo = _FakeRepo();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        approverInboxRepositoryProvider.overrideWithValue(repo),
        approverSelfProvider.overrideWith((ref) async => _grant()),
        approverOwnerDocumentsProvider.overrideWith((ref, id) async => const <ApproverDoc>[]),
        approverMemberWalletProvider.overrideWith((ref, id) async => null),
        approverMemberVehiclesProvider.overrideWith((ref, id) async => _vehicles),
        approverVehicleDetailProvider.overrideWith((ref, id) async => _detail(canManage: canManage)),
        approverAddableVehicleDocsProvider.overrideWith((ref, id) async =>
            const [AddableDoc(docId: 'veh-type', name: 'Inspection (Puspakom)', required: true)]),
      ],
      child: MaterialApp(theme: appTheme(Brightness.light), home: const MyTeamMemberScreen(member: _member)),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('member-tab-vehicle')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('vehicle-view-v1')));
  await tester.pumpAndSettle();
  return repo;
}

/// A member with one allowed-to-use vehicle in the given access state, plus the
/// self-registered car, for the Vehicle tab action tests (migration 0376).
MemberVehicles _vehiclesWithAllowed({required String approval, bool active = true}) => MemberVehicles(
      registered: _vehicles.registered,
      allowed: [
        MemberVehicle(
          id: 'v9', plate: 'VAC7679', make: 'Toyota', model: 'Innova', color: 'Black', year: '2021',
          status: 'active', ownerSelf: false, ownerName: 'Nurul Shahida',
          accessApproval: approval, accessActive: active, assignmentId: 'a9',
        ),
      ],
    );

/// Pump the member screen straight onto the Vehicle tab (no detail sheet), with
/// the given allowed-vehicle list. Returns the fake repo.
Future<_FakeRepo> _pumpVehicleTab(WidgetTester tester, {required MemberVehicles vehicles}) async {
  final repo = _FakeRepo();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        approverInboxRepositoryProvider.overrideWithValue(repo),
        approverSelfProvider.overrideWith((ref) async => _grant()),
        approverOwnerDocumentsProvider.overrideWith((ref, id) async => const <ApproverDoc>[]),
        approverMemberWalletProvider.overrideWith((ref, id) async => null),
        approverMemberVehiclesProvider.overrideWith((ref, id) async => vehicles),
      ],
      child: MaterialApp(theme: appTheme(Brightness.light), home: const MyTeamMemberScreen(member: _member)),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('member-tab-vehicle')));
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('can-manage approver sees Assign driver and Edit vehicle', (tester) async {
    await _openSheet(tester, canManage: true);
    expect(find.byKey(const ValueKey('vehicle-assign-driver')), findsOneWidget);
    expect(find.byKey(const ValueKey('vehicle-edit')), findsOneWidget);
  });

  testWidgets('without the grant, neither action shows', (tester) async {
    await _openSheet(tester, canManage: false);
    expect(find.byKey(const ValueKey('vehicle-assign-driver')), findsNothing);
    expect(find.byKey(const ValueKey('vehicle-edit')), findsNothing);
  });

  testWidgets('Edit vehicle pre-fills and sends a trimmed patch', (tester) async {
    final repo = await _openSheet(tester, canManage: true);

    await tester.ensureVisible(find.byKey(const ValueKey('vehicle-edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('vehicle-edit')));
    await tester.pumpAndSettle();

    // Pre-filled from the vehicle.
    expect(find.widgetWithText(TextFormField, 'BMT4420'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Perodua'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Myvi'), findsOneWidget);

    // Change the colour and save.
    await tester.enterText(find.byKey(const ValueKey('vehicle-edit-color')), 'Blue');
    await tester.ensureVisible(find.byKey(const ValueKey('vehicle-edit-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('vehicle-edit-save')));
    await tester.pumpAndSettle();

    expect(repo.updatedVehicle, 'v1');
    expect(repo.updatedPatch?['plate'], 'BMT4420');
    expect(repo.updatedPatch?['make'], 'Perodua');
    expect(repo.updatedPatch?['color'], 'Blue');
  });

  testWidgets('Edit vehicle sends the full spec and owner patch', (tester) async {
    final repo = await _openSheet(tester, canManage: true);

    await tester.ensureVisible(find.byKey(const ValueKey('vehicle-edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('vehicle-edit')));
    await tester.pumpAndSettle();

    // Fill the spec and owner text fields (status pre-fills from the vehicle).
    Future<void> fill(String key, String value) async {
      await tester.ensureVisible(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(ValueKey(key)), value);
    }

    await fill('vehicle-edit-type', 'MPV');
    await fill('vehicle-edit-energy', 'Petrol');
    await fill('vehicle-edit-vin', 'MHFXW9F3XM1234567');
    await fill('vehicle-edit-engine', '2GD1234567');
    await fill('vehicle-edit-owner-name', 'Nurul Shahida');
    await fill('vehicle-edit-owner-ic', '831103085914');
    await fill('vehicle-edit-owner-phone', '+60126640912');

    await tester.ensureVisible(find.byKey(const ValueKey('vehicle-edit-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('vehicle-edit-save')));
    await tester.pumpAndSettle();

    final p = repo.updatedPatch;
    expect(repo.updatedVehicle, 'v1');
    expect(p?['vehicle_type'], 'MPV');
    expect(p?['energy_type'], 'Petrol');
    expect(p?['vin'], 'MHFXW9F3XM1234567');
    expect(p?['engine_number'], '2GD1234567');
    expect(p?['owner_name'], 'Nurul Shahida');
    expect(p?['owner_ic'], '831103085914');
    expect(p?['owner_phone'], '+60126640912');
    // Status pre-filled from the vehicle detail ('approved') and is sent.
    expect(p?['status'], 'approved');
  });

  testWidgets('a missing vehicle doc offers Upload on behalf and creates it', (tester) async {
    final repo = await _openSheet(tester, canManage: true);

    expect(find.text('Inspection (Puspakom)'), findsOneWidget);
    expect(find.text('Status: No Document'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('doc-upload-onbehalf-veh-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('doc-upload-onbehalf-veh-type')), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(repo.createdVehicleDoc, ('v1', 'veh-type'));
  });

  testWidgets('Assign driver picks a covered member and assigns them', (tester) async {
    final repo = await _openSheet(tester, canManage: true);

    await tester.ensureVisible(find.byKey(const ValueKey('vehicle-assign-driver')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('vehicle-assign-driver')));
    await tester.pumpAndSettle();

    // The covered member appears in the picker; tap them.
    await tester.tap(find.text('Rajesh').last);
    await tester.pumpAndSettle();

    expect(repo.assigned, ('v1', 'm2'));
  });

  testWidgets('a pending allowed vehicle shows Approve/Decline and approves', (tester) async {
    final repo = await _pumpVehicleTab(tester, vehicles: _vehiclesWithAllowed(approval: 'pending'));

    expect(find.byKey(const ValueKey('vehicle-approve-a9')), findsOneWidget);
    expect(find.byKey(const ValueKey('vehicle-decline-a9')), findsOneWidget);
    // An active self-registered car shows no access buttons.
    expect(find.byKey(const ValueKey('vehicle-revoke-a9')), findsNothing);

    await tester.ensureVisible(find.byKey(const ValueKey('vehicle-approve-a9')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('vehicle-approve-a9')));
    await tester.pumpAndSettle();
    expect(repo.accessSet, ('a9', 'approve'));
  });

  testWidgets('an active allowed vehicle shows Revoke and revokes', (tester) async {
    final repo = await _pumpVehicleTab(tester, vehicles: _vehiclesWithAllowed(approval: 'approved'));

    expect(find.byKey(const ValueKey('vehicle-revoke-a9')), findsOneWidget);
    expect(find.byKey(const ValueKey('vehicle-approve-a9')), findsNothing);

    await tester.ensureVisible(find.byKey(const ValueKey('vehicle-revoke-a9')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('vehicle-revoke-a9')));
    await tester.pumpAndSettle();
    expect(repo.accessSet, ('a9', 'revoke'));
  });

  testWidgets('Assign another vehicle finds by plate and grants access', (tester) async {
    final repo = await _pumpVehicleTab(tester, vehicles: _vehiclesWithAllowed(approval: 'approved'));
    repo.plateHit = const VehiclePlateHit(
      found: true, inScope: true, id: 'v-found', plate: 'WXY1180', make: 'Honda', model: 'City',
    );

    await tester.ensureVisible(find.byKey(const ValueKey('vehicle-assign-another')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('vehicle-assign-another')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('assign-vehicle-plate')), 'WXY1180');
    await tester.tap(find.byKey(const ValueKey('assign-vehicle-find')));
    await tester.pumpAndSettle();
    expect(repo.searchedPlate, 'WXY1180');

    await tester.ensureVisible(find.byKey(const ValueKey('assign-vehicle-grant')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('assign-vehicle-grant')));
    await tester.pumpAndSettle();
    expect(repo.assigned, ('v-found', 'm1'));
  });
}
