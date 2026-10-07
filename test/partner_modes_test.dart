import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/partner_doc_check.dart';
import 'package:get_ride/src/core/partner_modes.dart';
import 'package:get_ride/src/core/vehicle_assignment.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/partner_doc_check.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/vehicle_assignment_repository.dart';
import 'package:get_ride/src/features/partner/partner_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';

class _NoTrip implements RideRepository {
  @override
  Future<RideRequest?> ongoingForPartner() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PartnerTypeEntry _e(Map<String, dynamic> v) => (id: '${v['name']}', values: v);

void main() {
  test('vehicle required: the admin flag wins, driving modes default on', () {
    final entries = [
      _e({'name': 'TEKSI', 'vehicleRequired': false}),
      _e({'name': 'Courier', 'vehicleRequired': true}),
      _e({'name': 'Tour guide'}),
    ];
    expect(vehicleRequiredFor('teksi', entries), isFalse);
    expect(vehicleRequiredFor('Courier', entries), isTrue);
    expect(vehicleRequiredFor('Tour guide', entries), isFalse);
    expect(vehicleRequiredFor('e-Hailing', entries), isTrue); // no entry: a driving mode
    expect(vehicleRequiredFor('pHailing', const []), isTrue);
  });

  test('mode options: switched off dropped, admin order, description and icon', () {
    final entries = [
      _e({'name': 'eHailing', 'displayPriority': 2, 'shortInfo': 'Ride requests'}),
      _e({'name': 'TEKSI', 'displayPriority': 1, 'description': 'Metered taxi', 'iconUrl': 'https://x/t.png'}),
      _e({'name': 'Courier', 'enabled': false}),
    ];
    final modes = partnerModeOptions(['eHailing', 'Courier', 'TEKSI', 'teksi', 'Mystery'], entries);
    expect(modes.map((m) => m.name), ['TEKSI', 'eHailing', 'Mystery']);
    expect(modes.first.description, 'Metered taxi');
    expect(modes.first.iconUrl, 'https://x/t.png');
    expect(modes.first.isTeksi, isTrue);
    expect(modes[1].description, 'Ride requests');
  });

  testWidgets('going online without a vehicle asks for one when the mode needs it', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 1400);
    addTearDown(tester.view.reset);
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const PartnerScreen()),
        GoRoute(
          path: '/drive/vehicles/new',
          builder: (_, _) => const Scaffold(body: Text('add vehicle')),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          partnerProvider.overrideWith(
            (ref) async => Partner({
              'id': 'p1',
              'status': 'approved',
              'name': 'Ali',
              'partner_types': ['eHailing'],
            }),
          ),
          rideRepositoryProvider.overrideWithValue(_NoTrip()),
          openRequestsProvider.overrideWith((ref) => const Stream<List<RideRequest>>.empty()),
          assignableVehiclesProvider.overrideWith((ref) async => const <AssignableVehicle>[]),
          partnerTypeEntriesProvider.overrideWith(
            (ref) async => [
              _e({'name': 'eHailing', 'vehicleRequired': true}),
            ],
          ),
          partnerDocCheckProvider.overrideWithValue((partner, {required teksi}) async => const <DocIssue>[]),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('You are offline'));
    await tester.pump();
    await _pumpOpen(tester);
    expect(find.byKey(const ValueKey('vehicle-required')), findsOneWidget);
    await tester.tap(find.text('Add a vehicle'));
    await tester.pumpAndSettle();
    expect(find.text('add vehicle'), findsOneWidget);
  });
}

/// Lets a dialog or sheet open over a busy control: the control's spinner
/// keeps turning until the dialog is answered, so pumpAndSettle can't settle.
Future<void> _pumpOpen(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
