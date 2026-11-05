import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/rider_id_gate_card.dart';
import 'package:get_ride/src/core/rider_id_gate.dart';
import 'package:get_ride/src/data/rider_id_gate_repository.dart';

void main() {
  testWidgets('the card lists the master row and each country rule', (tester) async {
    const config = RiderIdGateConfig({
      'master': RiderIdGateRule(require: true, idType: 'national', nthBooking: 1),
      'Malaysia': RiderIdGateRule(require: true, idType: 'passport', nthBooking: 2, allowPhoto: false),
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [riderIdGateConfigProvider.overrideWith((ref) async => config)],
      child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: RiderIdGateCard(canEdit: true)))),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('rider-id-gate-master')), findsOneWidget);
    expect(find.byKey(const ValueKey('rider-id-gate-Malaysia')), findsOneWidget);
    expect(find.byKey(const ValueKey('rider-id-gate-add')), findsOneWidget);
    // The country summary reflects its rule.
    expect(find.textContaining('Passport'), findsOneWidget);
    expect(find.textContaining('live only'), findsOneWidget);
  });

  testWidgets('read-only hides the edit and add controls', (tester) async {
    const config = RiderIdGateConfig({'master': RiderIdGateRule()});
    await tester.pumpWidget(ProviderScope(
      overrides: [riderIdGateConfigProvider.overrideWith((ref) async => config)],
      child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: RiderIdGateCard(canEdit: false)))),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('rider-id-gate-master')), findsOneWidget);
    expect(find.byKey(const ValueKey('rider-id-gate-add')), findsNothing);
    // Master default is off.
    expect(find.textContaining('book without verifying'), findsOneWidget);
  });
}
