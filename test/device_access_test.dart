import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/device_access.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/vehicle_assignment_repository.dart';
import 'package:get_ride/src/core/vehicle_assignment.dart';
import 'package:get_ride/src/features/auth/phone_screen.dart';
import 'package:get_ride/src/features/partner/partner_screen.dart';
import 'package:get_ride/src/providers.dart';

class _NoTrip implements RideRepository {
  @override
  Future<RideRequest?> ongoingForPartner() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<void> setUpView(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 1400);
    addTearDown(tester.view.reset);
  }

  testWidgets('a blacklisted device cannot continue to sign-in', (tester) async {
    await setUpView(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [deviceBlockedProvider.overrideWith((ref) async => true)],
        child: const MaterialApp(home: PhoneScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('device-blocked')), findsOneWidget);
    final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue'));
    expect(button.onPressed, isNull);
  });

  testWidgets('other devices see no banner', (tester) async {
    await setUpView(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [deviceBlockedProvider.overrideWith((ref) async => false)],
        child: const MaterialApp(home: PhoneScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('device-blocked')), findsNothing);
    final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue'));
    expect(button.onPressed, isNotNull);
  });

  testWidgets('a blacklisted partner cannot go online', (tester) async {
    await setUpView(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceBlockedProvider.overrideWith((ref) async => true),
          rideRepositoryProvider.overrideWithValue(_NoTrip()),
          partnerProvider.overrideWith((ref) async => Partner({'id': 'p1', 'status': 'approved'})),
          openRequestsProvider.overrideWith((ref) => const Stream<List<RideRequest>>.empty()),
          assignableVehiclesProvider.overrideWith((ref) async => const <AssignableVehicle>[]),
        ],
        child: const MaterialApp(home: PartnerScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('You are offline'));
    await tester.pumpAndSettle();
    expect(find.text('You are offline'), findsOneWidget);
    expect(find.textContaining(serviceNotAvailable), findsOneWidget);
  });
}
