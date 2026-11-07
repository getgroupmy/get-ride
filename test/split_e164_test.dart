import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/dial_countries.dart';

void main() {
  group('splitE164', () {
    test('Malaysian number → +60 and the local part', () {
      final (country, local) = splitE164('+601123456789');
      expect(country.dialCode, '+60');
      expect(local, '1123456789');
    });

    test('longest dial code wins (Brunei +673 over a shorter prefix)', () {
      final (country, local) = splitE164('+6731234567');
      expect(country.dialCode, '+673');
      expect(local, '1234567');
    });

    test('tolerates spaces and dashes in the input', () {
      final (country, local) = splitE164('+60 11-2345 6789');
      expect(country.dialCode, '+60');
      expect(local, '1123456789');
    });

    test('unknown dial code still round-trips the digits', () {
      final (country, local) = splitE164('+9991234567');
      expect(country.dialCode, '+');
      expect(local, '9991234567');
    });
  });
}
