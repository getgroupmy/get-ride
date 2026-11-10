// The pure decision logic behind recording a rider's current country
// (migration 0400): normalisation, the country-scale move gate, and the
// send-if-changed rule.
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:get_ride/src/data/current_country_reporter.dart';

void main() {
  group('normalizeReportedCountry', () {
    test('trims, collapses whitespace, and nulls empty', () {
      expect(normalizeReportedCountry('  Malaysia '), 'Malaysia');
      expect(normalizeReportedCountry('Papua  New   Guinea'), 'Papua New Guinea');
      expect(normalizeReportedCountry(''), isNull);
      expect(normalizeReportedCountry('   '), isNull);
      expect(normalizeReportedCountry(null), isNull);
    });
    test('caps overly long values', () {
      expect(normalizeReportedCountry('x' * 200)!.length, 80);
    });
  });

  group('movedFar', () {
    test('true on the first fix (no previous point)', () {
      expect(movedFar(null, const LatLng(3.1, 101.6)), isTrue);
    });
    test('false for ordinary movement within ~11 km', () {
      expect(movedFar(const LatLng(3.10, 101.60), const LatLng(3.12, 101.61)), isFalse);
    });
    test('true for a country-scale move (KL → Singapore)', () {
      expect(movedFar(const LatLng(3.14, 101.69), const LatLng(1.35, 103.82)), isTrue);
    });
  });

  group('shouldSend', () {
    test('sends a new non-null country', () {
      expect(shouldSend(null, 'Malaysia'), isTrue);
      expect(shouldSend('Malaysia', 'Singapore'), isTrue);
    });
    test('skips an unchanged or null country', () {
      expect(shouldSend('Malaysia', 'Malaysia'), isFalse);
      expect(shouldSend('Malaysia', null), isFalse);
      expect(shouldSend(null, null), isFalse);
    });
  });
}
