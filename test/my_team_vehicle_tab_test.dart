// My Team Member screen → Vehicle tab (migration 0364): the two lists
// (registered under this ID, allowed to use) render from
// approverMemberVehiclesProvider, with the member's plates and owner lines.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/approver_inbox_repository.dart';
import 'package:get_ride/src/features/approver/my_team_screen.dart';

ApproverGrant _grant() => const ApproverGrant(
      canApprove: true,
      canUpload: false,
      canDelete: false,
      deleteHard: false,
      canCredit: false,
      canEditProfile: true,
      canVerifyId: false,
      scope: 'all',
      docTypes: [],
    );

const _member = TeamMember(id: 'm1', name: 'Mohd Faizul', ic: '830314025001', status: 'approved');

const _vehicles = MemberVehicles(
  registered: [
    MemberVehicle(
      id: 'v1', plate: 'BMT4420', make: 'Perodua', model: 'Myvi', color: 'Silver', year: '2021',
      status: 'active', ownerSelf: true, ownerName: 'Self', registeredAt: '2025-02-04',
    ),
  ],
  allowed: [
    MemberVehicle(
      id: 'v2', plate: 'VAC7679', make: 'Toyota', model: 'Innova', color: 'Black', year: '2021',
      status: 'active', ownerSelf: false, ownerName: 'Nurul Shahida Bt Redzuan', ownerIc: '831103085914',
      accessActive: true,
    ),
  ],
);

Future<void> _pump(WidgetTester tester, {MemberVehicles? vehicles = _vehicles}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        approverSelfProvider.overrideWith((ref) async => _grant()),
        approverOwnerDocumentsProvider.overrideWith((ref, id) async => const <ApproverDoc>[]),
        approverMemberWalletProvider.overrideWith((ref, id) async => null),
        approverMemberVehiclesProvider.overrideWith((ref, id) async => vehicles),
      ],
      child: MaterialApp(theme: appTheme(Brightness.light), home: const MyTeamMemberScreen(member: _member)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Vehicle tab lists registered and allowed-to-use vehicles', (tester) async {
    await _pump(tester);

    // Default tab is Profile; the Vehicle plates are not shown yet.
    expect(find.text('BMT4420'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('member-tab-vehicle')));
    await tester.pumpAndSettle();

    expect(find.text('REGISTERED UNDER THIS ID'), findsOneWidget);
    expect(find.text('ALLOWED TO USE'), findsOneWidget);
    expect(find.text('BMT4420'), findsOneWidget);
    expect(find.text('VAC7679'), findsOneWidget);
    // Owner lines: Self (registered) and the other owner's national ID.
    expect(find.textContaining('Owner: Self'), findsOneWidget);
    expect(find.textContaining('Nurul Shahida Bt Redzuan'), findsOneWidget);
    expect(find.textContaining('National ID 831103085914'), findsOneWidget);
  });

  testWidgets('Vehicle tab shows an empty state when the member has no vehicles', (tester) async {
    await _pump(tester, vehicles: const MemberVehicles(registered: [], allowed: []));
    await tester.tap(find.byKey(const ValueKey('member-tab-vehicle')));
    await tester.pumpAndSettle();
    expect(find.text('No vehicles'), findsOneWidget);
  });
}
