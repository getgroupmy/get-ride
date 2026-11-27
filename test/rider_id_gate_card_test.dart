import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/rider_id_gate_card.dart';
import 'package:get_ride/src/core/rider_id_gate.dart';
import 'package:get_ride/src/data/rider_id_gate_repository.dart';

void main() {
  Widget host({required RiderIdGateConfig id, required Map<String, bool> selfie, bool canEdit = true}) => ProviderScope(
        overrides: [
          riderIdGateConfigProvider.overrideWith((ref) async => id),
          profileSelfieGateConfigProvider.overrideWith((ref) async => selfie),
        ],
        child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: RiderIdGateCard(canEdit: canEdit)))),
      );

  testWidgets('each country shows its combined method, from both gates', (tester) async {
    const id = RiderIdGateConfig({
      'master': RiderIdGateRule(),
      'Malaysia': RiderIdGateRule(require: true, idType: 'passport', nthBooking: 2),
    });
    await tester.pumpWidget(host(id: id, selfie: const {'Malaysia': true, 'Thailand': true}));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('rider-id-gate-master')), findsOneWidget);
    expect(find.byKey(const ValueKey('rider-id-gate-Malaysia')), findsOneWidget);
    // A country present only in the live-selfie config still gets a row.
    expect(find.byKey(const ValueKey('rider-id-gate-Thailand')), findsOneWidget);
    expect(find.byKey(const ValueKey('rider-id-gate-add')), findsOneWidget);

    // Malaysia: eKYC + live selfie (Both).
    expect(find.textContaining('eKYC: Passport · before booking #2'), findsOneWidget);
    // Both Malaysia (Both) and Thailand (Live selfie) mention the selfie.
    expect(find.textContaining('live selfie on record'), findsNWidgets(2));
    // Master: nothing required.
    expect(find.textContaining('book without verifying'), findsOneWidget);
  });

  testWidgets('read-only hides the edit and add controls', (tester) async {
    const id = RiderIdGateConfig({'master': RiderIdGateRule()});
    await tester.pumpWidget(host(id: id, selfie: const {}, canEdit: false));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('rider-id-gate-master')), findsOneWidget);
    expect(find.byKey(const ValueKey('rider-id-gate-add')), findsNothing);
    expect(find.byType(IconButton), findsNothing);
    expect(find.textContaining('book without verifying'), findsOneWidget);
  });
}
