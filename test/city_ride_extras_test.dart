// City ride extras (migration 0314): the rules by place, the waiting clock
// and charge, the luggage line, the tip terms, the receipt's lines, the
// statement's tips, and the app's cards kept in step with the server's
// checkers and defaults.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/city_ride_extras.dart';
import 'package:get_ride/src/core/partner_statement.dart';
import 'package:get_ride/src/core/partner_type_rules.dart' show RegionScope;
import 'package:get_ride/src/core/statement_layout.dart';
import 'package:get_ride/src/core/trip_receipt.dart';
import 'package:get_ride/src/data/models.dart';

const _kl = RegionScope(country: 'Malaysia', state: 'Kuala Lumpur', city: 'Kuala Lumpur');
const _my = RegionScope(country: 'Malaysia');

final _places = [
  const ExtrasPlace(id: 'd', rules: {
    'luggage': {'freeBags': 1, 'perBag': 3},
  }),
  const ExtrasPlace(id: 'my', scope: _my, rules: {
    'waiting': {'perMinute': 0.5},
    'tips': {'commissionPercent': 10},
  }),
  const ExtrasPlace(id: 'kl', scope: _kl, rules: {
    'waiting': {'on': false},
  }),
];

String _rm(double v) => 'RM${v.toStringAsFixed(2)}';

void main() {
  group('rules by place', () {
    test('nothing read: the built-in values', () {
      final x = CityRideExtras.standard;
      expect(x.tips.presets, [2, 5, 10]);
      expect([x.tips.min, x.tips.max, x.tips.days, x.tips.commissionPercent], [1, 100, 3, 0]);
      expect([x.waiting.freeMinutes, x.waiting.perMinute, x.waiting.cap, x.waiting.radiusM], [3, 0.3, 6, 150]);
      expect([x.luggage.freeBags, x.luggage.perBag, x.luggage.maxBags], [2, 2, 5]);
      expect(x.tips.on && x.waiting.on && x.luggage.on, isTrue);
    });

    test('each place lays only its own keys over the place above', () {
      final kl = CityRideExtras.resolve(_places, _kl);
      expect(kl.waiting.on, isFalse, reason: 'the city switched waiting off');
      expect(kl.waiting.perMinute, 0.5, reason: 'the country\'s rate is still read');
      expect(kl.waiting.freeMinutes, 3, reason: 'the built-in free minutes');
      expect(kl.tips.commissionPercent, 10);
      expect([kl.luggage.freeBags, kl.luggage.perBag, kl.luggage.maxBags], [1, 3, 5]);

      final sg = CityRideExtras.resolve(_places, const RegionScope(country: 'Singapore'));
      expect(sg.waiting.on, isTrue);
      expect(sg.waiting.perMinute, 0.3);
      expect(sg.luggage.perBag, 3, reason: 'Default\'s luggage everywhere');
    });

    test('a card a later batch adds is kept, with the others', () {
      final x = CityRideExtras.resolve([
        const ExtrasPlace(rules: {
          'audio': {'on': true, 'keepHours': 24},
        }),
      ], RegionScope.all);
      expect(x.section('audio'), {'on': true, 'keepHours': 24});
      expect(x.tips.on, isTrue);
    });

    test('as the server answers it', () {
      final x = CityRideExtras.fromJson({
        'waiting': {'on': true, 'perMinute': 0.4},
        'luggage': {'on': false},
      });
      expect(x.waiting.perMinute, 0.4);
      expect(x.waiting.cap, 6);
      expect(x.luggage.on, isFalse);
    });

    test('a place as stored and written back', () {
      final p = ExtrasPlace.fromRow({
        'id': 'x',
        'level': 'city',
        'country': 'Malaysia',
        'state': 'Kuala Lumpur',
        'city': 'Kuala Lumpur',
        'rules': {
          'waiting': {'on': false},
          'junk': 3,
        },
      });
      expect(p.scope.key, _kl.key);
      expect(p.rules.keys, ['waiting'], reason: 'only objects are cards');
      expect(p.sets('waiting'), isTrue);
      expect(p.sets('tips'), isFalse);
      final row = p.withSection('tips', {'days': 5}).toRow();
      expect(row['level'], 'city');
      expect(row['city'], 'Kuala Lumpur');
      expect(row['suburb'], isNull);
      expect(row['rules'], {
        'waiting': {'on': false},
        'tips': {'days': 5},
      });
      expect(p.withSection('waiting', null).rules, isEmpty);
    });
  });

  group('the waiting charge', () {
    const terms = WaitingTerms(freeMinutes: 3, perMinute: 0.5, cap: 6);
    final from = DateTime.utc(2026, 10, 28, 10);

    test('whole minutes past the free ones, at most the cap (as ride_waiting_charge)', () {
      expect(waitingCharge(terms, from, from.add(const Duration(minutes: 9, seconds: 59))), (minutes: 9, charge: 3.0));
      expect(waitingCharge(terms, from, from.add(const Duration(minutes: 2, seconds: 30))), (minutes: 2, charge: 0.0));
      expect(waitingCharge(terms, from, from.add(const Duration(minutes: 30))), (minutes: 30, charge: 6.0));
      expect(waitingCharge(terms, from, from.subtract(const Duration(minutes: 5))), (minutes: 0, charge: 0.0));
    });

    test('the clock both sides see', () {
      final early = WaitingClock(terms: terms, from: from, now: from.add(const Duration(seconds: 19)));
      expect(early.charging, isFalse);
      expect(early.label, 'Free waiting');
      expect(early.headline(_rm), '2:41 free left');
      expect(early.note(_rm), 'Waited 0 min. Free 3 min, then RM0.50 a minute, up to RM6.00.');

      final late = WaitingClock(terms: terms, from: from, now: from.add(const Duration(minutes: 9, seconds: 10)));
      expect(late.charging, isTrue);
      expect(late.label, 'Waiting charge running');
      expect(late.headline(_rm), 'RM3.00');

      final capped = WaitingClock(terms: terms, from: from, now: from.add(const Duration(minutes: 40)));
      expect(capped.label, 'Waiting charge (at its most)');

      final booked = WaitingClock(terms: terms, from: from, now: from.subtract(const Duration(minutes: 10)));
      expect(booked.notStarted, isTrue);
      expect(booked.label, 'Waiting starts at the booked time');
      expect(booked.headline(_rm), '3:00 free left');
    });

    test('the booking screen\'s rule line, none while waiting is free', () {
      expect(
        const WaitingRules().ruleLine(_rm),
        'Waiting: the first 3 minutes after your driver arrives are free, then RM0.30 a minute (up to RM6.00). '
        'Scheduled rides count from the booked time.',
      );
      expect(const WaitingRules(on: false).ruleLine(_rm), isNull);
      expect(const WaitingRules(perMinute: 0).ruleLine(_rm), isNull);
    });

    test('Arrived too far, in the driver\'s words', () {
      expect(
        arrivedRefusal('PostgrestException(message: RIDE_ARRIVED_TOO_FAR, hint: You\'re about 420 m from the pickup. '
            'Arrived works within 150 m of it.)'),
        'You\'re about 420 m from the pickup. Arrived works within 150 m of it.',
      );
      expect(arrivedRefusal('something else'), isNull);
    });
  });

  group('luggage', () {
    const rules = LuggageRules(freeBags: 2, perBag: 2, maxBags: 5);

    test('the bags past the free ones, as a line on the fare', () {
      expect(rules.charge(1), 0);
      expect(rules.line(2), isNull);
      final line = rules.line(3)!;
      expect(line.kind, 'luggage');
      expect(line.name, 'Luggage: 3 bags (2 free)');
      expect(line.amount, 2);
      expect(rules.note(1, _rm), '2 free, then RM2.00 a bag');
      expect(rules.note(4, _rm), '2 free, then RM2.00 a bag · + RM4.00');
      expect(const LuggageRules(freeBags: 0, perBag: 1).note(1, _rm), 'RM1.00 a bag · + RM1.00');
      expect(const LuggageRules(perBag: 0).note(3, _rm), 'Free');
      expect(luggageLineName(1, 0), 'Luggage: 1 bag');
    });

    test('held to the most bags; none while luggage is off', () {
      expect(rules.clamp(9), 5);
      expect(rules.clamp(-1), 0);
      expect(const LuggageRules(on: false).clamp(3), 0);
      expect(const LuggageRules(on: false).charge(5), 0);
    });
  });

  group('tips', () {
    test('the terms the server gives', () {
      final t = TipTerms.fromJson({
        'on': true,
        'presets': [2, 5, 10],
        'min': 1,
        'max': 100,
        'days': 3,
        'commissionPercent': 0,
        'until': '2026-10-30T10:00:00Z',
        'currency': 'MYR',
        'driverName': 'Hafiz Rahman',
        'canTip': true,
        'why': null,
        'tip': null,
        'cashTip': null,
      });
      expect(t.canTip, isTrue);
      expect(t.presets, [2, 5, 10]);
      expect(t.driverFirstName, 'Hafiz');
      expect(t.shareLine, 'All of it goes to Hafiz.');
      expect(t.laterLine, 'You can also tip from the receipt for 3 days.');
      expect(t.allows(1), isTrue);
      expect(t.allows(0.5), isFalse);
      expect(t.allows(101), isFalse);
      expect(TipTerms.fromJson({'commissionPercent': 10, 'driverName': 'Hafiz'}).shareLine, 'Hafiz gets 90% of it.');
      expect(TipTerms.fromJson(null).on, isFalse);
    });

    test('a tip already given, and the driver\'s cash mark', () {
      final t = TipTerms.fromJson({
        'on': true,
        'why': 'tipped',
        'tip': {'amount': 5, 'method': 'get_coin', 'driverAmount': 4.5},
        'cashTip': {'amount': null},
      });
      expect(t.canTip, isFalse);
      expect(t.tip!.amount, 5);
      expect(t.tip!.methodLabel, 'GET.coin');
      expect(t.tip!.driverAmount, 4.5);
      expect(t.cashTip, isNotNull);
      expect(t.cashTip!.amount, isNull);
    });

    test('refusals in plain words', () {
      expect(tipErrorMessage('insufficient_balance'), contains('Not enough balance'));
      expect(tipErrorMessage('TIP_EXPIRED'), 'The time to tip this trip has passed.');
      expect(tipErrorMessage('boom'), 'The tip didn\'t go through. Please try again.');
    });
  });

  group('the admin page\'s cards', () {
    test('tips, waiting charge and luggage, in that order', () {
      expect(cityRideExtrasCards.map((c) => c.title), ['Tips', 'Waiting charge', 'Luggage']);
      expect(cityRideExtrasPage, 'admin-settings-city-ride-extras');
    });

    test('− and + within the limits', () {
      const f = ExtrasField('perMinute', 'Then per minute', step: 0.05, min: 0, max: 5, unit: ExtrasUnit.money);
      expect(f.stepped(0.3, 1), 0.35);
      expect(f.stepped(0, -1), isNull);
      expect(f.stepped(5, 1), isNull);
      expect(f.show(0.35, _rm), 'RM0.35');
      expect(const ExtrasField('days', 'x', step: 1, min: 1, max: 30, unit: ExtrasUnit.days).show(1, _rm), '1 day');
      expect(const ExtrasField('r', 'x', step: 25, min: 25, max: 1000, unit: ExtrasUnit.metres).show(150, _rm), '150 m');
    });

    test('a card\'s values checked as the server does', () {
      expect(extrasSectionProblem('waiting', {'on': true, 'perMinute': 0.5}), isNull);
      expect(extrasSectionProblem('waiting', {'perMinute': 9}), contains('Then per minute'));
      expect(extrasSectionProblem('tips', {'min': 50, 'max': 10}), 'The smallest tip is more than the largest');
      expect(extrasSectionProblem('luggage', {'freeBags': 6, 'maxBags': 3}), 'More free bags than bags allowed');
      expect(extrasSectionProblem('luggage', {'bogus': 1}), contains('not a setting'));
    });

    // The cards' ranges and the defaults are the server's (0314).
    test('in step with the migration\'s checkers and defaults', () {
      final sql = File('supabase/migrations/0314_tips_waiting_luggage.sql').readAsStringSync();
      for (final card in cityRideExtrasCards) {
        final check = RegExp(
          'city_ride_extras_check_${card.section}\\(p jsonb\\)[\\s\\S]*?city_ride_extras_check_keys\\(p, \'(\\{[\\s\\S]*?\\})\'\\)',
        ).firstMatch(sql);
        expect(check, isNotNull, reason: '${card.section} has a checker');
        final spec = jsonDecode(check!.group(1)!) as Map<String, dynamic>;
        expect(spec['on'], 'bool');
        expect(spec.keys.where((k) => k != 'on').toSet(), card.fields.map((f) => f.key).toSet(), reason: card.section);
        for (final f in card.fields) {
          expect(spec[f.key], [f.min, f.max], reason: '${card.section}.${f.key}');
        }
        final defaults = RegExp(
          'city_ride_extras_default_${card.section}\\(\\)[\\s\\S]*?select \'(\\{[\\s\\S]*?\\})\'::jsonb',
        ).firstMatch(sql);
        expect(jsonDecode(defaults!.group(1)!), cityRideExtrasDefaults[card.section], reason: card.section);
      }
    });
  });

  group('the receipt', () {
    RideRequest ride(Map<String, dynamic> extra) => RideRequest({
      'id': '00000000-0000-0000-0000-000000031401',
      'status': 'completed',
      'fare': 19.2,
      'ride_fare': 19.2,
      'currency': 'MYR',
      ...extra,
    });

    test('the trip fare, the waiting and the luggage on their own lines', () {
      final r = ride({
        'waiting_charge': 1.8,
        'waiting_minutes': 9,
        'waiting_terms': {'freeMinutes': 3, 'perMinute': 0.3, 'cap': 6},
        'luggage': 3,
        'option_charges': [
          {'kind': 'luggage', 'name': 'Luggage: 3 bags (2 free)', 'amount': 2},
        ],
      });
      final lines = TripReceipt.fromRide(r).lines;
      expect(lines.map((l) => l.label).take(3), [
        'Trip fare',
        'Waiting 9 min (3 free), RM0.30 a min',
        'Luggage: 3 bags (2 free)',
      ]);
      expect(lines.take(3).map((l) => l.amount), [15.4, 1.8, 2]);
      expect(TripReceipt.fromRide(r).total, closeTo(19.2, 0.001), reason: 'the same total');
    });

    test('without them, one line as before', () {
      expect(TripReceipt.fromRide(ride({})).lines.first, (label: 'Trip fare', amount: 19.2));
    });
  });

  test('the statement and the Earnings page count the tips', () {
    final t = StatementTotals.fromJson({'tips': 6.3, 'cashTips': 4, 'cashTipCount': 1});
    expect([t.tips, t.cashTips, t.cashTipCount], [6.3, 4, 1]);
    expect(StatementTotals.zero.tips, 0);
    expect(statementField('tips')?.group, StatementFieldGroup.earnings);
    expect(statementField('tips')?.builtIn('ms'), 'Tip');
  });
}
