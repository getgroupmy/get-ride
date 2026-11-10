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
  _FakeRepo(this._page, {this.vehicles = const []})
      : super(SupabaseClient('http://localhost', 'test-anon-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false)));
  final TeamPage _page;
  final List<CoveredVehicle> vehicles;

  // Records the filters the screen asked with, for assertions.
  String? lastStatus;
  String? lastPresence;
  String? lastUsage;
  String? lastKind;

  @override
  Future<TeamPage> coveredPartners(
      {String? query, TeamMember? after, int limit = ApproverInboxRepository.teamPageSize, String? status, String? presence, String? kind}) async {
    lastStatus = status;
    lastPresence = presence;
    lastKind = kind;
    return _page;
  }

  @override
  Future<CoveredVehiclePage> coveredVehicles(
      {String? query, CoveredVehicle? after, int limit = ApproverInboxRepository.teamPageSize, String? status, String? usage}) async {
    lastStatus = status;
    lastUsage = usage;
    return CoveredVehiclePage(vehicles: vehicles, hasMore: false);
  }
}

Future<void> _pump(WidgetTester tester, List<TeamMember> members, {List<CoveredVehicle> vehicles = const [], _FakeRepo? repo}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        approverInboxRepositoryProvider.overrideWithValue(
          repo ?? _FakeRepo(TeamPage(members: members, hasMore: false), vehicles: vehicles),
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

  test('TeamMember.fromJson reads is_partner, partner_status and effectiveStatus (0398)', () {
    final partner = TeamMember.fromJson({
      'owner_id': 'u1', 'name': 'A', 'status': 'approved',
      'is_partner': true, 'partner_status': 'unapproved',
    });
    expect(partner.isPartner, isTrue);
    expect(partner.partnerStatus, 'unapproved');
    // A partner shows the provider status, not the (approved) account status.
    expect(partner.effectiveStatus, 'unapproved');

    final user = TeamMember.fromJson({'owner_id': 'u2', 'name': 'B', 'status': 'approved'});
    expect(user.isPartner, isFalse);
    expect(user.partnerStatus, isNull);
    expect(user.effectiveStatus, 'approved');
  });

  testWidgets("a partner card shows the partner status, not the account status", (tester) async {
    await _pump(tester, const [
      TeamMember(
        id: 'p1', displayId: 'GR-0009', name: 'Zulfaqar',
        status: 'approved', isPartner: true, partnerStatus: 'unapproved'),
    ]);
    expect(find.text('Zulfaqar'), findsOneWidget);
    // The badge reads the partner status (Unapproved), matching the admin page.
    // Scope to the card so the "Unapproved" status filter chip isn't counted.
    final card = find.byKey(const ValueKey('my-team-member-p1'));
    expect(find.descendant(of: card, matching: find.text('Unapproved')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('Approved')), findsNothing);
  });

  testWidgets('People split: section headers and the kind chips filter the list', (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _FakeRepo(const TeamPage(members: [
      TeamMember(id: 'p1', displayId: 'GR-1', name: 'Aaron Partner', status: 'approved', isPartner: true, partnerStatus: 'approved'),
      TeamMember(id: 'u1', displayId: 'GR-2', name: 'Bella User', status: 'approved'),
    ], hasMore: false));
    await _pump(tester, const [], repo: repo);

    // Everyone (default): both section headers render.
    expect(find.byKey(const ValueKey('team-section-partners')), findsOneWidget);
    expect(find.byKey(const ValueKey('team-section-users')), findsOneWidget);
    expect(find.byKey(const ValueKey('team-kind-partner')), findsOneWidget);

    // Tapping the Users chip reloads with kind=user.
    await tester.tap(find.byKey(const ValueKey('team-kind-user')));
    await tester.pumpAndSettle();
    expect(repo.lastKind, 'user');
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
    // The online pill (scoped to the card — a presence filter chip also reads
    // "Online") and the pending-docs chip.
    expect(
      find.descendant(of: find.byKey(const ValueKey('my-team-member-u1')), matching: find.text('Online')),
      findsOneWidget,
    );
    expect(find.text('2 to review'), findsOneWidget);
    // Docs / Stats shortcuts; the Documents one carries the pending count.
    expect(find.byKey(const ValueKey('my-team-docs-u1')), findsOneWidget);
    expect(find.byKey(const ValueKey('my-team-stats-u1')), findsOneWidget);
    expect(find.text('Documents (2)'), findsOneWidget);
    expect(find.text('Statistics'), findsOneWidget);
  });

  testWidgets('shortcuts show a plain Documents label when nothing is waiting', (tester) async {
    await _pump(tester, const [
      TeamMember(id: 'u5', displayId: 'GR-0005', name: 'Siti', status: 'approved'),
    ]);
    expect(find.byKey(const ValueKey('my-team-docs-u5')), findsOneWidget);
    expect(find.text('Documents'), findsOneWidget);
    expect(find.byKey(const ValueKey('my-team-stats-u5')), findsOneWidget);
  });

  testWidgets('offline member shows no Online pill', (tester) async {
    await _pump(tester, const [
      TeamMember(id: 'u3', displayId: 'GR-0003', name: 'Rajesh', status: 'approved'),
    ]);

    expect(find.text('Rajesh'), findsOneWidget);
    final card = find.byKey(const ValueKey('my-team-member-u3'));
    // No online pill on the card (a presence filter chip reads "Online").
    expect(find.descendant(of: card, matching: find.text('Online')), findsNothing);
    // An offline member now shows a grey "Offline" pill (migration-free UI).
    expect(find.descendant(of: card, matching: find.text('Offline')), findsOneWidget);
    // With no wallet balance the subtitle is the account number alone.
    expect(find.text('#GR-0003'), findsOneWidget);
  });

  testWidgets('the list shows a scope banner at the top', (tester) async {
    await _pump(tester, const [
      TeamMember(id: 'u4', displayId: 'GR-0004', name: 'Lim', status: 'approved'),
    ]);
    expect(find.textContaining('Showing'), findsOneWidget);
  });

  testWidgets('filter bullets render; a status filter reloads with it', (tester) async {
    final repo = _FakeRepo(const TeamPage(
      members: [TeamMember(id: 'u6', displayId: 'GR-0006', name: 'Faiz', status: 'approved')],
      hasMore: false,
    ));
    await _pump(tester, const [], repo: repo);
    // The mode + status + presence bullets are all present.
    expect(find.byKey(const ValueKey('team-mode-partners')), findsOneWidget);
    expect(find.byKey(const ValueKey('team-mode-vehicles')), findsOneWidget);
    expect(find.byKey(const ValueKey('team-status-approved')), findsOneWidget);
    expect(find.byKey(const ValueKey('team-presence-online')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('team-status-unapproved')));
    await tester.pumpAndSettle();
    expect(repo.lastStatus, 'unapproved');
  });

  testWidgets('switching to Vehicles shows vehicle cards and usage bullets', (tester) async {
    final repo = _FakeRepo(
      const TeamPage(members: [], hasMore: false),
      vehicles: const [
        CoveredVehicle(
          id: 'v1', plate: 'JXB7484', make: 'Toyota', model: 'Corolla Cross',
          status: 'approved', usage: 'online', ownerId: 'u1', ownerName: 'Anwar', ownerDisplayId: 'GR-0001',
        ),
      ],
    );
    await _pump(tester, const [], repo: repo);
    await tester.tap(find.byKey(const ValueKey('team-mode-vehicles')));
    await tester.pumpAndSettle();

    // The vehicle card and its usage chip show; usage bullets replace presence.
    expect(find.byKey(const ValueKey('my-team-vehicle-v1')), findsOneWidget);
    expect(find.text('JXB7484'), findsOneWidget);
    expect(find.text('In use · online'), findsWidgets);
    expect(find.byKey(const ValueKey('team-usage-unassigned')), findsOneWidget);
    expect(find.byKey(const ValueKey('team-presence-online')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('team-usage-unassigned')));
    await tester.pumpAndSettle();
    expect(repo.lastUsage, 'unassigned');
  });
}
