// Place fees (migration 0324): reading the admin's rows and the server's
// answers, the words the admin and the rider see, and the admin form's
// checks (lib/src/core/place_fees.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/place_fees.dart';
import 'package:get_ride/src/core/scheduled_rides.dart';

String rm(double v) => 'RM ${v.toStringAsFixed(2)}';

void main() {
  group('a fee row', () {
    test('read from the database and written back', () {
      final f = PlaceFee.fromRow({
        'id': 'f1',
        'area_id': 'a1',
        'enabled': true,
        'sort_order': 2,
        'name': 'KLIA kerbside fee',
        'rider_note': 'For the kerbside lane',
        'applies_to': 'each',
        'amount_kind': 'percent',
        'amount': '10.00',
        'min_amount': 3,
        'max_amount': 8,
        'services': ['Comfort', ' ', 'Premium'],
        'days': [5, 1, 5, 9],
        'time_from': '22:00:00',
        'time_to': '02:00:00',
        'date_from': '2026-12-01',
        'date_to': 'not a date',
        'count_stops': true,
        'goes_to': 'driver',
      });
      expect(f.appliesTo, PlaceFeeEnd.each);
      expect(f.percent, isTrue);
      expect(f.amount, 10);
      expect(f.services, ['Comfort', 'Premium']);
      expect(f.days, [1, 5], reason: 'days kept once each, 0 to 6 only');
      expect((f.timeFrom, f.timeTo), ('22:00', '02:00'));
      expect((f.dateFrom, f.dateTo), ('2026-12-01', null));
      expect(f.goesTo, PlaceFeeGoesTo.driver);
      final row = f.toRow();
      expect(row['id'], 'f1');
      expect(row['applies_to'], 'each');
      expect(row['amount_kind'], 'percent');
      expect(row['min_amount'], 3);
      expect(row['time_from'], '22:00');
      expect(row['goes_to'], 'driver');
    });

    test('a new fee has no id; a fixed one keeps no least or most; one time alone is all day', () {
      const f = PlaceFee(areaId: 'a', name: ' Fee ', amount: 5, minAmount: 1, maxAmount: 2, timeFrom: '08:00');
      final row = f.toRow();
      expect(row.containsKey('id'), isFalse);
      expect(row['name'], 'Fee');
      expect(row['min_amount'], isNull);
      expect(row['max_amount'], isNull);
      expect(row['time_from'], isNull);
      expect(row['days'], placeFeeAllDays);
    });

    test('defaults for what an old or partial row leaves out', () {
      final f = PlaceFee.fromRow({'area_id': 'a', 'name': 'X'});
      expect(f.appliesTo, PlaceFeeEnd.pickup);
      expect(f.amountKind, PlaceFeeAmountKind.fixed);
      expect(f.goesTo, PlaceFeeGoesTo.pass);
      expect(f.days, placeFeeAllDays);
      expect(f.enabled, isTrue);
    });

    test('what the form says is wrong', () {
      const ok = PlaceFee(areaId: 'a', name: 'Fee', amount: 5);
      expect(ok.problem, isNull);
      expect(ok.copyWith(name: ' ').problem, contains('name'));
      expect(ok.copyWith(amount: 0).problem, 'Enter the amount.');
      expect(ok.copyWith(amount: 1001).problem, contains('at most'));
      expect(ok.copyWith(amountKind: PlaceFeeAmountKind.percent, amount: 101).problem, contains('100'));
      expect(
        ok.copyWith(amountKind: PlaceFeeAmountKind.percent, minAmount: () => 9, maxAmount: () => 2).problem,
        contains('least'),
      );
      expect(ok.copyWith(days: const []).problem, contains('day'));
      expect(ok.copyWith(timeFrom: () => '08:00').problem, contains('both'));
      expect(ok.copyWith(dateFrom: () => '2026-12-02', dateTo: () => '2026-12-01').problem, contains('after'));
    });

    test('in words: the amount and when', () {
      const f = PlaceFee(areaId: 'a', name: 'Fee', amount: 5);
      expect(f.amountText(rm), 'RM 5.00');
      expect(f.whenText(), 'Every day');
      final p = f.copyWith(amountKind: PlaceFeeAmountKind.percent, amount: 10, minAmount: () => 3, maxAmount: () => 8);
      expect(p.amountText(rm), '10% (RM 3.00 to RM 8.00)');
      expect(p.copyWith(maxAmount: () => null).amountText(rm), '10% (at least RM 3.00)');
      expect(f.copyWith(days: [1, 2, 3, 4, 5], timeFrom: () => '08:00', timeTo: () => '10:00').whenText(),
          'Mon to Fri, 08:00 to 10:00');
      expect(f.copyWith(days: [5], timeFrom: () => '22:00', timeTo: () => '02:00').whenText(), 'Fri, 22:00 to 02:00');
      expect(f.copyWith(days: [0, 6], dateFrom: () => '2026-12-01', dateTo: () => '2026-12-31').whenText(),
          'Sat and Sun · 2026-12-01 to 2026-12-31');
      expect(f.copyWith(dateFrom: () => '2026-12-01').whenText(date: (s) => 'D$s'), 'Every day · from D2026-12-01');
    });

    test('the choices in plain words', () {
      expect([for (final e in PlaceFeeEnd.values) placeFeeEndLabel(e)],
          ['Pickup', 'Drop-off', 'Either end (charged once)', 'Each end']);
      expect([for (final g in PlaceFeeGoesTo.values) placeFeeGoesToLabel(g)], ['Driver', 'Platform', 'Passed on']);
    });
  });

  group('the list', () {
    const a = PlaceFee(id: 'a', areaId: 'x', name: 'A', amount: 1, sortOrder: 0);
    const b = PlaceFee(id: 'b', areaId: 'x', name: 'B', amount: 1, sortOrder: 1);
    const c = PlaceFee(id: 'c', areaId: 'x', name: 'C', amount: 1, sortOrder: 2);
    const other = PlaceFee(id: 'o', areaId: 'y', name: 'O', amount: 1);

    test("a place's fees, in order; moving one; the next order", () {
      expect([for (final f in placeFeesFor([c, other, a, b], 'x')) f.id], ['a', 'b', 'c']);
      expect(reorderPlaceFees([a, b, c], 'c', -1), {'c': 1, 'b': 2});
      expect(reorderPlaceFees([a, b, c], 'a', -1), isEmpty, reason: 'the first can\'t go up');
      expect(reorderPlaceFees([a, b, c], 'c', 1), isEmpty);
      expect(nextPlaceFeeOrder([a, b, c]), 3);
      expect(nextPlaceFeeOrder(const []), 0);
    });

    test("the admin's trial fare: the fees for that end and service", () {
      final fees = [
        a.copyWith(name: 'Pickup fee', amount: 5),
        b.copyWith(name: 'Drop fee', appliesTo: PlaceFeeEnd.dropoff, amount: 2),
        c.copyWith(
            name: 'Pct', appliesTo: PlaceFeeEnd.each, amountKind: PlaceFeeAmountKind.percent, amount: 10,
            minAmount: () => 4),
        other.copyWith(name: 'Premium only', services: ['Premium'], appliesTo: PlaceFeeEnd.either, sortOrder: 3),
        a.copyWith(name: 'Off', enabled: false),
      ];
      expect(placeFeesForTrial(fees, pickup: true, service: 'Comfort', fare: 30),
          [(name: 'Pickup fee', amount: 5.0), (name: 'Pct', amount: 4.0)]);
      expect(placeFeesForTrial(fees, pickup: false, service: 'premium', fare: 100),
          [(name: 'Drop fee', amount: 2.0), (name: 'Pct', amount: 10.0), (name: 'Premium only', amount: 1.0)]);
    });
  });

  group('the settings', () {
    test('defaults for what is missing or wrong', () {
      final s = PlaceFeeSettings.fromJson({'showMapLabel': false, 'badgeText': '', 'maxTotal': -1, 'timeZone': 'Asia/Tokyo'});
      expect(s.showMapLabel, isFalse);
      expect(s.showAddressHint && s.showCardBadge && s.lockScheduled, isTrue);
      expect(s.badgeText, 'incl. place fee');
      expect(s.addressHintText, '{name} {amount} applies here');
      expect(s.maxTotal, isNull);
      expect(s.timeZone, 'Asia/Tokyo');
      expect(PlaceFeeSettings.fromJson(null).timeZone, 'Asia/Kuala_Lumpur');
    });

    test('saved with every key, and checked first', () {
      final s = PlaceFeeSettings.defaults.copyWith(lockScheduled: false, maxTotal: () => 20);
      expect(s.toJson(), {
        'lockScheduled': false,
        'timeZone': 'Asia/Kuala_Lumpur',
        'percentOf': 'fare',
        'showMapLabel': true,
        'showAddressHint': true,
        'showCardBadge': true,
        'showOutline': true,
        'badgeText': 'incl. place fee',
        'addressHintText': '{name} {amount} applies here',
        'maxTotal': 20.0,
      });
      expect(s.problem, isNull);
      expect(s.copyWith(badgeText: '').problem, contains('badge'));
      expect(s.copyWith(timeZone: ' ').problem, contains('time zone'));
      expect(s.copyWith(maxTotal: () => 20000).problem, contains('most'));
    });
  });

  group("the server's lines", () {
    const charges = [
      {'kind': 'surcharge', 'name': 'Night surcharge', 'charge': 'fixed', 'value': 2},
      {
        'kind': 'surcharge', 'charge': 'fixed', 'name': 'KLIA kerbside fee', 'value': 5, 'airport': 'pick',
        'place_fee': 'f1', 'area': 'a1', 'goes_to': 'pass', 'note': 'For the kerbside lane', 'locked': true,
      },
      {
        'kind': 'surcharge', 'charge': 'fixed', 'name': 'Driver fee', 'value': 3, 'airport': 'once',
        'place_fee': 'f2', 'area': 'a1', 'goes_to': 'driver', 'earning': true,
      },
    ];

    test('the place fees of a ride, by end', () {
      final lines = placeFeeLinesOf(charges);
      expect([for (final l in lines) l.label], ['KLIA kerbside fee (pickup)', 'Driver fee']);
      expect(lines.first.note, 'For the kerbside lane');
      expect(lines.first.locked, isTrue);
      expect(lines.last.goesTo, PlaceFeeGoesTo.driver);
      expect(placeFeesTotal(lines), 8);
      expect(passedOnPlaceFeeNames(charges), {'KLIA kerbside fee'});
      expect(PlaceFeeLine.fromCharge({'name': 'x', 'value': 1}), isNull, reason: 'not a place fee');
    });

    test('the quote: lines, ends, what to show', () {
      final q = PlaceFeesQuote.fromJson({
        'lines': charges,
        'total': 8,
        'pickup': {'area_id': 'a1', 'name': 'KLIA', 'fees': [{'name': 'KLIA kerbside fee', 'amount': 5}]},
        'drop': null,
        'settings': {'showMapLabel': true, 'showAddressHint': true, 'showCardBadge': true,
                     'badgeText': 'with fee', 'addressHintText': '{name} {amount} applies here'},
      });
      expect(q.lines.length, 2);
      expect(q.total, 8);
      expect(q.hintFor(q.pickup, rm), 'KLIA kerbside fee RM 5.00 applies here');
      expect(q.hintFor(q.drop, rm), isNull);
      expect(q.mapLabelFor(q.pickup, rm), 'KLIA · RM 5.00');
      expect(q.badge, 'with fee');
      final off = PlaceFeesQuote.fromJson({
        'lines': charges,
        'pickup': {'area_id': 'a1', 'name': 'KLIA', 'fees': [{'name': 'A', 'amount': 5}, {'name': 'B', 'amount': 1}]},
        'settings': {'showMapLabel': false, 'showAddressHint': true, 'showCardBadge': false},
      });
      expect(off.mapLabelFor(off.pickup, rm), isNull);
      expect(off.badge, isNull);
      expect(off.hintFor(off.pickup, rm), 'KLIA RM 6.00 applies here', reason: 'two fees: the place and their sum');
      expect(PlaceFeesQuote.fromJson(null).isEmpty, isTrue);
      expect(PlaceFeesQuote.fromJson({'lines': []}).badge, isNull);
    });

    test('the hint text', () {
      expect(placeFeeHint('{name}  costs {amount} ', name: 'KLIA fee', amount: 'RM 5'), 'KLIA fee costs RM 5');
      expect(placeFeeHint('Fee here', name: 'x', amount: 'y'), 'Fee here');
    });

    test("a booking for later: its locked fees in what the rider pays", () {
      final r = ScheduledRide.fromRow({
        'id': 's1',
        'pickup_at': '2026-11-02T01:00:00Z',
        'status': 'scheduled',
        'fare': 30,
        'scheduling_fee': 2,
        'request': {'charges': charges},
      });
      expect([for (final l in r.placeFees) l.name], ['KLIA kerbside fee']);
      expect(r.total, 37);
      expect(ScheduledRide.fromRow({'id': 's2', 'pickup_at': '2026-11-02T01:00:00Z', 'status': 'scheduled', 'fare': 30})
          .total, 30);
    });
  });
}
