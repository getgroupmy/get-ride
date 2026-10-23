// The chosen vehicle on the confirm page: a larger picture whose back is cut
// off by the card's left edge, sized by App Page Settings (home surface,
// "Confirm ride: chosen vehicle"); the rows not chosen keep 72 × 45.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/fare.dart';
import 'package:get_ride/src/core/page_styles.dart';
import 'package:get_ride/src/features/ride/confirm_parts.dart';

void main() {
  test('the size and the cut, kept inside their limits', () {
    final d = chosenPictureBox(170, 30);
    expect(d.width, closeTo(122.4, 0.01));
    expect(d.height, closeTo(76.5, 0.01));
    expect(d.shown, closeTo(85.68, 0.01));
    final whole = chosenPictureBox(100, 0);
    expect((whole.width, whole.height, whole.shown), (72.0, 45.0, 72.0));
    final capped = chosenPictureBox(400, 90);
    expect(capped.width, closeTo(158.4, 0.01));
    expect(capped.shown, closeTo(79.2, 0.01));
  });

  test('the two settings sit on the home surface with the defaults', () {
    final keys = {for (final t in elementTokens[homeSurface]!) t.key: t.fallback};
    expect(keys['chosenPictureSize'], 170);
    expect(keys['chosenPictureHidden'], 30);
  });

  for (final b in Brightness.values) {
    for (final fixed in [true, false]) {
      testWidgets('chosen ${fixed ? 'fixed' : 'bidding'} card: a larger picture, cut by the edge (${b.name})', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: b),
            home: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    ConfirmServiceCard(
                      service: const RideService('Ride', 'Affordable fares', 1, 4),
                      price: 'RM 17',
                      selected: false,
                      onTap: () {},
                    ),
                    ConfirmServiceCard(
                      service: const RideService('Comfort', 'Newer cars', 1, 4),
                      price: 'RM 20',
                      selected: true,
                      fixed: fixed,
                      onTap: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        final box = tester.getSize(find.byKey(const ValueKey('service-picture-chosen-Comfort')));
        final d = chosenPictureBox(170, 30);
        expect(box.width, closeTo(d.shown, 0.01));
        expect(box.height, closeTo(d.height, 0.01));
        expect(find.byKey(const ValueKey('service-picture-chosen-Ride')), findsNothing, reason: 'not chosen: as before');
        // The picture's left reaches past the card's own left: the edge cuts it.
        final card = tester.getRect(find.byKey(const ValueKey('service-Comfort')));
        final pic = tester.getRect(
          find.descendant(of: find.byKey(const ValueKey('service-picture-chosen-Comfort')), matching: find.byType(OverflowBox)),
        );
        expect(pic.left, lessThanOrEqualTo(card.left + 6));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
