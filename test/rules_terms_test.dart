import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/config.dart';
import 'package:get_ride/src/features/settings/rules_terms_card.dart';

void main() {
  Future<List<(String, String?)>> pumpCard(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 1400);
    addTearDown(tester.view.reset);
    final opened = <(String, String?)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RulesTermsCard(
            open: (context, url, {title}) async => opened.add((url, title)),
          ),
        ),
      ),
    );
    return opened;
  }

  testWidgets('terms and privacy open their pages in the app', (tester) async {
    final opened = await pumpCard(tester);
    await tester.tap(find.byKey(const ValueKey('terms-of-service')));
    await tester.tap(find.byKey(const ValueKey('privacy-policy')));
    await tester.pump();
    expect(opened, [(AppConfig.termsUrl, 'Terms and conditions'), (AppConfig.privacyUrl, 'Privacy Policy')]);
  });

  testWidgets('licenses lists the packages', (tester) async {
    await pumpCard(tester);
    await tester.tap(find.byKey(const ValueKey('licenses')));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
  });
}
