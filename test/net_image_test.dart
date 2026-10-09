// Every network picture: a skeleton while it loads, the base icon only if it
// fails; and the vehicle bar is a skeleton until the service catalogue lands.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/features/ride/home_parts.dart';
import 'package:get_ride/src/widgets/net_image.dart';

const _base = Icon(Icons.directions_car, key: ValueKey('base-icon'));

void main() {
  testWidgets('a picture still loading is a skeleton, not the base icon', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: NetImage('https://cdn.example/van.png', width: 56, height: 26, fallback: _base)),
      ),
    );
    expect(find.byKey(const ValueKey('image-bone')), findsOneWidget);
    expect(find.byKey(const ValueKey('base-icon')), findsNothing);
  });

  testWidgets('the base icon shows once the picture fails to load', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: NetImage('https://cdn.example/van.png', width: 56, height: 26, fallback: _base)),
      ),
    );
    // The test binding answers every HTTP request with a 400.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(find.byKey(const ValueKey('base-icon')), findsOneWidget);
    expect(find.byKey(const ValueKey('image-bone')), findsNothing);
  });

  testWidgets('an avatar with no picture is its icon at once; with one, a skeleton first', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Column(
          children: [
            NetAvatar(url: null, fallback: Icon(Icons.person, key: ValueKey('no-photo'))),
            NetAvatar(
              url: 'https://cdn.example/me.png',
              fallback: Icon(Icons.person, key: ValueKey('photo-icon')),
            ),
          ],
        ),
      ),
    );
    expect(find.byKey(const ValueKey('no-photo')), findsOneWidget);
    expect(find.byKey(const ValueKey('photo-icon')), findsNothing);
    expect(find.byKey(const ValueKey('image-bone')), findsOneWidget);
  });

  testWidgets('the vehicle bar skeleton has no names or car icons to change', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: VehicleTypeBarSkeleton())));
    expect(find.byKey(const ValueKey('vehicle-type-bar-skeleton')), findsOneWidget);
    expect(find.byIcon(Icons.directions_car), findsNothing);
    expect(find.text('Teksi'), findsNothing);
  });
}
