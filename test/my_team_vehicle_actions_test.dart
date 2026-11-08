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
    await tester.tap(find.byKey(const ValueKey('vehicle-edit-save')));
    await tester.pumpAndSettle();

    expect(repo.updatedVehicle, 'v1');
    expect(repo.updatedPatch?['plate'], 'BMT4420');
    expect(repo.updatedPatch?['make'], 'Perodua');
    expect(repo.updatedPatch?['color'], 'Blue');
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
}
