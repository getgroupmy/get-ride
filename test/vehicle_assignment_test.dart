import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/people/vehicle_drivers.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/vehicle_assignment.dart';
import 'package:get_ride/src/data/vehicle_assignment_repository.dart';
import 'package:get_ride/src/features/partner/vehicle_picker.dart';
import 'package:get_ride/src/providers.dart';

Map<String, dynamic> _car(
  String id,
  String plate, {
  String status = 'approved',
  bool docs = true,
  bool complete = true,
}) => {
  'id': id,
  'plate': plate,
  'make': 'Proton',
  'model': complete ? 'Saga' : '',
  'year': '2022',
  'color': 'White',
  'image_front': 'f',
  'image_left': 'l',
  'image_right': 'r',
  'image_back': 'b',
  'owner_name': 'Ali',
  'owner_phone': '0123456789',
  'owner_ic': '900101-01-1234',
  'documents_ok': docs,
  'status': status,
  'permit': 'approved',
};

class _FakeRepo implements VehicleAssignmentRepository {
  _FakeRepo(this.vehicles, {this.claimError});

  List<AssignableVehicle> vehicles;
  final Object? claimError;
  final claimed = <String>[];
  var released = 0;
  final drivers = <VehicleDriver>[];
  final assigned = <Map<String, dynamic>>[];
  final removed = <String>[];
  ({String userId, String? name, String? partnerId})? found;

  void _drive(String? id) => vehicles = [
    for (final v in vehicles)
      AssignableVehicle(
        vehicle: v.vehicle,
        role: v.role,
        status: v.id == id ? AssignableStatus.inUseByYou : (v.inUseByMe ? AssignableStatus.available : v.status),
      ),
  ];

  @override
  Future<List<AssignableVehicle>> assignable() async => vehicles;

  @override
  Future<void> claim(String vehicleId) async {
    if (claimError != null) throw claimError!;
    claimed.add(vehicleId);
    _drive(vehicleId);
  }

  @override
  Future<void> release() async {
    released++;
    _drive(null);
  }

  @override
  Future<List<VehicleDriver>> driversFor(String vehicleId) async => drivers;

  @override
  Future<({String userId, String? name, String? partnerId})?> findByPhone(String phone) async => found;

  @override
  Future<void> assign(Map<String, dynamic> row) async => assigned.add(row);

  @override
  Future<void> setActive(String assignmentId, bool active) async {}

  @override
  Future<void> remove(String assignmentId) async => removed.add(assignmentId);

  @override
  Future<void> endSession(String vehicleId) async {}
}

List<AssignableVehicle> _list({String? driving}) => buildAssignableVehicles(
  owned: [_car('own', 'WXY 1')],
  assignments: [
    {'vehicle_id': 'shared', 'role': 'co-driver'},
  ],
  assignedVehicles: [_car('shared', 'ABC 2')],
  mySessionVehicleId: driving,
);

void main() {
  group('assignment logic', () {
    test('roles, states and order', () {
      final list = buildAssignableVehicles(
        owned: [_car('own', 'B 1'), _car('half', 'A 9', complete: false)],
        assignments: [
          {'vehicle_id': 'shared', 'role': 'co-driver'},
          {'vehicle_id': 'locked', 'role': 'driver'},
          {'vehicle_id': 'review', 'role': 'driver'},
          {'vehicle_id': 'own', 'role': 'driver'}, // owner wins
        ],
        assignedVehicles: [
          _car('shared', 'C 3'),
          _car('locked', 'D 4', status: 'blocked'),
          _car('review', 'E 5', status: 'unapproved'),
          _car('own', 'B 1'), // already owned: not listed twice
        ],
        mySessionVehicleId: 'shared',
      );
      expect([for (final v in list) v.id], ['shared', 'own', 'half', 'locked', 'review']);
      final byId = {for (final v in list) v.id: v};
      expect(byId['shared']!.status, AssignableStatus.inUseByYou);
      expect(byId['shared']!.role, VehicleRole.coDriver);
      expect(byId['own']!.role, VehicleRole.owner);
      expect(byId['own']!.selectable, isTrue);
      expect(byId['half']!.status, AssignableStatus.incomplete);
      expect(byId['half']!.blockedReason, 'Finish setting it up first.');
      expect(byId['locked']!.status, AssignableStatus.contactAdmin);
      expect(byId['review']!.status, AssignableStatus.pendingReview);
      expect(byId['review']!.selectable, isFalse);
    });

    test('a non-owner is told the owner has to finish', () {
      final list = buildAssignableVehicles(
        owned: const [],
        assignments: [
          {'vehicle_id': 'x', 'role': 'co-driver'},
        ],
        assignedVehicles: [_car('x', 'X 1', complete: false)],
        mySessionVehicleId: null,
      );
      expect(list.single.blockedReason, "The owner hasn't finished setting it up.");
    });

    test('roles round-trip and claim errors read plainly', () {
      expect(parseVehicleRole('co-driver'), VehicleRole.coDriver);
      expect(parseVehicleRole('OWNER'), VehicleRole.owner);
      expect(parseVehicleRole(null), VehicleRole.driver);
      expect(vehicleRoleValue(VehicleRole.coDriver), 'co-driver');
      expect(claimVehicleErrorMessage('P0001: vehicle_in_use'), contains('Another driver'));
      expect(claimVehicleErrorMessage('user_busy'), contains('already driving'));
      expect(claimVehicleErrorMessage('not_assigned'), contains('not assigned'));
      expect(claimVehicleErrorMessage('PostgrestException(message: not_authorized, code: 42501)'), contains('Sign in again'));
      expect(claimVehicleErrorMessage('permission denied for function claim_vehicle'), contains('Sign in again'));
      expect(claimVehicleErrorMessage('boom'), contains('Please try again'));
      expect(releaseVehicleErrorMessage('PostgrestException(message: not_authorized, code: 42501)'), contains('Sign in again'));
      expect(releaseVehicleErrorMessage('boom'), "Couldn't hand the vehicle back. Try again.");
    });

    test('phone matching and the assignment row', () {
      expect(samePhone('+60 12-345 6789', '0123456789'), isTrue);
      expect(samePhone('0123456789', '0123456780'), isFalse);
      expect(samePhone('12345', '12345'), isFalse);
      final row = assignmentRow(vehicleId: 'v', userId: 'u', partnerId: null, role: VehicleRole.coDriver, adminId: 'a');
      expect(row['role'], 'co-driver');
      expect(row['is_active'], isTrue);
    });
  });

  group('driver card', () {
    Future<_FakeRepo> pump(WidgetTester tester, _FakeRepo repo) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [vehicleAssignmentRepositoryProvider.overrideWithValue(repo)],
          child: const MaterialApp(home: Scaffold(body: CurrentVehicleCard())),
        ),
      );
      await tester.pumpAndSettle();
      return repo;
    }

    testWidgets('picks a shared vehicle, then hands it back', (tester) async {
      final repo = await pump(tester, _FakeRepo(_list()));
      expect(find.text('No vehicle selected'), findsOneWidget);

      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      expect(find.text('Choose a vehicle'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pick-shared')));
      await tester.pumpAndSettle();
      expect(repo.claimed, ['shared']);
      expect(find.text('ABC 2 · Proton Saga · Co-driver'), findsOneWidget);

      await tester.tap(find.text('Hand back'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Hand back'));
      await tester.pumpAndSettle();
      expect(repo.released, 1);
      expect(find.text('No vehicle selected'), findsOneWidget);
    });

    testWidgets('a car someone else is driving is refused plainly', (tester) async {
      final repo = await pump(tester, _FakeRepo(_list(), claimError: Exception('vehicle_in_use')));
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pick-shared')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Another driver is using this vehicle'), findsOneWidget);
      expect(repo.claimed, isEmpty);
    });

    testWidgets('with the app theme the text keeps its width beside the Select button', (tester) async {
      // The theme makes filled buttons full width (Size.fromHeight); in the
      // tile's trailing slot that squeezed the text to one letter per line.
      await tester.pumpWidget(ProviderScope(
        overrides: [vehicleAssignmentRepositoryProvider.overrideWithValue(_FakeRepo(_list()))],
        child: MaterialApp(
          theme: appTheme(Brightness.light),
          home: const Scaffold(body: Center(child: SizedBox(width: 900, child: CurrentVehicleCard()))),
        ),
      ));
      await tester.pumpAndSettle();
      final text = tester.getSize(find.text('No vehicle selected'));
      expect(text.height, lessThan(40), reason: 'one line, not a column of letters');
      expect(text.width, greaterThan(100));
      expect(tester.getSize(find.byKey(const ValueKey('select-vehicle'))).width, lessThan(300));
    });

    testWidgets('no vehicles points to My vehicles', (tester) async {
      await pump(tester, _FakeRepo(const []));
      expect(find.textContaining('ask an admin to assign you'), findsOneWidget);
    });
  });

  group('admin drivers section', () {
    testWidgets('adds a co-driver by phone and lists who is driving', (tester) async {
      final repo = _FakeRepo(const [])
        ..found = (userId: 'u2', name: 'Siti', partnerId: 'p2')
        ..drivers.addAll(const [
          VehicleDriver(assignmentId: 'a1', userId: 'u1', role: VehicleRole.owner, active: true, name: 'Ali'),
          VehicleDriver(
            assignmentId: 'a2',
            userId: 'u3',
            role: VehicleRole.coDriver,
            active: true,
            name: 'Ravi',
            drivingNow: true,
          ),
        ]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            vehicleAssignmentRepositoryProvider.overrideWithValue(repo),
            currentUserIdProvider.overrideWithValue('admin-1'),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: VehicleDriversSection(vehicleId: 'v1', canEdit: true)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Owner'), findsOneWidget);
      expect(find.text('Co-driver · Driving now'), findsOneWidget);
      expect(find.text('End Ravi session'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('add-driver')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('driver-phone')), '012-345 6789');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      expect(repo.assigned.single['user_id'], 'u2');
      expect(repo.assigned.single['partner_id'], 'p2');
      expect(repo.assigned.single['role'], 'co-driver');
      expect(repo.assigned.single['assigned_by'], 'admin-1');
    });

    testWidgets('an unknown phone number is reported', (tester) async {
      final repo = _FakeRepo(const []);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [vehicleAssignmentRepositoryProvider.overrideWithValue(repo)],
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: VehicleDriversSection(vehicleId: 'v1', canEdit: true)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-driver')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('driver-phone')), '0199999999');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      expect(find.textContaining('No account has that phone number'), findsOneWidget);
      expect(repo.assigned, isEmpty);
    });
  });
}
