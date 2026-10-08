// Pages loading their data show a shimmering skeleton of rows (skeletonizer)
// rather than a spinner, in the app's light or dark.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skeletonizer/skeletonizer.dart';

import 'package:get_ride/src/widgets/common.dart';
import 'package:get_ride/src/widgets/loading_skeleton.dart';

void main() {
  testWidgets('AsyncView loading shows the skeleton, then the data', (tester) async {
    Widget view(AsyncValue<String> v) => MaterialApp(
      home: Scaffold(
        body: AsyncView<String>(value: v, data: (s) => Text(s)),
      ),
    );
    await tester.pumpWidget(view(const AsyncLoading()));
    expect(find.byKey(const ValueKey('loading-skeleton')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(view(const AsyncData('Loaded')));
    expect(find.byKey(const ValueKey('loading-skeleton')), findsNothing);
    expect(find.text('Loaded'), findsOneWidget);
  });

  for (final b in Brightness.values) {
    testWidgets('it shimmers in the app theme, not the platform\'s ($b)', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = b == Brightness.dark ? Brightness.light : Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: b),
          home: const Scaffold(body: LoadingSkeleton()),
        ),
      );
      final config = SkeletonizerConfig.of(tester.element(find.byKey(const ValueKey('loading-skeleton'))));
      expect(config.brightness, b);
    });
  }

  testWidgets('it fits the space it is given, and lists its rows when unbounded', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SizedBox(height: 200, child: LoadingSkeleton(rows: 6))),
      ),
    );
    expect(find.byType(ListTile), findsNWidgets(2));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ListView(children: const [LoadingSkeleton(rows: 3)])),
      ),
    );
    expect(find.byType(ListTile), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });
}
