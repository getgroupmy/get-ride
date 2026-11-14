import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/launch_destination.dart';

void main() {
  group('isFoldedCoverSize', () {
    test('iPhone Duo folded cover (466x678, inset 84) is the cover', () {
      expect(isFoldedCoverSize(466, 678, 84, web: false), isTrue);
    });

    test('an ordinary phone of the same size (no reserved-region inset) is not', () {
      expect(isFoldedCoverSize(466, 678, 0, web: false), isFalse);
      expect(isFoldedCoverSize(390, 844, 0, web: false), isFalse);
    });

    test('the unfolded inner (large, shortest >= 600) is not the cover even with the inset', () {
      // Inner portrait 669x951 carries the same 84 inset but is a large screen.
      expect(isFoldedCoverSize(669, 951, 84, web: false), isFalse);
    });

    test('a tablet is not the cover', () {
      expect(isFoldedCoverSize(834, 1112, 0, web: false), isFalse);
    });

    test('landscape is not the cover (it is caught portrait-locked)', () {
      // The cover in its transient landscape (678x466) is width > height.
      expect(isFoldedCoverSize(678, 466, 84, web: false), isFalse);
    });

    test('the inset must reach the foldable threshold', () {
      expect(isFoldedCoverSize(466, 678, foldedCoverInsetMin - 1, web: false), isFalse);
      expect(isFoldedCoverSize(466, 678, foldedCoverInsetMin, web: false), isTrue);
    });
  });

  group('mapButtonsRightInset', () {
    test('the iPhone Duo reserved inset is dropped so the buttons hug the edge', () {
      // Folded cover (small portrait) and unfolded inner (tablet-size) both
      // carry the ~84 reserved inset.
      expect(mapButtonsRightInset(466, 678, 84, web: false), 0);
      expect(mapButtonsRightInset(951, 669, 84, web: false), 0); // inner, landscape
      expect(mapButtonsRightInset(669, 951, 84, web: false), 0); // inner, portrait
    });

    test('a plain phone on its side keeps its real notch inset (never hugged)', () {
      // iPhone 15 landscape 852x393, notch 59: the buttons must still clear it.
      expect(mapButtonsRightInset(852, 393, 59, web: false), 59);
      expect(mapButtonsHugRightEdge(852, 393, 59, web: false), isFalse);
    });

    test('a plain portrait phone / tablet keeps its (near-zero) real inset', () {
      expect(mapButtonsRightInset(390, 844, 0, web: false), 0);
      expect(mapButtonsRightInset(390, 844, 8, web: false), 8); // below the threshold
      expect(mapButtonsRightInset(834, 1112, 0, web: false), 0); // iPad
    });
  });
}
