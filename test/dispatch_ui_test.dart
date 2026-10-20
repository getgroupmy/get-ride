// Order dispatch (migration 0251) on screen: the console's form and board,
// the role tabs, the stand admin's staff and charges, the fleet owner's
// fleet, the admin pages and the driver's side — in light and dark.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/dispatch/admin_dispatch_screen.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/dispatch.dart';
import 'package:get_ride/src/data/dispatch_repository.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/dispatch/dispatch_console.dart';
import 'package:get_ride/src/features/dispatch/dispatch_screen.dart';
import 'package:get_ride/src/features/dispatch/fleet_view.dart';
import 'package:get_ride/src/features/dispatch/stand_charges_view.dart';
import 'package:get_ride/src/features/partner/stand_groups_screen.dart';
import 'package:get_ride/src/features/partner/stand_order_label.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';
import 'text_contrast.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));
final _now = DateTime.now().toUtc();

const _group = DispatchGroup(id: 'g1', name: 'Pavilion stand drivers', kind: GroupKind.closed, members: 3);
const _open = DispatchGroup(id: 'g2', name: 'KL city open pool', kind: GroupKind.open, members: 2);

DispatchStand _stand({StandPerms perms = StandPerms.all, String role = 'admin', bool fixed = true}) => DispatchStand(
  id: 's1',
  name: 'Pavilion KL · Taxi stand',
  code: 'PAV',
  lat: 3.149,
  lng: 101.713,
  allowFixedFare: fixed,
  perms: perms,
  role: role,
  fee: const StandFee(type: FeeType.fixed, value: 3, platformValue: 20),
  groups: const [_group, _open],
  groupIds: const ['g1', 'g2'],
);

Map<String, dynamic> _order(String id, String status, {Map<String, dynamic> extra = const {}}) => {
  'id': id,
  'stand_id': 's1',
  'stand_name': 'Pavilion KL · Taxi stand',
  'ticket_no': 'PAV-00$id',
  'status': status,
  'mode': 'broadcast',
  'group_name': 'Pavilion stand drivers',
  'group_kind': 'closed',
  'offered_at': _now.subtract(const Duration(seconds: 18)).toIso8601String(),
  'created_at': _now.toIso8601String(),
  'drop_name': 'Mid Valley',
  'service': 'Taxi',
  'fare_mode': 'fixed',
  'fare': 28,
  'payment': 'counter',
  'trip_code': '4821',
  'share_token': '00000000-0000-0000-0000-000000000abc',
  'events': [
    {
      'action': 'created',
      'detail': 'PAV-00$id · Broadcast to Pavilion stand drivers',
      'actor': 'Aina',
      'at': _now.toIso8601String(),
    },
  ],
  if (status != 'open') ...{
    'partner_name': 'Ali',
    'partner_plate': 'WXY 1234',
    'partner_vehicle': 'Silver Toyota Vios',
  },
  ...extra,
};

class _Repo extends DispatchRepository {
  _Repo({this.roles = DispatchRoles.none, this.orders = const []}) : super(_db);

  DispatchRoles roles;
  List<Map<String, dynamic>> orders;
  final created = <Map<String, dynamic>>[];
  final actions = <String>[];
  final grants = <String>[];
  final decisions = <String>[];
  final fees = <String>[];
  final joins = <String>[];

  @override
  Future<DispatchRoles> myRoles() async => roles;

  @override
  Stream<List<DispatchOrder>> watchBoard({String? standId}) =>
      Stream.value([for (final o in orders) DispatchOrder.fromJson(o)]);

  @override
  Future<List<NearbyDriver>> drivers(String standId) async => const [
    NearbyDriver(
      id: 'd1',
      name: 'Ali',
      plate: 'WXY 1234',
      vehicle: 'Silver Toyota Vios',
      service: 'Taxi',
      km: 0.1,
      state: DriverState.atStand,
    ),
    NearbyDriver(id: 'd2', name: 'Siti', plate: 'VDE 4471', service: 'Taxi', km: 3, state: DriverState.onTrip),
  ];

  @override
  Future<Map<String, dynamic>> report(String standId, {int days = 1}) async => {
    'orders': 4,
    'done': 2,
    'cancelled': 1,
    'fares': 80,
    'fees': 6,
  };

  @override
  Future<DispatchOrder> create(NewOrder o) async {
    created.add(o.toJson());
    return DispatchOrder.fromJson(_order('42', 'open', extra: {'ticket_no': 'PAV-0042', 'drop_name': o.dropName}));
  }

  @override
  Future<DispatchOrder> act(String id, String action, [Map<String, dynamic> args = const {}]) async {
    actions.add('$action $id ${args.isEmpty ? '' : args}'.trim());
    return DispatchOrder.fromJson(orders.firstWhere((o) => o['id'] == id));
  }

  @override
  Future<List<Map<String, dynamic>>> staff(String standId) async => [
    {
      'stand_id': 's1',
      'user_id': 'u4',
      'role': 'staff',
      'name': 'Rizal',
      'phone': '+60 11-222 0002',
      'can_broadcast': true,
      'active': true,
    },
  ];

  @override
  Future<void> setStaff(String standId, String userId, {StandPerms? perms, bool? active}) async =>
      actions.add('staff $userId ${perms?.toStaffRow()} $active');

  @override
  Future<bool> grant({
    required String kind,
    required String name,
    required String phone,
    List<String> standIds = const [],
    String? groupId,
    StandPerms perms = const StandPerms(),
  }) async {
    grants.add('$kind $name $phone $standIds $groupId ${perms.toJson()}');
    return true;
  }

  @override
  Future<void> setStandFee(String standId, StandFee fee) async => fees.add('stand ${fee.type.name} ${fee.value}');

  @override
  Future<void> saveStandCharges(String standId, StandFee fee) async =>
      fees.add('admin ${fee.type.name} ${fee.value} ${fee.setByStand} ${fee.platformValue}');

  @override
  Future<StandStatement> statement(String standId, DateTime from, DateTime to) async => StandStatement.fromJson({
    'orders': [
      {'ticket_no': 'PAV-0039', 'driver': 'Mei Ling', 'fare': 25, 'fee': 3, 'platform': 0.6, 'stand': 2.4},
    ],
    'totals': {'orders': 1, 'fares': 25, 'fees': 3, 'platform': 0.6, 'stand': 2.4, 'counter': 28},
  });

  @override
  Future<List<DispatchStand>> allStands() async => [_stand()];

  @override
  Future<List<DispatchGroup>> allGroups() async => const [
    _group,
    _open,
    DispatchGroup(id: 'g3', name: 'Sunlight Taxi', kind: GroupKind.fleet),
  ];

  @override
  Future<List<Map<String, dynamic>>> standPeople() async => [
    {'stand_id': 's1', 'user_id': 'u3', 'role': 'admin', 'name': 'Pavilion Mall Mgmt', 'active': true},
    {'stand_id': 's1', 'user_id': 'u4', 'role': 'staff', 'name': 'Rizal', 'can_broadcast': true, 'active': true},
  ];

  @override
  Future<List<Map<String, dynamic>>> accounts() async => [
    {
      'kind': 'stand_admin',
      'user_id': 'u3',
      'name': 'Pavilion Mall Mgmt',
      'phone': '+60 12-300 1100',
      'active': true,
      'places': [
        {'id': 's1', 'name': 'Pavilion KL'},
      ],
      'staff': 2,
    },
  ];

  @override
  Future<List<Map<String, dynamic>>> groupPeople(String groupId) async => [
    {'driver_id': 'd5', 'status': 'pending', 'name': 'Daniel', 'plate': 'WRR 1180'},
    {'driver_id': 'd1', 'status': 'approved', 'name': 'Ali', 'plate': 'WXY 1234'},
  ];

  @override
  Future<void> decide(String groupId, String driverId, String status) async =>
      decisions.add('$groupId $driverId $status');

  @override
  Future<Map<String, dynamic>> fleet(String groupId) async => {
    'id': groupId,
    'name': 'Sunlight Taxi',
    'drivers': [
      {
        'driver_id': 'd1',
        'status': 'approved',
        'name': 'Rajesh',
        'plate': 'BMK 3310',
        'service': 'Taxi',
        'state': 'free',
      },
      {'driver_id': 'd5', 'status': 'pending', 'name': 'Daniel', 'plate': 'WRR 1180'},
    ],
    'today': {'orders': 14, 'done': 12, 'cancelled': 1, 'fares': 300},
  };

  @override
  Future<List<Map<String, dynamic>>> fleetVehicles(String groupId) async => [
    {
      'id': 'v1',
      'plate': 'SUN 1',
      'make': 'Toyota',
      'model': 'Vios',
      'service': 'Taxi',
      'status': 'unapproved',
      'documents_ok': true,
      'fleet_id': groupId,
      'drivers': [
        {'driver_id': 'd1', 'name': 'Rajesh', 'approval': 'pending', 'active': true},
      ],
    },
  ];

  @override
  Future<List<({DispatchGroup group, JoinState state})>> joinable() async => [
    (group: _group, state: JoinState.none),
    (group: _open, state: JoinState.pending),
  ];

  @override
  Future<void> askToJoin(String groupId) async => joins.add(groupId);

  final scheduled = <String>[];

  @override
  Future<void> scheduledAction(String id, String action, [Map<String, dynamic> args = const {}]) async =>
      scheduled.add('$action $id ${args.keys.toList()}');

  @override
  Future<({bool found, String? name})> lookupCustomer(String phone) async =>
      phone.replaceAll(RegExp(r'\D'), '').endsWith('21')
      ? (found: true, name: 'Nur Aisyah')
      : (found: false, name: null);
}

const _callCentre = DispatchStand(
  id: 'call',
  name: 'Call centre · phone & text bookings',
  code: 'CALL',
  kind: StandKind.callCentre,
  adminOnly: true,
  admin: true,
  groups: [_open],
);

Map<String, dynamic> _ahead(String id, {bool confirmed = false}) => {
  ..._order(id, 'scheduled'),
  'kind': 'scheduled',
  'pickup_at': _now.add(const Duration(hours: 5)).toIso8601String(),
  'lead_minutes': 30,
  'mode': confirmed ? 'assign' : 'broadcast',
  'driver_target_name': 'Mei Ling',
  'driver_confirmed': confirmed,
  if (confirmed) ...{'partner_name': 'Mei Ling', 'partner_vehicle': 'Silver Toyota Vios', 'partner_plate': 'VBA 8821'},
};

Future<void> _pump(
  WidgetTester tester,
  Widget child,
  _Repo repo, {
  Brightness b = Brightness.light,
  Size size = const Size(1280, 1600),
  List<AdminGrant> grants = const [],
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        supabaseProvider.overrideWithValue(_db),
        ...quietLiveOverrides,
        dispatchRepositoryProvider.overrideWithValue(repo),
        dispatchServiceNamesProvider.overrideWith((_) => const ['Taxi', 'Comfort']),
        adminAccessProvider.overrideWith((_) async => AdminAccess(grants)),
        currentUserIdProvider.overrideWithValue('me'),
      ],
      child: MaterialApp(
        theme: appTheme(b),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  for (final b in Brightness.values) {
    group('${b.name}:', () {
      testWidgets('the console: a broadcast from the form, and its ticket', (tester) async {
        final repo = _Repo(orders: [_order('41', 'open')]);
        await _pump(tester, DispatchConsole(stands: [_stand()], ticking: false), repo, b: b);
        expect(find.text('New order'), findsOneWidget);
        expect(find.byKey(const ValueKey('order-mode')), findsOneWidget, reason: 'both ways to send');
        expect(find.byKey(const ValueKey('fare-fixed')), findsOneWidget);

        await tester.enterText(find.byKey(const ValueKey('order-dest')), 'KL Sentral');
        await tester.enterText(find.byKey(const ValueKey('order-phone')), '+60 12-555 0001');
        await _tap(tester, find.byKey(const ValueKey('fare-fixed')));
        await tester.enterText(find.byKey(const ValueKey('order-fare')), '28');
        await _tap(tester, find.byKey(const ValueKey('pay-cash')));
        await _tap(tester, find.byKey(const ValueKey('order-send')));
        expect(repo.created, hasLength(1));
        expect(repo.created.single, containsPair('drop_name', 'KL Sentral'));
        expect(repo.created.single, containsPair('group_id', 'g1'));
        expect(repo.created.single, containsPair('fare_mode', 'fixed'));
        expect(repo.created.single, containsPair('fare', 28.0));
        expect(repo.created.single, containsPair('payment', 'cash'));
        // The customer's ticket.
        expect(find.byKey(const ValueKey('ticket-no')), findsOneWidget);
        expect(find.text('PAV-0042'), findsWidgets);
        expect(find.text('4821'), findsOneWidget, reason: 'the trip code the driver asks for');
        expect(unreadableTexts(tester, find.byType(AlertDialog)), isEmpty);
        await _tap(tester, find.widgetWithText(FilledButton, 'Done'));
      });

      testWidgets('the console: assigning picks a driver, nearest first', (tester) async {
        final repo = _Repo();
        await _pump(tester, DispatchConsole(stands: [_stand()], ticking: false), repo, b: b);
        await _tap(tester, find.text('Assign a driver'));
        expect(find.text('Ali'), findsOneWidget);
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('driver-car-d1'))).data,
          'Silver Toyota Vios · WXY 1234',
          reason: 'the car they are driving: colour, make, model, then plate',
        );
        expect(find.text('Taxi · 0.1 km · At the stand'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('order-dest')), 'KLCC');
        await _tap(tester, find.byKey(const ValueKey('order-send')));
        expect(find.byKey(const ValueKey('order-error')), findsOneWidget);
        expect(find.text('Pick a driver.'), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('driver-d1')));
        await _tap(tester, find.byKey(const ValueKey('order-send')));
        expect(repo.created.single['driver_id'], 'd1');
        expect(repo.created.single['mode'], 'assign');
      });

      testWidgets('the board: columns, ages, and the actions the access allows', (tester) async {
        final repo = _Repo(
          orders: [
            _order('41', 'open'),
            _order('40', 'accepted', extra: {'payment': 'cash', 'fare_mode': 'meter', 'fare': null}),
            _order('39', 'on_trip', extra: {'fare_mode': 'meter', 'fare': null}),
            _order('38', 'completed'),
          ],
        );
        await _pump(tester, DispatchConsole(stands: [_stand()], ticking: false), repo, b: b);
        expect(find.text('Waiting for a driver'), findsOneWidget);
        expect(find.textContaining('Sent '), findsOneWidget);
        expect(find.text('To: Pavilion stand drivers'), findsOneWidget);
        // A driver on the order: their name, then the car and plate, each labelled.
        for (final id in ['40', '39', '38']) {
          expect(tester.widget<Text>(find.byKey(ValueKey('order-driver-0-$id'))).data, 'Driver: Ali');
          expect(tester.widget<Text>(find.byKey(ValueKey('order-driver-1-$id'))).data, 'Car: Silver Toyota Vios');
          expect(tester.widget<Text>(find.byKey(ValueKey('order-driver-2-$id'))).data, 'Plate: WXY 1234');
        }
        expect(find.byKey(const ValueKey('order-driver-0-41')), findsNothing, reason: 'nobody on a waiting order');
        // The ticket says the same.
        await _tap(tester, find.byKey(const ValueKey('ticket-40')));
        expect(tester.widget<Text>(find.byKey(const ValueKey('ticket-driver-0'))).data, 'Driver: Ali');
        expect(tester.widget<Text>(find.byKey(const ValueKey('ticket-driver-1'))).data, 'Car: Silver Toyota Vios');
        expect(tester.widget<Text>(find.byKey(const ValueKey('ticket-driver-2'))).data, 'Plate: WXY 1234');
        expect(unreadableTexts(tester, find.byType(AlertDialog)), isEmpty);
        await _tap(tester, find.widgetWithText(FilledButton, 'Done'));
        expect(find.byKey(const ValueKey('dispatch-report')), findsOneWidget);
        expect(find.byKey(const ValueKey('cancel-41')), findsOneWidget);
        expect(find.byKey(const ValueKey('reassign-40')), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('picked-40')));
        expect(repo.actions.last, 'picked_up 40');
        // A metered trip asks what the meter shows.
        await _tap(tester, find.byKey(const ValueKey('complete-39')));
        await tester.enterText(find.byKey(const ValueKey('meter-fare')), '23.5');
        await _tap(tester, find.text('Complete').last);
        expect(repo.actions.last, 'complete 39 {fare: 23.5}');
        // Re-send widens to anyone nearby.
        await _tap(tester, find.byKey(const ValueKey('resend-41')));
        await _tap(tester, find.byKey(const ValueKey('resend-widen')));
        expect(repo.actions.last, 'widen 41');
        expect(unreadableTexts(tester, find.byKey(const ValueKey('board-waiting'))), isEmpty);
        expect(unreadableTexts(tester, find.byKey(const ValueKey('board-coming'))), isEmpty);
      });

      testWidgets('staff with broadcast only: no assign, no fixed fare, no cancel', (tester) async {
        final repo = _Repo(orders: [_order('41', 'open'), _order('40', 'accepted')]);
        final staff = _stand(perms: const StandPerms(broadcast: true), role: 'staff');
        await _pump(
          tester,
          DispatchConsole(stands: [staff], ticking: false),
          repo,
          b: b,
          size: const Size(420, 2600),
        );
        expect(find.byKey(const ValueKey('order-mode')), findsNothing);
        expect(find.text('Your access: broadcast only'), findsOneWidget);
        expect(find.byKey(const ValueKey('fare-fixed')), findsNothing);
        expect(find.byKey(const ValueKey('cancel-41')), findsNothing);
        expect(find.byKey(const ValueKey('reassign-40')), findsNothing);
        expect(find.byKey(const ValueKey('dispatch-report')), findsNothing, reason: 'no See reports');
        expect(tester.takeException(), isNull);
      });

      testWidgets('the role tabs: a stand admin, a fleet owner, nobody', (tester) async {
        final repo = _Repo(roles: DispatchRoles(stands: [_stand()]));
        await _pump(tester, const DispatchScreen(ticking: false), repo, b: b);
        expect(find.text('Console'), findsOneWidget);
        expect(find.text('My staff'), findsOneWidget);
        expect(find.text('Charges'), findsOneWidget);
        expect(find.text('My fleet'), findsNothing);

        repo.roles = const DispatchRoles(
          fleets: [DispatchGroup(id: 'g3', name: 'Sunlight Taxi', kind: GroupKind.fleet)],
        );
        await _pump(tester, const DispatchScreen(ticking: false), _Repo(roles: repo.roles), b: b);
        expect(find.text('Console'), findsNothing);
        expect(find.text('Sunlight Taxi · drivers'), findsOneWidget);

        await _pump(tester, const DispatchScreen(ticking: false), _Repo(), b: b);
        expect(find.text('No stand or fleet'), findsOneWidget);
      });

      testWidgets("the stand admin's staff: a new ID with its access, chips change it", (tester) async {
        final repo = _Repo(roles: DispatchRoles(stands: [_stand()]));
        await _pump(tester, const DispatchScreen(ticking: false), repo, b: b);
        await _tap(tester, find.text('My staff'));
        expect(find.text('Rizal'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('staff-name')), 'Aina');
        await tester.enterText(find.byKey(const ValueKey('staff-phone')), '+60 11-222 0001');
        await _tap(tester, find.byKey(const ValueKey('access-new-cancel')));
        await _tap(tester, find.byKey(const ValueKey('staff-create')));
        expect(repo.grants.single, contains('staff Aina +60 11-222 0001 [s1]'));
        expect(repo.grants.single, contains('cancel: true'));
        await _tap(tester, find.byKey(const ValueKey('access-u4-assign')));
        expect(repo.actions.last, contains('can_assign: true'));
        expect(unreadableTexts(tester, find.byType(Scaffold).first), isEmpty);
      });

      testWidgets("charges: the stand admin can't change a fee the admin sets", (tester) async {
        final repo = _Repo();
        await _pump(tester, StandChargesView(stands: [_stand()], admin: false), repo, b: b);
        expect(find.text('Your fee is set by the admin.'), findsOneWidget);
        expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('fee-percent'))).onSelected, isNull);
        expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('platform-fixed'))).onSelected, isNull);
        expect(find.text('Customer pays RM 28.00 · driver gets RM 25.00'), findsOneWidget);
        expect(find.textContaining('the platform takes RM 0.60, stand keeps RM 2.40'), findsOneWidget);
        expect(find.byKey(const ValueKey('statement-totals')), findsOneWidget);

        final open = DispatchStand(
          id: 's1',
          name: 'Pavilion KL',
          code: 'PAV',
          role: 'admin',
          fee: const StandFee(type: FeeType.fixed, value: 3, setByStand: true),
        );
        await _pump(
          tester,
          StandChargesView(key: const ValueKey('open'), stands: [open], admin: false),
          repo,
          b: b,
        );
        expect(find.text("You set your stand's fee."), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('fee-percent')));
        await tester.enterText(find.byKey(const ValueKey('fee-amount')), '10');
        await _tap(tester, find.byKey(const ValueKey('charges-save')));
        expect(repo.fees.single, 'stand percent 10.0');
      });

      testWidgets('the fleet: drivers, vehicles waiting for approval, requests to approve', (tester) async {
        final repo = _Repo();
        await _pump(
          tester,
          const FleetView(
            fleets: [DispatchGroup(id: 'g3', name: 'Sunlight Taxi', kind: GroupKind.fleet)],
          ),
          repo,
          b: b,
        );
        expect(find.text('Rajesh · BMK 3310'), findsOneWidget);
        expect(find.text('SUN 1 · Toyota Vios'), findsOneWidget);
        expect(find.text('Pending review'), findsWidgets);
        expect(find.byKey(const ValueKey('fleet-today')), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('fleet-approve-d5')));
        expect(repo.decisions.single, 'g3 d5 approved');
        expect(unreadableTexts(tester, find.byType(Scaffold).first), isEmpty);
      });

      testWidgets('admin pages: stands with their people, groups, accounts, charges', (tester) async {
        final repo = _Repo(roles: DispatchRoles(stands: [_stand()]));
        await _pump(
          tester,
          const AdminDispatchScreen(ticking: false),
          repo,
          b: b,
          grants: const [AdminGrant(page: '*', edit: true)],
        );
        for (final tab in ['Console', 'Stands', 'Groups & fleets', 'Accounts', 'Charges']) {
          expect(find.text(tab), findsOneWidget);
        }
        await _tap(tester, find.text('Stands'));
        expect(find.text('Pavilion KL · Taxi stand · PAV'), findsOneWidget);
        expect(find.text('Rizal · Staff'), findsOneWidget);
        expect(find.textContaining('Sends to Pavilion stand drivers, KL city open pool'), findsOneWidget);

        await _tap(tester, find.text('Groups & fleets'));
        expect(find.text('Sunlight Taxi · Fleet'), findsOneWidget);
        await _tap(tester, find.text('Pavilion stand drivers · Closed group'));
        expect(find.text('Daniel · WRR 1180'), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('approve-d5')));
        expect(repo.decisions.single, 'g1 d5 approved');
        await tester.pageBack();
        await tester.pumpAndSettle();

        await _tap(tester, find.text('Accounts'));
        expect(find.text('Pavilion Mall Mgmt · Stand admin'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('account-name')), 'TBS Operations');
        await tester.enterText(find.byKey(const ValueKey('account-phone')), '+60 12-300 2200');
        await _tap(tester, find.byKey(const ValueKey('account-create')));
        expect(find.text('Pick their stand.'), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('account-stand-s1')));
        await _tap(tester, find.byKey(const ValueKey('account-create')));
        expect(repo.grants.single, startsWith('stand_admin TBS Operations +60 12-300 2200 [s1]'));

        await _tap(tester, find.text('Charges'));
        await _tap(tester, find.byKey(const ValueKey('setby-stand')));
        await _tap(tester, find.byKey(const ValueKey('charges-save')));
        expect(repo.fees.single, 'admin fixed 3.0 true 20.0');
        expect(unreadableTexts(tester, find.byType(Scaffold).last), isEmpty);
      });

      testWidgets('a read-only admin grant shows the stands and changes nothing', (tester) async {
        final repo = _Repo();
        await _pump(
          tester,
          const AdminDispatchScreen(ticking: false),
          repo,
          b: b,
          grants: const [AdminGrant(page: 'admin-dispatch-stands', edit: false)],
        );
        expect(find.text('Console'), findsNothing);
        expect(find.text('Accounts'), findsNothing);
        expect(find.byKey(const ValueKey('stand-add')), findsNothing);
      });

      testWidgets("the driver's card and the groups to join", (tester) async {
        final repo = _Repo();
        final r = RideRequest({
          'id': 'r1',
          'status': 'open',
          'stand_id': 's1',
          'dispatch_stand_name': 'Pavilion KL',
          'ticket_no': 'PAV-0041',
          'dispatch_mode': 'assign',
          'dispatch_driver_id': 'me',
          'dispatch_payment': 'counter',
          'fare_mode': 'fixed',
        });
        await _pump(
          tester,
          StandOrderLabel(request: r, me: 'me'),
          repo,
          b: b,
        );
        expect(find.text('Assigned to you'), findsOneWidget);
        expect(find.textContaining('Ticket PAV-0041 · Paid at counter'), findsOneWidget);
        expect(unreadableTexts(tester, find.byType(StandOrderLabel)), isEmpty);

        await _pump(tester, const StandGroupsScreen(), repo, b: b);
        expect(find.text('Pavilion stand drivers'), findsOneWidget);
        expect(find.textContaining('Waiting for an admin.'), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('join-ask-g1')));
        expect(repo.joins.single, 'g1');
      });
    });

    group('${b.name}: call centre and bookings ahead,', () {
      testWidgets('the Call centre: booked by, pickup address, nearby drivers, name and phone required', (
        tester,
      ) async {
        final repo = _Repo();
        await _pump(tester, DispatchConsole(stands: const [_callCentre], ticking: false), repo, b: b);
        expect(find.byKey(const ValueKey('via-whatsapp')), findsOneWidget);
        expect(find.byKey(const ValueKey('order-pickup')), findsOneWidget);
        expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('group-nearby'))).selected, isTrue);
        expect(find.textContaining('exactly like a booking made in the app'), findsOneWidget);
        expect(find.byKey(const ValueKey('pay-counter')), findsNothing, reason: 'no counter at a call centre');
        expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('pay-cash'))).selected, isTrue);
        expect(find.text('Customer name'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('order-dest')), 'KLCC');
        await _tap(tester, find.byKey(const ValueKey('order-send')));
        expect(find.text('Find the pickup address.'), findsOneWidget);
        expect(repo.created, isEmpty);
        // The phone finds the customer's account.
        await tester.enterText(find.byKey(const ValueKey('order-phone')), '+60 10-000 0021');
        await tester.pump(const Duration(milliseconds: 700));
        await tester.pumpAndSettle();
        expect(find.textContaining('Found a GET.ride account: Nur Aisyah'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('order-phone')), '+60 19-888 7777');
        await tester.pump(const Duration(milliseconds: 700));
        await tester.pumpAndSettle();
        expect(find.textContaining('booked as a guest'), findsOneWidget);
        expect(unreadableTexts(tester, find.byType(Scaffold).first), isEmpty);
      });

      testWidgets('booking ahead: a date in boxes, a time and the lead time go with the order', (tester) async {
        final repo = _Repo();
        await _pump(tester, DispatchConsole(stands: [_stand()], ticking: false), repo, b: b);
        await _tap(tester, find.text('Schedule'));
        expect(find.byKey(const ValueKey('order-date')), findsOneWidget);
        expect(find.byKey(const ValueKey('lead-15')), findsOneWidget);
        final day = DateTime.now().add(const Duration(days: 2));
        await tester.enterText(find.byKey(const ValueKey('date-box-day')), '${day.day}');
        await tester.enterText(find.byKey(const ValueKey('date-box-month')), '${day.month}');
        await tester.enterText(find.byKey(const ValueKey('date-box-year')), '${day.year}');
        await tester.enterText(find.byKey(const ValueKey('order-time')), '14:30');
        await _tap(tester, find.byKey(const ValueKey('lead-60')));
        await tester.enterText(find.byKey(const ValueKey('order-dest')), 'KLIA');
        await _tap(tester, find.byKey(const ValueKey('order-send')));
        expect(repo.created, hasLength(1));
        final at = DateTime.parse(repo.created.single['pickup_at'] as String).toLocal();
        expect([at.year, at.month, at.day, at.hour, at.minute], [day.year, day.month, day.day, 14, 30]);
        expect(repo.created.single['lead_minutes'], 60);
        await _tap(tester, find.widgetWithText(FilledButton, 'Done'));
      });

      testWidgets('the Scheduled column: when, confirmed or not, Send now and Edit time', (tester) async {
        final repo = _Repo(orders: [_ahead('51', confirmed: true), _ahead('52'), _order('41', 'open')]);
        await _pump(tester, DispatchConsole(stands: [_stand()], ticking: false), repo, b: b);
        expect(find.text('Scheduled'), findsWidgets);
        expect(find.byKey(const ValueKey('board-scheduled')), findsOneWidget);
        expect(tester.widget<Text>(find.byKey(const ValueKey('order-schedule-51'))).data, 'Driver confirmed');
        expect(tester.widget<Text>(find.byKey(const ValueKey('order-driver-1-51'))).data, 'Car: Silver Toyota Vios');
        expect(tester.widget<Text>(find.byKey(const ValueKey('order-schedule-52'))).data, 'Goes out 30 min before');
        expect(find.byKey(const ValueKey('picked-51')), findsNothing);
        await _tap(tester, find.byKey(const ValueKey('send-now-52')));
        expect(repo.scheduled.last, 'release 52 []');
        await _tap(tester, find.byKey(const ValueKey('edit-time-52')));
        expect(find.text('Edit pickup time'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('edit-time-field')), '9');
        await _tap(tester, find.byKey(const ValueKey('edit-time-save')));
        expect(find.textContaining('Pick a time at least'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('edit-time-field')), '23:45');
        await _tap(tester, find.byKey(const ValueKey('edit-time-save')));
        expect(repo.scheduled.last, 'reschedule 52 [pickup_at, lead_minutes]');
        // The ticket says when.
        await _tap(tester, find.byKey(const ValueKey('ticket-52')));
        expect(find.byKey(const ValueKey('ticket-pickup-at')), findsOneWidget);
        expect(unreadableTexts(tester, find.byType(AlertDialog)), isEmpty);
        await _tap(tester, find.widgetWithText(FilledButton, 'Done'));
        expect(unreadableTexts(tester, find.byKey(const ValueKey('board-scheduled'))), isEmpty);
      });

      testWidgets('a Call centre card: pickup to destination and how they booked', (tester) async {
        final repo = _Repo(
          orders: [
            _order(
              '61',
              'accepted',
              extra: {
                'pickup_name': 'Menara A',
                'drop_name': 'KLCC',
                'booked_via': 'whatsapp',
                'rider_account': true,
                'stand_id': 'call',
              },
            ),
          ],
        );
        await _pump(tester, DispatchConsole(stands: const [_callCentre], ticking: false), repo, b: b);
        expect(tester.widget<Text>(find.byKey(const ValueKey('order-route-61'))).data, 'Menara A to KLCC');
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('order-via-61'))).data,
          'Booked by WhatsApp · on their account',
        );
      });
    });
  }
}
