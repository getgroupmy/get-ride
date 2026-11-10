// Owner-side driver consent (migrations 0377 + 0391): a vehicle owner sees the
// drivers added to their car and approves / declines each one.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/vehicle_access_repository.dart';
import 'package:get_ride/src/features/partner/vehicle_access_requests_screen.dart';
import 'package:get_ride/src/providers.dart' show currentUserIdProvider;
import 'package:supabase_flutter/supabase_flutter.dart';

final _items = [
  const OwnerDriverRequest(
    assignmentId: 'a1', vehicleId: 'v1', plate: 'WVX 1234', vehicleLabel: 'Perodua Myvi',
    driverId: 'd1', driverName: 'Aisyah Rahman'),
];

class _FakeRepo extends VehicleAccessRepository {
  _FakeRepo()
      : super(SupabaseClient('http://localhost', 'test-anon-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false)));

  final List<(String, bool)> responded = [];

  @override
  Future<String> respond(String assignmentId, {required bool approve}) async {
    responded.add((assignmentId, approve));
    return approve ? 'approved' : 'declined';
  }
}

Future<_FakeRepo> _pump(WidgetTester tester, {List<OwnerDriverRequest>? items}) async {
  tester.view.physicalSize = const Size(1000, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repo = _FakeRepo();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentUserIdProvider.overrideWith((ref) => 'me'),
        vehicleAccessRepositoryProvider.overrideWithValue(repo),
        ownerDriverRequestsProvider.overrideWith((ref) async => items ?? _items),
      ],
      child: MaterialApp(theme: appTheme(Brightness.light), home: const VehicleAccessRequestsScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('lists a driver request with the plate and both actions', (tester) async {
    await _pump(tester);
    expect(find.text('Aisyah Rahman'), findsOneWidget);
    expect(find.textContaining('WVX 1234'), findsOneWidget);
    expect(find.byKey(const ValueKey('driver-request-approve-a1')), findsOneWidget);
    expect(find.byKey(const ValueKey('driver-request-decline-a1')), findsOneWidget);
  });

  testWidgets('Approve calls respond(approve: true)', (tester) async {
    final repo = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('driver-request-approve-a1')));
    await tester.pumpAndSettle();
    expect(repo.responded, [('a1', true)]);
  });

  testWidgets('Decline calls respond(approve: false)', (tester) async {
    final repo = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('driver-request-decline-a1')));
    await tester.pumpAndSettle();
    expect(repo.responded, [('a1', false)]);
  });

  testWidgets('an empty list shows the empty state', (tester) async {
    await _pump(tester, items: const []);
    expect(find.text('No driver requests'), findsOneWidget);
  });
}
