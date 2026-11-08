// My Team list (migration 0368): the richer member card shows the member's
// GET.wallet balance and account number, where they drive (service city), when
// they registered and last changed, and an "Online" pill when they are driving
// now. These are a fromJson mapping test plus a widget test over MyTeamScreen
// with a fake repository, so nothing touches the network.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/approver_inbox_repository.dart';
import 'package:get_ride/src/features/approver/my_team_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeRepo extends ApproverInboxRepository {
  _FakeRepo(this._page)
      : super(SupabaseClient('http://localhost', 'test-anon-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false)));
  final TeamPage _page;
  @override
  Future<TeamPage> coveredPartners({String? query, TeamMember? after, int limit = ApproverInboxRepository.teamPageSize}) async => _page;
}

Future<void> _pump(WidgetTester tester, List<TeamMember> members) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        approverInboxRepositoryProvider.overrideWithValue(
          _FakeRepo(TeamPage(members: members, hasMore: false)),
        ),
      ],
      child: MaterialApp(theme: appTheme(Brightness.light), home: const MyTeamScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('TeamMember.fromJson reads the 0368 card fields', () {
    final m = TeamMember.fromJson({
      'owner_id': 'u1',
      'display_id': 'GR-0001',
      'name': 'Mohd Faizul',
      'wallet_balance': 1284.5,
      'service_city': 'Kuala Lumpur',
      'registered_at': '2026-02-04T08:00:00Z',
      'updated_at': '2026-11-01T10:30:00Z',
      'online': true,
    });
    expect(m.walletBalance, 1284.5);
    expect(m.serviceCity, 'Kuala Lumpur');
    expect(m.registeredAt, isNotNull);
    expect(m.registeredAt!.year, 2026);
    expect(m.updatedAt, isNotNull);
    expect(m.online, isTrue);
  });

  test('TeamMember.fromJson tolerates the fields being absent', () {
    final m = TeamMember.fromJson({'owner_id': 'u2', 'name': 'Someone'});
    expect(m.walletBalance, isNull);
    expect(m.serviceCity, isNull);
    expect(m.registeredAt, isNull);
    expect(m.updatedAt, isNull);
    expect(m.online, isFalse);
  });

  testWidgets('a team card shows balance, account number, service city and Online', (tester) async {
    await _pump(tester, const [
      TeamMember(
        id: 'u1',
        displayId: 'GR-0001',
        name: 'Mohd Faizul',
        status: 'approved',
        phone: '+60123456789',
        plate: 'VAC7679',
        vehicleLabel: 'Toyota Innova',
        walletBalance: 1284.5,
        serviceCity: 'Kuala Lumpur',
        online: true,
        pendingDocs: 2,
      ),
    ]);

    expect(find.text('Mohd Faizul'), findsOneWidget);
    // Balance + account number on one subtitle line.
    expect(find.text('RM 1,284.50 · #GR-0001'), findsOneWidget);
    // Service city in the info grid, and its label.
    expect(find.text('Kuala Lumpur'), findsOneWidget);
    expect(find.text('SERVICE CITY'), findsOneWidget);
    // The online pill and the pending-docs chip.
    expect(find.text('Online'), findsOneWidget);
    expect(find.text('2 to review'), findsOneWidget);
  });

  testWidgets('offline member shows no Online pill', (tester) async {
    await _pump(tester, const [
      TeamMember(id: 'u3', displayId: 'GR-0003', name: 'Rajesh', status: 'approved'),
    ]);

    expect(find.text('Rajesh'), findsOneWidget);
    expect(find.text('Online'), findsNothing);
    // With no wallet balance the subtitle is the account number alone.
    expect(find.text('#GR-0003'), findsOneWidget);
  });
}
