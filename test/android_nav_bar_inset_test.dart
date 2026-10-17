import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/widgets/android_nav_bar_inset.dart';

void main() {
  Future<double> buttonBottom(WidgetTester tester, TargetPlatform platform, {bool dark = false}) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    // Android's three buttons, drawn over the app (edge to edge).
    tester.view.padding = const FakeViewPadding(bottom: 48);
    tester.view.viewPadding = const FakeViewPadding(bottom: 48);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform, brightness: dark ? Brightness.dark : Brightness.light),
        builder: (_, child) => AndroidNavBarInset(child: child!),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: FilledButton(onPressed: () {}, child: const Text('Cancel ride')),
          ),
        ),
      ),
    );
    return tester.getBottomLeft(find.text('Cancel ride')).dy;
  }

  for (final dark in [false, true]) {
    testWidgets('Android: the bottom button sits above the navigation buttons (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      expect(await buttonBottom(tester, TargetPlatform.android, dark: dark), lessThanOrEqualTo(800 - 48));
    });
  }

  testWidgets('iPhone: left to each page, as before', (tester) async {
    expect(await buttonBottom(tester, TargetPlatform.iOS), greaterThan(800 - 48));
  });
}
