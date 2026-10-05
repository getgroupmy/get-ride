import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/config.dart';
import 'package:get_ride/src/features/settings/rules_terms_card.dart';

void main() {
  Future<List<Uri>> pumpCard(WidgetTester tester, {bool opens = true}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 1400);
    addTearDown(tester.view.reset);
    final opened = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RulesTermsCard(
            launch: (uri) async {
              opened.add(uri);
              return opens;
            },
          ),
        ),
      ),
    );
    return opened;
  }

  testWidgets('terms and privacy open their pages', (tester) async {
    final opened = await pumpCard(tester);
    await tester.tap(find.byKey(const ValueKey('terms-of-service')));
    await tester.tap(find.byKey(const ValueKey('privacy-policy')));
    await tester.pump();
    expect(opened, [Uri.parse(AppConfig.termsUrl), Uri.parse(AppConfig.privacyUrl)]);
  });

  testWidgets('a link that cannot open says so', (tester) async {
    await pumpCard(tester, opens: false);
    await tester.tap(find.byKey(const ValueKey('terms-of-service')));
    await tester.pump();
    expect(find.text('Could not open ${AppConfig.termsUrl}'), findsOneWidget);
  });

  testWidgets('licenses lists the packages', (tester) async {
    await pumpCard(tester);
    await tester.tap(find.byKey(const ValueKey('licenses')));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
  });
}
