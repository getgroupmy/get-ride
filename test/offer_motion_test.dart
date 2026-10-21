import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/widgets/offer_motion.dart';

/// Files that show incoming offers without "offer" in their name or class
/// names, scanned all the same.
const _offerHosts = {
  'lib/src/features/partner/partner_screen.dart',
  'lib/src/features/ride/ride_tracking_screen.dart',
};

/// Slides and tilts an offer file may keep, with why. The count is how many
/// matches there are in that file.
const _allowed = <String, (int, String)>{
  'lib/src/features/partner/partner_screen.dart': (
    2,
    'the phone\'s new-request bottom sheet rises from the bottom (a sheet, not an offer card); '
        'the desktop request card uses OfferMotionSwitcher',
  ),
};

/// What a card's own slide or tilt looks like in the code.
final _ownMotion = [
  RegExp(r'\bSlideTransition\b'),
  RegExp(r'Tween<Offset>'),
  RegExp(r'Tween\(\s*begin:\s*(const\s+)?Offset'),
  RegExp(r'\bAnimatedSlide\b'),
  RegExp(r'\bFractionalTranslation\b'),
  RegExp(r'\bTransform\.rotate\b'),
  RegExp(r'\bRotationTransition\b'),
];

final _offerClass = RegExp(r'class\s+_?\w*Offer\w*');

void main() {
  group('the locked motion', () {
    test('constants', () {
      expect(offerMotionInDuration, const Duration(milliseconds: 460));
      expect(offerMotionOutDuration, const Duration(milliseconds: 340));
      expect(offerMotionTiltDegrees, -6.0);
      expect(offerMotionTilt, closeTo(-6 * math.pi / 180, 1e-12));
      // In from the right edge (positive), out past the left (negative).
      expect(offerMotionInFrom, 1.0);
      expect(offerMotionOutTo, lessThan(-1.0));
      expect(offerMotionInCurve, const Cubic(0.2, 1.4, 0.4, 1.0));
      expect(offerMotionOutCurve, Curves.easeInCubic);
    });

    test('in: right to left, past its place a little, then at rest', () {
      final start = offerMotionIn(0);
      expect(start.dx, offerMotionInFrom);
      expect(start.opacity, 0);
      expect(start.angle, 0, reason: 'a new card comes in level');
      final dxs = [for (var i = 0; i <= 100; i++) offerMotionIn(i / 100).dx];
      expect(dxs.reduce(math.min), lessThan(0), reason: 'the overshoot carries it a little left of its place');
      expect(dxs.reduce(math.min), greaterThan(-0.15), reason: 'a small overshoot');
      expect(offerMotionIn(1), OfferMotionFrame.rest);
    });

    test('out: to the left, tilting to -6 degrees and fading', () {
      expect(offerMotionOut(0), OfferMotionFrame.rest);
      final end = offerMotionOut(1);
      expect(end.dx, offerMotionOutTo);
      expect(end.angle, closeTo(offerMotionTilt, 1e-12));
      expect(end.opacity, 0);
      final mid = offerMotionOut(0.5);
      expect(mid.dx, lessThan(0));
      expect(mid.angle, lessThan(0));
      expect(mid.opacity, inExclusiveRange(0, 1));
      // A swiped card goes on from where the finger let go.
      expect(offerMotionOut(0, from: -0.3).dx, -0.3);
      expect(offerMotionOut(1, from: -0.3).dx, offerMotionOutTo);
    });

    test('reduced motion: no slide and no tilt, only a fade', () {
      for (final t in [0.0, 0.3, 0.7, 1.0]) {
        final i = offerMotionIn(t, reduceMotion: true), o = offerMotionOut(t, reduceMotion: true);
        expect((i.dx, i.angle, o.dx, o.angle), (0.0, 0.0, 0.0, 0.0), reason: 't=$t');
      }
      expect(offerMotionOut(1, reduceMotion: true).opacity, 0);
    });

    testWidgets('OfferMotionList slides a new card in and a gone one out', (tester) async {
      Widget list(List<String> ids) => MaterialApp(
        home: Scaffold(
          body: OfferMotionList(
            animateFirst: false,
            children: [for (final id in ids) SizedBox(key: ValueKey(id), height: 40, child: Text(id))],
          ),
        ),
      );
      await tester.pumpWidget(list(['a']));
      await tester.pumpWidget(list(['a', 'b']));
      await tester.pump(const Duration(milliseconds: 40));
      final t = tester.widget<FractionalTranslation>(
        find.ancestor(of: find.text('b'), matching: find.byType(FractionalTranslation)).first,
      );
      expect(t.translation.dx, greaterThan(0), reason: 'b comes from the right');
      await tester.pumpAndSettle();
      await tester.pumpWidget(list(['b']));
      await tester.pump(const Duration(milliseconds: 170));
      expect(find.text('a'), findsOneWidget, reason: 'a is still sliding out');
      final out = tester.widget<FractionalTranslation>(
        find.ancestor(of: find.text('a'), matching: find.byType(FractionalTranslation)).first,
      );
      expect(out.translation.dx, lessThan(0), reason: 'a leaves to the left');
      await tester.pumpAndSettle();
      expect(find.text('a'), findsNothing);
    });
  });

  test('no offer card animates on its own', () {
    final found = <String, int>{};
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = f.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart') || path.endsWith('lib/src/widgets/offer_motion.dart')) continue;
      final src = f.readAsStringSync();
      final name = path.split('/').last.toLowerCase();
      if (!name.contains('offer') && !_offerClass.hasMatch(src) && !_offerHosts.contains(path)) continue;
      final n = _ownMotion.fold<int>(0, (a, r) => a + r.allMatches(src).length);
      if (n > 0) found[path] = n;
    }
    final wrong = [
      for (final e in found.entries)
        if (_allowed[e.key]?.$1 != e.value) '${e.key}: ${e.value} (allowed ${_allowed[e.key]?.$1 ?? 0})',
    ];
    expect(wrong, isEmpty,
        reason: 'Offer cards move with lib/src/widgets/offer_motion.dart (OfferMotion, OfferMotionList, '
            'OfferMotionSwitcher, offerMotionIn/Out). Use it, or add the file to _allowed with the reason.');
    for (final k in _allowed.keys) {
      expect(found.containsKey(k), isTrue, reason: '$k no longer needs its allow-list entry');
    }
  });
}
