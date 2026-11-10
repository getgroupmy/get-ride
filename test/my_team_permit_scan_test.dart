// My Team — the vehicle-permit sheet's "Scan a photo" path reads the operating /
// e-hailing permit (Malaysia: the APAD / EVP permit; named differently per
// country) with the vehicle-permit-read function (Gemini) and surfaces the
// plate the permit is issued for, so the approver can catch a permit issued for
// a different car. The pick→read round trip isn't widget-tested (the image
// picker isn't injectable), so the shaping (PermitRead.fromJson) and the plate
// comparison (permitPlateMatches) are unit-tested, and the scan button is
// asserted to render in the sheet.
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
  @override
  Future<VehiclePermits?> vehiclePermitCard(String vehicleId) async => _permitCard;
}

Future<void> _openPermitSheet(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 3200);
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
}

void main() {
  group('PermitRead.fromJson', () {
    test('reads the four fields, trimming blanks and the literal "null" to null', () {
      final p = PermitRead.fromJson(const {
        'document_number': 'APAD-123456',
        'expiry_date': '2026-12-31',
        'plate': 'WXY 1234',
        'authority': 'APAD',
      });
      expect(p.documentNumber, 'APAD-123456');
      expect(p.expiryDate, '2026-12-31');
      expect(p.plate, 'WXY 1234');
      expect(p.authority, 'APAD');
      expect(p.isEmpty, isFalse);
    });

    test('a nothing-read answer is empty', () {
      final p = PermitRead.fromJson(const {
        'document_number': null, 'expiry_date': '', 'plate': 'null', 'authority': null,
      });
      expect(p.isEmpty, isTrue);
    });
  });

  group('permitPlateMatches', () {
    test('ignores case and separators', () {
      expect(permitPlateMatches('WXY 1234', 'wxy-1234'), isTrue);
      expect(permitPlateMatches('BMT4420', 'B M T 4 4 2 0'), isTrue);
    });
    test('a different plate does not match', () {
      expect(permitPlateMatches('WXY 1234', 'WXY 1235'), isFalse);
    });
    test('empty or null never matches', () {
      expect(permitPlateMatches('', 'WXY 1234'), isFalse);
      expect(permitPlateMatches(null, null), isFalse);
      expect(permitPlateMatches('WXY 1234', null), isFalse);
    });
  });

  testWidgets('the permit sheet offers the Scan a photo button', (tester) async {
    await _openPermitSheet(tester);
    expect(find.byKey(const ValueKey('permit-scan')), findsOneWidget);
    expect(find.text('Scan a photo'), findsOneWidget);
  });
}
