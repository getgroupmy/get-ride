// Booking tariffs by place: which card prices a pickup, and what it charges.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/commission.dart' show Geo;
import 'package:get_ride/src/core/fare.dart';
import 'package:get_ride/src/core/fare_tariff.dart';

const _master = FareTariff(level: 'master', currency: 'MYR', baseFare: 4, perKm: 1, perMinute: 0.3);
const _sg = FareTariff(
  level: 'country',
  country: 'Singapore',
  currency: 'SGD',
  baseFare: 3.9,
  perKm: 0.7,
  perMinute: 0.2,
);
const _penang = FareTariff(
  level: 'state',
  country: 'Malaysia',
  state: 'Penang',
  currency: 'MYR',
  baseFare: 3,
  perKm: 0.9,
);
const _georgetown = FareTariff(
  level: 'suburb',
  country: 'Malaysia',
  state: 'Penang',
  city: 'George Town',
  suburb: 'Georgetown',
  currency: 'MYR',
  baseFare: 5,
  perKm: 1.2,
);
const _kl = FareTariff(
  level: 'city',
  country: 'Malaysia',
  state: 'Kuala Lumpur',
  city: 'Kuala Lumpur',
  baseFare: 4.5,
  perKm: 1.1,
);

const _all = [_master, _sg, _penang, _georgetown, _kl];

void main() {
  group('which card prices the pickup', () {
    test('the narrowest card that matches wins', () {
      const gt = Geo(country: 'Malaysia', state: 'Penang', city: 'George Town', suburb: 'Georgetown');
      expect(resolveFareTariff(_all, gt), _georgetown);
      expect(resolveFareTariff(_all, const Geo(country: 'Malaysia', state: 'Penang', city: 'Butterworth')), _penang);
      expect(resolveFareTariff(_all, const Geo(country: 'malaysia', state: 'kuala lumpur', city: 'KUALA LUMPUR')), _kl);
      expect(resolveFareTariff(_all, const Geo(country: 'Singapore', city: 'Singapore')), _sg);
      expect(resolveFareTariff(_all, const Geo(country: 'Thailand')), _master);
      expect(resolveFareTariff(_all, const Geo()), _master, reason: 'before the geocoder answers');
    });

    test('a card only applies under its own parents', () {
      // A "Georgetown" elsewhere is not Penang's.
      const elsewhere = Geo(country: 'Malaysia', state: 'Selangor', city: 'Klang', suburb: 'Georgetown');
      expect(resolveFareTariff(_all, elsewhere), _master);
    });

    test('inactive cards are skipped; with no card at all there is none', () {
      const off = FareTariff(level: 'country', country: 'Singapore', currency: 'SGD', baseFare: 9, active: false);
      expect(resolveFareTariff([_master, off], const Geo(country: 'Singapore')), _master);
      expect(resolveFareTariff(const [], const Geo(country: 'Malaysia')), isNull);
    });
  });

  group('what a card charges', () {
    test('base + per km + per minute, times the service, plus the booking fee', () {
      const t = FareTariff(level: 'master', baseFare: 4, perKm: 1, perMinute: 0.3, bookingFee: 1);
      expect(tariffFare(t, 10, 20), 4 + 10 + 6 + 1);
      expect(tariffFare(t, 10, 20, multiplier: 1.5), 30 + 1, reason: 'the fee is not multiplied');
    });

    test('never below the minimum fare', () {
      const t = FareTariff(level: 'master', baseFare: 2, perKm: 0.5, minimumFare: 8, bookingFee: 0.5);
      expect(tariffFare(t, 1, 2), 8.5);
      expect(tariffFare(t, -5, -5), 8.5, reason: 'nonsense distances are zero');
    });

    test("the quote is in the card's currency, else the built-in tariff in ringgit", () {
      expect(quoteFare(_sg, 10, 20), (fare: tariffFare(_sg, 10, 20), currency: 'SGD'));
      expect(quoteFare(null, 10, 20, multiplier: 1.1), (fare: calculateFare(10, 20, multiplier: 1.1), currency: 'MYR'));
    });

    test('the rates read back as the admin list prints them', () {
      expect(describeFareTariff(_sg), 'SGD 3.90 base · 0.70/km · 0.20/min');
      expect(
        describeFareTariff(const FareTariff(level: 'master', baseFare: 4, perKm: 1, minimumFare: 6, bookingFee: 1)),
        'MYR 4 base · 1/km · 0/min · min 6 · +1 booking fee',
      );
    });
  });

  group('the admin editor', () {
    test('a card names every level above its own, a currency code and a charge', () {
      expect(fareTariffProblem(_georgetown), isNull);
      expect(
        fareTariffProblem(const FareTariff(level: 'city', country: 'Malaysia', city: 'Ipoh', baseFare: 1)),
        'Enter the state.',
      );
      expect(fareTariffProblem(const FareTariff(level: 'master', currency: 'RM', baseFare: 1)), contains('3-letter'));
      expect(fareTariffProblem(const FareTariff(level: 'master')), 'Set at least one charge.');
    });

    test('a row keeps only the levels its card names, and reads back the same', () {
      const typed = FareTariff(
        level: 'state',
        country: ' Malaysia ',
        state: 'Penang',
        city: 'left over',
        suburb: 'left over',
        label: '  ',
        currency: 'MYR',
        baseFare: 3,
      );
      final row = fareTariffRow(typed);
      expect(row['country'], 'Malaysia');
      expect(row['city'], isNull);
      expect(row['suburb'], isNull);
      expect(row['label'], isNull);
      final back = FareTariff.fromRow({...row, 'base_fare': '3.00'});
      expect(back.baseFare, 3);
      expect(back.scope, 'Penang, Malaysia');
      expect(FareTariff.fromRow({'level': 'master', 'per_km': -1, 'currency': 'sgd'}).perKm, 0);
      expect(FareTariff.fromRow({'level': 'master', 'currency': 'sgd'}).currency, 'SGD');
    });
  });
}
