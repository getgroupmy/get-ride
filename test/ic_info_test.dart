// Deriving date of birth and gender from a Malaysian NRIC (MyKad) number.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/ic_info.dart';

void main() {
  final now = DateTime(2026, 6, 1);

  test('reads DOB and gender, choosing the 1900s when 2000s would be future', () {
    final a = malaysianIcInfo('880814-07-5678', now: now);
    expect(a.dob, DateTime(1988, 8, 14));
    expect(a.gender, 'Female'); // last digit 8 → even

    final b = malaysianIcInfo('950317-10-5327', now: now);
    expect(b.dob, DateTime(1995, 3, 17));
    expect(b.gender, 'Male'); // last digit 7 → odd
  });

  test('a recent two-digit year stays in the 2000s when not in the future', () {
    final c = malaysianIcInfo('100220-14-5012', now: now); // 2010, in the past
    expect(c.dob, DateTime(2010, 2, 20));
    expect(c.gender, 'Female');
  });

  test('tolerates dashes or their absence', () {
    expect(malaysianIcInfo('880814075678', now: now).dob, DateTime(1988, 8, 14));
  });

  test('a passport or non-12-digit number yields nothing', () {
    expect(malaysianIcInfo('A1234567', now: now).isEmpty, isTrue);
    expect(malaysianIcInfo('', now: now).isEmpty, isTrue);
    expect(malaysianIcInfo(null, now: now).isEmpty, isTrue);
  });

  test('an impossible month or day yields nothing', () {
    expect(malaysianIcInfo('881574-07-5678', now: now).isEmpty, isTrue); // month 15
    expect(malaysianIcInfo('880800-07-5678', now: now).isEmpty, isTrue); // day 00
  });
}
