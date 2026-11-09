// My Team — the dedicated vehicle-permit sheet (migration 0386): an approver who
// manages the vehicle can put a permit (the EVP / APAD permit, or any other) on
// file by typing its number and expiry. Widget test over the Vehicle sheet with
// a fake repository; the scan path (image picker) is exercised separately by the
// shared document-AI logic.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/permits.dart' show PermitItem;
import 'package:get_ride/src/data/approver_inbox_repository.dart';
import 'package:get_ride/src/data/permits_repository.dart' show VehiclePermits;
import 'package:get_ride/src/features/approver/my_team_screen.dart';
import 'package:get_ride/src/providers.dart' show currentUserIdProvider;
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
      status: 'active', ownerSelf: true, ownerName: 'Self'),
  ],
  allowed: [],
);

VehicleDetail _detail() => const VehicleDetail(
      id: 'v1', plate: 'BMT4420', make: 'Perodua', model: 'Myvi', color: 'Silver', year: '2021',
      descriptor: 'Perodua · Myvi · Silver · 2021', status: 'approved', ownerName: 'Self', canManage: true,
    );

final _permitCard = VehiclePermits(
  permits: [
    PermitItem(typeId: 'pt-evp', name: 'E-hailing vehicle permit (eVP)', shortName: 'eVP',
        state: 'without', validUntil: DateTime(2030, 5, 1)),
  ],
);

class _FakeRepo extends ApproverInboxRepository {
  _FakeRepo()
      : super(SupabaseClient('http://localhost', 'test-anon-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false)));

  (String, String, String?, String?)? permitSet; // (vehicle, typeId, number, expiry)

  @override
  Future<String> setVehiclePermit(String vehicleId, String permitTypeId, {String? number, String? expiry}) async {
    permitSet = (vehicleId, permitTypeId, number, expiry);
    return 'new-doc-id';
  }

  @override
  Future<VehiclePermits?> vehiclePermitCard(String vehicleId) async => _permitCard;
}

Future<_FakeRepo> _openPermitSheet(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 3200);
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
        approverVehiclePermitCardProvider.overrideWith((ref, id) async => _permitCard),
        approverAddableVehicleDocsProvider.overrideWith((ref, id) async => const <AddableDoc>[]),
      ],
      child: MaterialApp(theme: appTheme(Brightness.light), home: const MyTeamMemberScreen(member: _member)),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('member-tab-vehicle')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('vehicle-view-v1')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('permit-upload-pt-evp')));
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('a managed vehicle offers Upload on the EVP permit and saves number + expiry', (tester) async {
    final repo = await _openPermitSheet(tester);

    // The sheet pre-fills expiry from the permit's validUntil.
    expect(find.byKey(const ValueKey('permit-save')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('permit-number')), 'APAD-99123');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('permit-save')));
    await tester.pumpAndSettle();

    expect(repo.permitSet, ('v1', 'pt-evp', 'APAD-99123', '2030-05-01'));
  });
}
