import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/auth_utils.dart';
import 'package:get_ride/src/core/commission.dart';
import 'package:get_ride/src/core/fare.dart';
import 'package:get_ride/src/data/models.dart';

void main() {
  group('auth utils (wire-compatible with the Expo app)', () {
    test('normalizeE164 keeps digits and prefixes +', () {
      expect(normalizeE164(' +60 12-345 6789 '), '+60123456789');
      expect(normalizeE164('abc'), '');
    });

    test('composePhone drops the trunk zero', () {
      expect(composePhone('+60', '012 345 6789'), '+60123456789');
      expect(composePhone('+65', '9123 4567'), '+6591234567');
    });

    test('derivePinPassword matches Expo derivePinPassword', () {
      expect(derivePinPassword('123456'), 'teksi-pin-v1-123456');
    });

    test('isValidPin requires exactly six digits', () {
      expect(isValidPin('123456'), isTrue);
      expect(isValidPin('12345'), isFalse);
      expect(isValidPin('12345a'), isFalse);
    });

    test('parsePinLockSeconds reads the server marker', () {
      expect(parsePinLockSeconds('PIN_LOCKED:120'), 120);
      expect(parsePinLockSeconds('error: PIN_LOCKED'), pinLockDefaultSeconds);
      expect(parsePinLockSeconds('Invalid'), isNull);
      expect(pinLockMessage(61), 'Too many incorrect attempts. Try again in 2 minutes.');
      expect(pinLockMessage(30), 'Too many incorrect attempts. Try again in 1 minute.');
    });

    test('parseRateLimitSeconds reads the 0137 marker', () {
      expect(parseRateLimitSeconds('RATE_LIMITED:300'), 300);
      expect(parseRateLimitSeconds('error: RATE_LIMITED'), 60);
      expect(parseRateLimitSeconds('PIN_LOCKED:300'), isNull);
      expect(rateLimitMessage(301), 'Too many tries from this network. Try again in 6 minutes.');
      expect(rateLimitMessage(5), 'Too many tries from this network. Try again in 1 minute.');
    });

    test('otpNextFor: what an SMS code confirms', () {
      expect(otpNextFor('set-pin'), OtpNext.setPin);
      expect(otpNextFor('resync', pin: '123456'), OtpNext.resync);
      expect(otpNextFor('resync'), OtpNext.setPin, reason: 'no PIN to re-sync from');
      expect(otpNextFor('unlock'), OtpNext.unlock);
      expect(otpNextFor('anything'), OtpNext.setPin);
    });

    test('isRegistrationBlocked recognises device-guard errors', () {
      expect(isRegistrationBlocked('DEVICE_LIMIT:3'), isTrue);
      expect(isRegistrationBlocked('EMULATOR_BLOCKED'), isTrue);
      expect(isRegistrationBlocked('network'), isFalse);
    });
  });

  group('calculateFare (TEKSI tariffs, same as Expo utils/maps.ts)', () {
    test('flag fall within the first km', () {
      expect(calculateFare(0.8, 3), 4.0);
      expect(calculateFare(1, 3, multiplier: 1.5), 6.0);
    });

    test('old tariff bills the larger of distance and time units', () {
      // 5 km: 4000 m / 200 = 20 distance units; 10 min → 480 s / 36 = 14 time units.
      expect(calculateFare(5, 10), 4.0 + 20 * 0.35);
      // 2 km in 30 min: 5 distance units vs 25 time units.
      expect(calculateFare(2, 30), 4.0 + 25 * 0.35);
    });

    test('new tariff is linear', () {
      expect(calculateFare(10, 20, tariff: Tariff.newTariff), 4 + 10 + 6);
    });

    test('negative inputs are clamped', () {
      expect(calculateFare(-3, -5), 4.0);
    });
  });

  group('resolveCommissionRate', () {
    const rules = [
      CommissionRule(level: 'master', rate: 0.12),
      CommissionRule(level: 'country', rate: 0.11, country: 'Malaysia'),
      CommissionRule(level: 'state', rate: 0.10, country: 'Malaysia', state: 'Selangor'),
      CommissionRule(level: 'city', rate: 0.09, country: 'Malaysia', state: 'Selangor', city: 'Shah Alam'),
      CommissionRule(level: 'user', rate: 0.05, userId: 'u1'),
      CommissionRule(level: 'city', rate: 0.01, city: 'Ipoh', active: false),
    ];

    test('user override wins', () {
      expect(resolveCommissionRate(rules, userId: 'u1', geo: const Geo(city: 'Shah Alam')), 0.05);
    });

    test('most specific geography wins', () {
      expect(
        resolveCommissionRate(rules, geo: const Geo(country: 'malaysia', state: 'Selangor', city: 'shah alam')),
        0.09,
      );
      expect(resolveCommissionRate(rules, geo: const Geo(country: 'Malaysia', state: 'Johor')), 0.11);
    });

    test('contradicting parents and inactive rules are skipped', () {
      expect(resolveCommissionRate(rules, geo: const Geo(state: 'Perak', city: 'Shah Alam')), 0.12);
      expect(resolveCommissionRate(rules, geo: const Geo(city: 'Ipoh')), 0.12);
    });

    test('falls back to the platform default', () {
      expect(resolveCommissionRate(const []), defaultCommissionRate);
    });
  });

  group('models', () {
    test('RideStatus round-trips the database values', () {
      for (final s in RideStatus.values) {
        expect(RideStatus.parse(s.db), s);
      }
      expect(RideStatus.onTrip.db, 'on_trip');
      expect(RideStatus.parse('unknown'), RideStatus.open);
    });

    test('RideRequest reads numeric columns of either type', () {
      final r = RideRequest({
        'id': 'r1',
        'status': 'on_trip',
        'fare': 12,
        'ride_fare': 15.5,
        'pickup_lat': 3,
        'pickup_lng': 101.5,
        'pickup_name': null,
        'pickup_address': 'Jalan 1',
      });
      expect(r.status, RideStatus.onTrip);
      expect(r.fare, 12.0);
      expect(r.effectiveFare, 15.5);
      expect(r.pickupLat, 3.0);
      expect(r.pickupLabel, 'Jalan 1');
      expect(r.dropLabel, 'Drop-off');
      expect(r.paymentMode, 'Cash');
    });

    test('WalletBalance labels', () {
      final b = WalletBalance.fromRow({'wallet_type': 'get_wallet', 'balance': 10, 'currency': 'MYR'});
      expect(b.label, 'GET.wallet');
      expect(b.balance, 10.0);
    });
  });
}
