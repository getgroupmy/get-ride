// My Team member screen (migrations 0357–0362): the approver's action buttons
// on a covered member are gated by their grant flags —
//   can_edit_profile → Edit profile / Payout / Change mobile
//   can_credit       → Add credit
// and the member's GET.wallet balance is shown. These are widget tests over
// MyTeamMemberScreen with the approver grant, documents and wallet providers
// overridden, so nothing touches the network.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/approver_inbox_repository.dart';
import 'package:get_ride/src/features/approver/my_team_screen.dart';

ApproverGrant _grant({bool credit = false, bool edit = false, bool verify = false}) => ApproverGrant(
      canApprove: true,
      canUpload: false,
      canDelete: false,
      deleteHard: false,
      canCredit: credit,
      canEditProfile: edit,
      canVerifyId: verify,
      scope: 'all',
      docTypes: const [],
    );

const _member = TeamMember(
  id: 'm1',
  displayId: 'GR-0001',
  name: 'Test Member',
  phone: '+60123456789',
  status: 'approved',
);

final _editKey = const ValueKey('my-team-edit-profile');
final _payoutKey = const ValueKey('profile-edit-payout');
final _phoneKey = const ValueKey('profile-edit-mobile');
final _creditKey = const ValueKey('my-team-add-credit');

Future<void> _pump(WidgetTester tester, {required ApproverGrant grant, double? wallet = 12.5}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        approverSelfProvider.overrideWith((ref) async => grant),
        approverOwnerDocumentsProvider.overrideWith((ref, id) async => const <ApproverDoc>[]),
        approverMemberWalletProvider.overrideWith((ref, id) async => wallet),
      ],
      child: MaterialApp(
        theme: appTheme(Brightness.light),
        home: const MyTeamMemberScreen(member: _member),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('all grants: every action shows, with the wallet balance', (tester) async {
    await _pump(tester, grant: _grant(credit: true, edit: true, verify: true));

    expect(find.byKey(_editKey), findsOneWidget);
    expect(find.byKey(_payoutKey), findsOneWidget);
    expect(find.byKey(_phoneKey), findsOneWidget);
    expect(find.byKey(_creditKey), findsOneWidget);
    // Name in the app bar and the header card.
    expect(find.text('Test Member'), findsWidgets);
    // The member's GET.wallet balance, read via approverMemberWalletProvider.
    expect(find.text('RM 12.50'), findsOneWidget);
  });

  testWidgets('no grants: no action buttons', (tester) async {
    await _pump(tester, grant: _grant());

    expect(find.byKey(_editKey), findsNothing);
    expect(find.byKey(_payoutKey), findsNothing);
    expect(find.byKey(_phoneKey), findsNothing);
    expect(find.byKey(_creditKey), findsNothing);
  });

  testWidgets('can_credit only: Add credit shows, the edit actions do not', (tester) async {
    await _pump(tester, grant: _grant(credit: true));

    expect(find.byKey(_creditKey), findsOneWidget);
    expect(find.byKey(_editKey), findsNothing);
    expect(find.byKey(_payoutKey), findsNothing);
    expect(find.byKey(_phoneKey), findsNothing);
  });

  testWidgets('can_edit_profile only: edit actions show, Add credit does not', (tester) async {
    await _pump(tester, grant: _grant(edit: true));

    expect(find.byKey(_editKey), findsOneWidget);
    expect(find.byKey(_payoutKey), findsOneWidget);
    expect(find.byKey(_phoneKey), findsOneWidget);
    expect(find.byKey(_creditKey), findsNothing);
  });

  testWidgets('no wallet balance available: the balance row is hidden', (tester) async {
    await _pump(tester, grant: _grant(edit: true), wallet: null);

    expect(find.textContaining('RM'), findsNothing);
    // The edit actions still render regardless of the wallet.
    expect(find.byKey(_editKey), findsOneWidget);
  });
}
