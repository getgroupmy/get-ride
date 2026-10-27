// City to City (lib/src/core/city_to_city.dart): which rule, the fare card,
// the add-on and the range, drivers' years and permits, and which
// commission rate wins. The same cases as supabase/tests/city_to_city_0306.sql.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/city_to_city.dart';
import 'package:get_ride/src/core/commission.dart' show Geo;
import 'package:get_ride/src/core/fare.dart' show ServiceRates;
import 'package:get_ride/src/core/fare_tariff.dart';

const _sem = 'Semenanjung 306';

C2cPlace _p(String level, {String? state, String? city, String? suburb, String country = _sem}) =>
    C2cPlace(level: level, country: country, state: state, city: city, suburb: suburb);

final _klCity = _p('city', state: 'Kuala Lumpur 306', city: 'Kuala Lumpur 306');
const _kl = Geo(country: _sem, state: 'Kuala Lumpur 306', city: 'Kuala Lumpur 306');
const _petaling = Geo(country: _sem, state: 'Selatan 306', city: 'Petaling 306');
const _ipoh = Geo(country: _sem, state: 'Perak 306', city: 'Ipoh 306');
const _kuantan = Geo(country: _sem, state: 'Pahang 306', city: 'Kuantan 306');
const _pulau = Geo(country: 'Pulau 306', state: 'Utara 306', city: 'Kota 306');
const _bangsar = Geo(country: _sem, state: 'Kuala Lumpur 306', city: 'Kuala Lumpur 306', suburb: 'Bangsar 306');

final _rules = [
  C2cRule(
    id: 'r1',
    from: [_klCity, _p('state', state: 'Selatan 306'), _p('city', state: 'Putrajaya 306', city: 'Putrajaya 306')],
    to: [_p('state', state: 'Perak 306')],
    addOnAmount: 20,
    rangeMode: C2cRangeMode.set,
    rangeLow: 130,
    rangeHigh: 150,
    position: 1,
  ),
  C2cRule(
    id: 'r2',
    from: [_klCity],
    to: [_p('state', state: 'Pinang 306')],
    fareMode: C2cFareMode.fixed,
    fixedFare: 190,
    rangeMode: C2cRangeMode.set,
    rangeLow: 180,
    rangeHigh: 210,
    bookAheadDays: 30,
    yearsMode: C2cYearsMode.off,
    position: 2,
  ),
  C2cRule(
    id: 'r5',
    from: [_p('state', state: 'Selatan 306')],
    to: [_p('country', country: 'Pulau 306')],
    addOnPercent: 15,
    yearsMode: C2cYearsMode.set,
    minYears: 5,
    position: 3,
  ),
  C2cRule(id: 'r3', from: [_p('country')], to: [_p('country')], addOnAmount: 10, position: 4),
  C2cRule(
    id: 'r4',
    from: [_p('suburb', state: 'Kuala Lumpur 306', city: 'Kuala Lumpur 306', suburb: 'Bangsar 306')],
    to: [_p('city', state: 'Pahang 306', city: 'Kuantan 306')],
    fareMode: C2cFareMode.fixed,
    fixedFare: 200,
    active: false,
    position: 5,
  ),
  C2cRule(id: 'r6', from: [_klCity], to: [_p('country')], addOnAmount: 1, position: 6),
  C2cRule(id: 'r7', from: [_p('country')], to: [_p('city', state: 'Pahang 306', city: 'Kuantan 306')], position: 7),
  C2cRule(id: 'r8', from: [_klCity], to: [_p('country')], addOnAmount: 3, position: 8),
];

String? _rule(Geo a, Geo b, [List<C2cRule>? rules]) => c2cRuleFor(rules ?? _rules, a, b)?.rule.id;

const _settings = C2cSettings(defaultAddOnAmount: 5, defaultRangePercent: 10);

final _cards = [
  FareTariff.fromRow({'level': 'country', 'country': _sem, 'base_fare': 2, 'per_km': 0.45, 'per_minute': 0.15}),
  FareTariff.fromRow({
    'level': 'city', 'country': _sem, 'state': 'Kuala Lumpur 306', 'city': 'Kuala Lumpur 306',
    'base_fare': 10, 'per_km': 0.5,
  }),
  FareTariff.fromRow({
    'level': 'city', 'country': _sem, 'state': 'Kuala Lumpur 306', 'city': 'Kuala Lumpur 306',
    'base_fare': 3, 'per_km': 0.4, 'per_minute': 0.2, 'vehicle_service': 'c2c',
  }),
];
const _rates = ServiceRates(perKm: 0.45, perMinute: 0.15, minimumFare: 50);

double _card(Geo g, {String service = 'c2c'}) =>
    c2cFareCard(_cards, g, 205, 160, vehicleService: service, serviceTypes: const {'m'}, rates: _rates).fare;

void main() {
  group('which rule', () {
    test('the most specific place on each end, several places per end', () {
      expect(_rule(_kl, _ipoh), 'r1', reason: 'city + state beats country + country');
      expect(_rule(_petaling, _ipoh), 'r1', reason: 'by its second place, Selatan');
      expect(_rule(const Geo(country: _sem, state: 'Putrajaya 306', city: 'Putrajaya 306'), _ipoh), 'r1');
      expect(_rule(const Geo(country: _sem, state: 'Pahang 306', city: 'Temerloh 306'), _ipoh), 'r3');
      expect(_rule(_petaling, _pulau), 'r5');
    });

    test('Kuala Lumpur is its own territory, not in Selatan; long names and any case match', () {
      expect(_rule(_kl, _pulau), isNull);
      expect(
        _rule(
          const Geo(country: 'semenanjung 306', state: 'Wilayah Persekutuan Kuala Lumpur 306', city: 'KUALA LUMPUR 306'),
          const Geo(country: _sem, state: 'Perak 306'),
        ),
        'r1',
      );
    });

    test('ties: the sum, then the pickup end, then the list order; inactive skipped', () {
      expect(_rule(_bangsar, _kuantan), 'r6');
      final on = [for (final r in _rules) r.id == 'r4' ? r.copyWith(active: true) : r];
      expect(_rule(_bangsar, _kuantan, on), 'r4');
      final first = [for (final r in _rules) r.id == 'r8' ? r.copyWith(position: 0) : r];
      expect(_rule(_kl, _kuantan, first), 'r8');
      expect(_rule(_pulau, _kl), isNull, reason: 'the default');
    });

    test('a side takes its most specific match', () {
      expect(c2cSideRank([_p('country'), _klCity], _kl), 3);
      expect(c2cSideRank([_p('country', country: 'Elsewhere')], _kl), 0);
    });
  });

  group('the fare card, the add-on and the range', () {
    test('the service\'s own card, every service\'s, own rates, then TEKSI', () {
      expect(_card(_kl), 117.00);
      expect(_card(_kl, service: 'another'), 112.50);
      expect(_card(_petaling), 118.25);
      final none = c2cFareCard(_cards, _pulau, 205, 160, vehicleService: 'c2c', rates: _rates);
      expect(none.fare, 116.25);
      expect(none.card, isNull);
      expect(c2cFareCard(_cards, _pulau, 10, 20).fare, 19.75);
    });

    test('card + RM add-on, set range, the default years', () {
      final q = c2cQuote(_rules, _settings, _kl, _ipoh, fareCard: _card(_kl));
      expect([q.ruleId, q.fareCard, q.addOn, q.suggested, q.low, q.high], ['r1', 117.0, 20.0, 137.0, 130.0, 150.0]);
      expect([q.fareMode, q.rangeMode, q.minYears, q.bookAheadDays], [C2cFareMode.card, C2cRangeMode.set, 3, 14]);
      expect(c2cQuote(_rules, _settings, _petaling, _ipoh, fareCard: _card(_petaling)).suggested, 138.25);
    });

    test('a fixed fare: no card, its own range, no minimum', () {
      final q = c2cQuote(_rules, _settings, _kl, const Geo(country: _sem, state: 'Pinang 306'), fareCard: 999);
      expect([q.fareMode, q.fareCard, q.suggested, q.low, q.high, q.minYears, q.bookAheadDays],
          [C2cFareMode.fixed, null, 190.0, 180.0, 210.0, null, 30]);
    });

    test('card + %, Auto ± 8 %, a rule\'s own years', () {
      final q = c2cQuote(_rules, _settings, _petaling, _pulau, fareCard: _card(_petaling));
      expect([q.suggested, q.addOn, q.low, q.high, q.minYears], [135.99, 17.74, 125.0, 147.0, 5]);
      expect(q.inRange, isTrue);
    });

    test('the default rule, and the experience switch off', () {
      final q = c2cQuote(_rules, _settings, _pulau, _kl, fareCard: _card(_pulau));
      expect([q.ruleId, q.suggested, q.low, q.high, q.minYears], [null, 121.25, 109.0, 133.0, 3]);
      final off = c2cQuote(_rules, _settings.copyWith(minYearsOn: false), _petaling, _pulau, fareCard: 100);
      expect(off.minYears, isNull);
    });

    test('rounding as the server does', () {
      expect(c2cRound2(118.25 * 1.15), 135.99);
      expect(c2cRound0(137 * 0.92), 126);
      expect(c2cRound0(132.5), 133);
    });
  });

  group('rules and settings: rows, text, problems', () {
    test('round trip through the row', () {
      final r = _rules[0];
      final back = C2cRule.fromRow({...r.toRow(), 'created_at': '2026-10-27T00:00:00Z'});
      expect(back.from, r.from);
      expect(back.to.single.label, 'Perak 306 · state');
      expect(back.rangeLow, 130);
      expect(r.toRow()['fixed_fare'], isNull);
      expect(_rules[1].toRow()['min_years'], isNull);
      expect(_klCity.toJson(), {'level': 'city', 'country': _sem, 'state': 'Kuala Lumpur 306', 'city': 'Kuala Lumpur 306'});
      expect(_klCity.within, 'Kuala Lumpur 306, Semenanjung 306');
    });

    test('list text', () {
      expect(c2cFareText(_rules[0]), 'Fare card + RM 20');
      expect(c2cFareText(_rules[1]), 'Fixed RM 190');
      expect(c2cFareText(_rules[2]), 'Fare card + 15%');
      expect(c2cFareText(const C2cRule()), 'Fare card + RM 0');
      expect(c2cRangeText(_rules[0]), 'RM 130 to RM 150');
      expect(c2cRangeText(_rules[2]), 'Auto ± 8%');
      expect(c2cYearsText(_rules[0], _settings), 'Default (3)');
      expect(c2cYearsText(_rules[2], _settings), '5 years');
      expect(c2cYearsText(_rules[1], _settings), 'Off');
      expect(const C2cSettings().cancelLine, 'Free to cancel until 24 hours before, then RM 20.');
      expect(const C2cSettings(cancelFeeOn: false).cancelLine, 'Free to cancel any time.');
    });

    test('what can\'t be saved', () {
      expect(c2cRuleProblem(const C2cRule()), 'Add at least one place to From and To.');
      expect(c2cRuleProblem(const C2cRule(), isDefault: true), isNull);
      expect(c2cRuleProblem(_rules[0]), isNull);
      expect(c2cRuleProblem(_rules[0].copyWith(rangeLow: 160)), 'The range low is at or below the high.');
      expect(c2cRuleProblem(_rules[1].copyWith(fixedFare: 300)), 'The fixed fare should sit inside the range.');
      expect(c2cRuleProblem(C2cRule(from: [_p('city')], to: [_p('country')])), 'A city needs its name.');
      expect(const C2cSettings(payInApp: false, payCash: false).problem, 'Keep at least one payment method on.');
      expect(const C2cSettings().problem, isNull);
    });

    test('settings from a row, missing values as the defaults', () {
      final s = C2cSettings.fromRow({'cancel_fee_amount': '25', 'pay_cash': false, 'default_range_mode': 'set'});
      expect([s.cancelFeeAmount, s.cancelFreeHours, s.payInApp, s.payCash, s.minYears], [25.0, 24, true, false, 3]);
      expect(s.defaultRule.rangeMode, C2cRangeMode.set);
      expect(C2cSettings.fromRow(null).cancelFeeOn, isTrue);
    });
  });

  group('drivers', () {
    const permits = [
      C2cCountryPermit(country: _sem, permitTypeId: 'card', name: 'Driver card 306'),
      C2cCountryPermit(country: _sem, permitTypeId: 'vp', name: 'Vehicle permit 306', appliesTo: 'vehicle'),
      C2cCountryPermit(country: 'Pulau 306', permitTypeId: 'pass', name: 'Border pass 306'),
    ];

    test('years of driving, whole years', () {
      expect(drivingYears(DateTime(2016, 10, 27), DateTime(2026, 10, 27)), 10);
      expect(drivingYears(DateTime(2016, 10, 28), DateTime(2026, 10, 27)), 9);
      expect(drivingYears(DateTime(2030), DateTime(2026)), 0);
    });

    test('permits for each country the trip touches', () {
      expect(c2cPermitsNeeded(permits, [_sem], {'card', 'vp'}), isEmpty);
      expect(c2cPermitsNeeded(permits, [_sem, 'Pulau 306'], {'card', 'vp'}).map((p) => p.name), ['Border pass 306']);
      expect(c2cPermitsNeeded(permits, [_sem], const {}).map((p) => p.label),
          ['Driver card 306 (driver)', 'Vehicle permit 306 (vehicle)']);
    });

    test('enough years and no permit missing; unknown years are not enough', () {
      expect(c2cDriverOk(minYears: 3, years: 10, needs: const []), isTrue);
      expect(c2cDriverOk(minYears: 3, years: 1, needs: const []), isFalse);
      expect(c2cDriverOk(minYears: 3, years: null, needs: const []), isFalse);
      expect(c2cDriverOk(minYears: null, years: null, needs: const []), isTrue);
      expect(c2cDriverOk(minYears: 5, years: 6, needs: [permits[2]]), isFalse);
    });
  });

  test('commission: the driver\'s own rate, a lower promotion, the service, the place', () {
    expect(commissionForService(userRate: 0.10, serviceRate: 0.12, placeRate: 0.15, promotionRate: 0.05),
        (rate: 0.10, source: CommissionSource.user));
    expect(commissionForService(serviceRate: 0.12, placeRate: 0.15, promotionRate: 0.08),
        (rate: 0.08, source: CommissionSource.promotion));
    expect(commissionForService(serviceRate: 0.12, placeRate: 0.15, promotionRate: 0.13),
        (rate: 0.12, source: CommissionSource.service));
    expect(commissionForService(placeRate: 0.15), (rate: 0.15, source: CommissionSource.place));
  });
}
