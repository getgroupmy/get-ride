import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/drop_change.dart';

void main() {
  group('DropChangeSettings', () {
    test('defaults', () {
      const s = DropChangeSettings.standard;
      expect(s.allow, isTrue);
      expect(s.autoApproveCheaper, isTrue);
      expect(s.autoApproveRm, 3);
      expect(s.autoApprovePct, 15);
      expect(s.responseWindowSec, 30);
      expect(s.maxChangesPerRide, 2);
      expect(s.responseWindow, const Duration(seconds: 30));
    });

    test('clamps and round-trips', () {
      final s = DropChangeSettings.fromJson({
        'allow': false,
        'autoApproveCheaper': false,
        'autoApproveRm': 999,
        'autoApprovePct': -5,
        'responseWindowSec': 5,
        'maxChangesPerRide': 50,
      });
      expect(s.allow, isFalse);
      expect(s.autoApproveCheaper, isFalse);
      expect(s.autoApproveRm, 50); // max
      expect(s.autoApprovePct, 0); // min
      expect(s.responseWindowSec, 10); // min
      expect(s.maxChangesPerRide, 10); // max
      expect(DropChangeSettings.fromJson(s.toJson()), s);
    });

    test('a non-map is the standard settings', () {
      expect(DropChangeSettings.fromJson(null), DropChangeSettings.standard);
      expect(DropChangeSettings.fromJson('x'), DropChangeSettings.standard);
    });
  });

  group('dropChangeKind', () {
    const rules = DropChangeSettings(autoApproveRm: 3, autoApprovePct: 15);

    test('cheaper applies instantly', () {
      expect(dropChangeKind(oldFare: 18, newFare: 15, rules: rules), DropChangeKind.instant);
      expect(dropChangeKind(oldFare: 18, newFare: 18, rules: rules), DropChangeKind.instant);
    });

    test('a small increase within RM applies instantly', () {
      // +RM2 ≤ max(RM3, 15% of 18 = 2.70) = RM3.
      expect(dropChangeKind(oldFare: 18, newFare: 20, rules: rules), DropChangeKind.instant);
    });

    test('a bigger increase needs the driver', () {
      // +RM6 > RM3 and > 15% (2.70).
      expect(dropChangeKind(oldFare: 18, newFare: 24, rules: rules), DropChangeKind.needsDriver);
    });

    test('percent threshold wins when it is larger', () {
      // Old RM100, 15% = RM15 > RM3; +RM10 is within.
      expect(dropChangeKind(oldFare: 100, newFare: 110, rules: rules), DropChangeKind.instant);
      expect(dropChangeKind(oldFare: 100, newFare: 120, rules: rules), DropChangeKind.needsDriver);
    });

    test('cheaper needs the driver when auto-approve-cheaper is off', () {
      const strict = DropChangeSettings(autoApproveCheaper: false);
      expect(dropChangeKind(oldFare: 18, newFare: 15, rules: strict), DropChangeKind.needsDriver);
    });
  });
}
