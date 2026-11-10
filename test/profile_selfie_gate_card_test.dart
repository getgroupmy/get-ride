// Admin → App Settings → Live-selfie verification card (migration 0401): shows
// the Master default and per-country rules, with Add / Edit when editable.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/admin/screens/profile_selfie_gate_card.dart';

Future<void> _pump(WidgetTester tester, Map<String, bool> config, {required bool canEdit}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        profileSelfieGateConfigProvider.overrideWith((ref) async => config),
      ],
      child: MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(body: SingleChildScrollView(child: ProfileSelfieGateCard(canEdit: canEdit))),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists Master and a country rule, with Add when editable', (tester) async {
    await _pump(tester, {'master': false, 'Malaysia': true}, canEdit: true);

    expect(find.byKey(const ValueKey('profile-selfie-gate-master')), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-selfie-gate-Malaysia')), findsOneWidget);
    expect(find.text('On — a verified live selfie is required'), findsOneWidget);
    expect(find.text('Off — no live selfie required'), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-selfie-gate-add')), findsOneWidget);
  });

  testWidgets('read-only: no Add button and no edit', (tester) async {
    await _pump(tester, {'master': true}, canEdit: false);
    expect(find.byKey(const ValueKey('profile-selfie-gate-master')), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-selfie-gate-add')), findsNothing);
  });

  testWidgets('edit dialog: the require switch and Save', (tester) async {
    await _pump(tester, {'master': false}, canEdit: true);
    await tester.tap(find.byKey(const ValueKey('profile-selfie-gate-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('profile-selfie-gate-country')), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-selfie-gate-require')), findsOneWidget);
    // Save is disabled until a country is typed.
    await tester.enterText(find.byKey(const ValueKey('profile-selfie-gate-country')), 'Singapore');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('profile-selfie-gate-save')), findsOneWidget);
  });
}
