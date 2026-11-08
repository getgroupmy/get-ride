// My Team Member screen → Statistics tab (migration 0367): the KPI grid renders
// the member's driver statistics from approverMemberStatsProvider, formatted
// with thousands separators and RM amounts.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/approver_inbox_repository.dart';
import 'package:get_ride/src/features/approver/my_team_screen.dart';

ApproverGrant _grant() => const ApproverGrant(
      canApprove: true, canUpload: false, canDelete: false, deleteHard: false,
      canCredit: false, canEditProfile: false, canVerifyId: false, scope: 'all', docTypes: [],
    );

const _member = TeamMember(id: 'm1', name: 'Mohd Faizul', status: 'approved');

const _stats = MemberStats(
  inAppJobs: 128, mygigJobs: 34, earning: 3842.50, avgPerKm: 1.94,
  minutesOnline: 9210, onlineKm: 1980, totalKm: 1544, cancelledByDriver: 6, cancelledByUser: 11,
);

void main() {
  testWidgets('Statistics tab shows the KPI grid, formatted', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          approverSelfProvider.overrideWith((ref) async => _grant()),
          approverMemberStatsProvider.overrideWith((ref, key) async => _stats),
        ],
        child: MaterialApp(theme: appTheme(Brightness.light), home: const MyTeamMemberScreen(member: _member)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('member-tab-statistics')));
    await tester.pumpAndSettle();

    expect(find.text('Driver statistics'), findsOneWidget);
    expect(find.text('128'), findsOneWidget);
    expect(find.text('34'), findsOneWidget);
    expect(find.text('RM 3,842.50'), findsOneWidget);
    expect(find.text('RM 1.94'), findsOneWidget);
    expect(find.text('9,210'), findsOneWidget);
    expect(find.text('1,980'), findsOneWidget);
    expect(find.text('1,544'), findsOneWidget);
    expect(find.text('Cancelled by driver'), findsOneWidget);
  });

  test('MemberStats.fromJson parses and rounds', () {
    final s = MemberStats.fromJson({
      'in_app_jobs': 5, 'mygig_jobs': 2, 'earning': 123.4, 'avg_per_km': null,
      'minutes_online': 90, 'online_km': 42, 'total_km': 60, 'cancelled_by_driver': 1, 'cancelled_by_user': 3,
    });
    expect(s.inAppJobs, 5);
    expect(s.earning, 123.4);
    expect(s.avgPerKm, isNull);
    expect(s.totalKm, 60);
  });
}
