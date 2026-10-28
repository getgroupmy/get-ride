// Premium service rules and GET.Plus (migration 0316), the pure parts: the
// rules by place, who may take a Premium request (the same cases as
// supabase/tests/premium_getplus_0316.sql), the booking card's rule line, a
// member's price, the server's answers, and the places that read them.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/catalogue/catalogue_logic.dart';
import 'package:get_ride/src/core/booking_modules.dart';
import 'package:get_ride/src/core/commission.dart' show Geo;
import 'package:get_ride/src/core/premium_plus.dart';
import 'package:get_ride/src/core/ride_services.dart';
import 'package:get_ride/src/data/models.dart';

const _default = PremiumPlusPlace(id: 'd', level: 'default', rules: {
  'premiumOn': true, 'premiumMaxCarAge': 5, 'premiumModels': ['Testmake Alpha', 'Lux 316'], 'premiumMinRating': 4.8,
  'premiumMinTrips': 200, 'plusOn': true, 'plusPrice': 19.9, 'plusDiscountPct': 10, 'plusMaxDiscount': 0,
  'plusFreeCancels': 2, 'plusPriority': true, 'plusGraceDays': 3,
});
const _testland = PremiumPlusPlace(id: 't', level: 'country', country: 'Testland 316', rules: {
  'plusPrice': 9.5, 'plusDiscountPct': 20, 'plusFreeCancels': 1, 'premiumMaxCarAge': 3,
});
const _north = PremiumPlusPlace(id: 'n', level: 'state', country: 'Testland 316', state: 'North 316', rules: {
  'premiumOn': false, 'plusOn': false,
});
const _places = [_north, _default, _testland];

void main() {
  group('the rules by place', () {
    test('no row: the built-in defaults, GET.Plus off', () {
      final r = premiumPlusRulesAt(const [], const Geo(country: 'Nowhere'));
      expect([r.premiumOn, r.maxCarAge, r.minRating, r.minTrips, r.models], [true, 5, 4.8, 200, isEmpty]);
      expect([r.plusOn, r.price, r.discountPct, r.maxDiscount, r.freeCancels, r.priority, r.graceDays],
          [false, 19.9, 10, 0, 2, true, 3]);
    });

    test('a region rule overrides only what it sets', () {
      final r = premiumPlusRulesAt(_places, const Geo(country: 'Testland 316', state: 'South 316', city: 'Town 316'));
      expect([r.price, r.discountPct, r.freeCancels, r.maxCarAge, r.minRating, r.plusOn],
          [9.5, 20, 1, 3, 4.8, true]);
      expect(r.models, ['Testmake Alpha', 'Lux 316']);
    });

    test('the smaller place wins; names without case', () {
      final r = premiumPlusRulesAt(_places, const Geo(country: 'testland 316', state: 'NORTH 316'));
      expect([r.plusOn, r.premiumOn, r.price], [false, false, 9.5]);
    });

    test('keys as the server keys them', () {
      expect(_default.key, '');
      expect(_north.key, 'testland 316|north 316');
      expect(const PremiumPlusPlace(level: 'suburb', country: 'MY', state: 'KL', city: 'KL', suburb: 'Bangsar').key,
          'my|kl|kl|bangsar');
      expect(_north.label, 'North 316 · state');
      expect(_north.toRow(), {'level': 'state', 'country': 'Testland 316', 'state': 'North 316', 'city': null,
        'suburb': null, 'rules': _north.rules});
    });

    test('bad values are refused, as the server', () {
      expect(premiumPlusRulesProblem({'plusDiscountPct': 95}), contains('from 0 to 90'));
      expect(premiumPlusRulesProblem({'premiumMaxCarAge': 2.5}), contains('whole number'));
      expect(premiumPlusRulesProblem({'premiumModels': ['']}), isNotNull);
      expect(premiumPlusRulesProblem({'surprise': 1}), isNotNull);
      expect(premiumPlusRulesProblem({'plusOn': 'yes'}), isNotNull);
      expect(premiumPlusRulesProblem({'premiumModels': ['Toyota Camry', 'Lexus'], 'plusOn': true}), isNull);
      expect(premiumPlusRulesProblem(_default.rules), isNull);
    });

    test('the admin fields read well', () {
      final f = {for (final x in [...premiumFields, ...plusFields]) x.key: x};
      expect(f['premiumMaxCarAge']!.show(5), '5 years old');
      expect(f['premiumMaxCarAge']!.show(0), 'No limit');
      expect(f['premiumMinRating']!.show(4.8), '4.8');
      expect(f['plusDiscountPct']!.show(10), '10%');
      expect(f['plusMaxDiscount']!.show(0), 'No cap');
      expect(f['plusGraceDays']!.show(1), '1 day');
      expect(f['plusPrice']!.show(19.9), contains('19.90'));
    });
  });

  group('who may take a Premium request', () {
    final rules = premiumPlusRulesAt(_places, const Geo(country: 'Testland 316'));

    test('a new listed car, 4.9 and 500 trips qualify', () {
      expect(premiumReasons(rules, hasCar: true, carAge: 0, make: 'Testmake', model: 'Alpha', rating: 4.9, trips: 500),
          isEmpty);
    });

    test('an old car off the list, a low rating and few trips: four reasons', () {
      final r = premiumReasons(rules, hasCar: true, carAge: 9, make: 'Oldmake', model: 'Beta', rating: 4.2, trips: 20);
      expect(r, [
        'Your car is 9 years old. Premium takes cars 3 years old or newer.',
        'Premium takes listed car models only, and your Oldmake Beta isn\'t on the list.',
        'Your rating is 4.2. Premium needs 4.8 or more.',
        'You have 20 trips. Premium needs 200 or more.',
      ]);
    });

    test('no car: choose one first; rules off: anyone', () {
      expect(premiumReasons(rules, hasCar: false, rating: 5, trips: 900), ['Choose the car you\'re driving first.']);
      final off = premiumPlusRulesAt(_places, const Geo(country: 'Testland 316', state: 'North 316'));
      expect(premiumReasons(off, hasCar: false), isEmpty);
    });

    test('models: a make allows its models; make and model match whole; none listed allows all', () {
      expect(premiumModelAllowed(['Lux 316'], 'LUX 316', 'Anything'), isTrue);
      expect(premiumModelAllowed(['Testmake  Alpha'], 'testmake', 'alpha'), isTrue);
      expect(premiumModelAllowed(['Testmake Alpha'], 'Testmake', 'Alphaville'), isFalse);
      expect(premiumModelAllowed(['Mercedes-Benz'], 'Mercedes Benz', 'E200'), isTrue);
      expect(premiumModelAllowed(const [], null, null), isTrue);
    });

    test('car age in whole years, from the registration date else the year', () {
      final today = DateTime(2026, 10, 31);
      expect(premiumCarAge(registered: DateTime(2010, 11, 1), today: today), 15);
      expect(premiumCarAge(year: '2021', today: today), 5);
      expect(premiumCarAge(year: 'n/a', today: today), isNull);
      expect(premiumCarAge(registered: DateTime(2027), today: today), 0);
    });

    test('the server\'s refusal in words', () {
      expect(
        premiumRefusalReason(Exception('PostgrestException(message: PREMIUM_NOT_ELIGIBLE, code: 42501, details: null, '
            'hint: You can\'t take Premium requests yet. Your rating is 4.2. Premium needs 4.8 or more.)')),
        'You can\'t take Premium requests yet. Your rating is 4.2. Premium needs 4.8 or more.',
      );
      expect(premiumRefusalReason(Exception('PREMIUM_NOT_ELIGIBLE')), contains('See Services'));
      expect(premiumRefusalReason(Exception('OFFER_DECLINED')), isNull);
    });

    test('the driver\'s status from the server', () {
      final s = PremiumStatus.fromJson({'service': 'Premium', 'ok': false, 'reasons': ['a', 'b']});
      expect([s.service, s.ok, s.reasons], ['Premium', false, ['a', 'b']]);
    });
  });

  group('the booking card', () {
    test('the Premium rule line', () {
      expect(premiumRuleLine(const PremiumTerms(maxCarAge: 5, modelsListed: true, minRating: 4.8)),
          'Cars 5 years or newer, listed models, drivers rated 4.8+');
      expect(premiumRuleLine(const PremiumTerms(maxCarAge: 5, modelsListed: true, minRating: 4.8, minTrips: 200)),
          'Cars 5 years or newer, listed models, drivers rated 4.8+ with 200+ trips');
      expect(premiumRuleLine(const PremiumTerms(minTrips: 50)), 'Drivers with 50+ trips');
      expect(premiumRuleLine(const PremiumTerms(modelsListed: true)), 'Listed car models');
      expect(premiumRuleLine(const PremiumTerms()), isNull);
      expect(premiumRuleLine(const PremiumTerms(on: false, maxCarAge: 5)), isNull);
      expect(premiumRuleLine(const PremiumTerms(maxCarAge: 5, minRating: 4.8)).toString(), isNot(contains('→')));
    });

    test('a member\'s price: the % off, the cap, as the server settles it', () {
      expect(plusMemberPrice(30, pct: 20), 24);
      expect(plusMemberPrice(30, pct: 20, maxDiscount: 4), 26);
      expect(plusMemberPrice(15.4, pct: 10), 13.86);
      expect(plusMemberPrice(23.1, pct: 10), 20.79);
      expect(plusMemberPrice(30, pct: 0), 30);
      expect(const PlusBenefits(pct: 10).price(15.4), 13.86);
    });

    test('the member banner', () {
      expect(plusBannerLine(const PlusBenefits(pct: 10, priority: true, freeCancels: 2, freeCancelsLeft: 2)),
          'GET.Plus member: 10% off, priority matching, 2 free cancels left this month');
      expect(plusBannerLine(const PlusBenefits(pct: 10, freeCancels: 2, freeCancelsLeft: 1)),
          'GET.Plus member: 10% off, 1 free cancel left this month');
      expect(plusBannerLine(const PlusBenefits(pct: 10, freeCancels: 2)),
          'GET.Plus member: 10% off, no free cancels left this month');
      expect(plusBannerLine(const PlusBenefits()), 'GET.Plus member');
    });
  });

  group('the server\'s answers', () {
    test('premium_plus_terms', () {
      final t = PremiumPlusTerms.fromJson({
        'premium': {'on': true, 'maxCarAge': 3, 'modelsListed': true, 'minRating': 4.8, 'minTrips': 200},
        'plus': {'on': true, 'price': 9.5, 'discountPct': 20, 'maxDiscount': 0, 'freeCancels': 1, 'priority': true,
          'graceDays': 3},
        'membership': {'status': 'active', 'live': true, 'autoRenew': false, 'periodEnd': '2026-11-28T03:36:10Z',
          'price': 9.5, 'freeCancelsUsed': 1},
        'benefits': {'pct': 20, 'maxDiscount': 0, 'priority': true, 'freeCancels': 1, 'freeCancelsLeft': 0},
        'walletBalance': 90.5,
      });
      expect([t.premium.maxCarAge, t.plus.price, t.plus.discountPct, t.walletBalance], [3, 9.5, 20, 90.5]);
      expect(t.membership!.cancelling, isTrue);
      expect(t.membership!.periodEnd!.isUtc, isFalse);
      expect(t.benefits!.freeCancelsLeft, 0);
      expect(PremiumPlusTerms.fromJson({'membership': null, 'benefits': null}).membership, isNull);
      expect(PlusStatus.parse('grace'), PlusStatus.grace);
      expect(PlusStatus.parse('nonsense'), PlusStatus.ended);
    });

    test('receipts, members and revenue', () {
      final r = PlusReceipt.fromRow({'id': 'x', 'receipt_no': 123, 'kind': 'renewal', 'status': 'paid', 'amount': 9.5,
        'created_at': '2026-10-28T00:00:00Z'});
      expect([r.label, r.paid, r.amount], ['GP-000123', true, 9.5]);
      final page = plusMembersPageFromJson({'total': 3, 'rows': [
        {'riderId': 'a', 'name': 'Aina', 'status': 'grace', 'paid': 28.5, 'saved': 10},
      ]});
      expect([page.total, page.rows.single.status, page.rows.single.saved], [3, PlusStatus.grace, 10]);
      final v = PlusRevenue.fromJson({'fees': 28.5, 'discounts': 10, 'waivedPaid': 2.4, 'net': 16.1, 'active': 4});
      expect([v.fees, v.discounts, v.net, v.active], [28.5, 10, 16.1, 4]);
    });

    test('join errors in words', () {
      expect(plusError(Exception('insufficient_balance'), price: 9.5), contains('Top up GET.wallet: GET.Plus is'));
      expect(plusError(Exception('PLUS_PRICE_CHANGED')), contains('price of GET.Plus just changed'));
      expect(plusError(Exception('PLUS_OFF')), 'GET.Plus isn\'t offered here yet.');
    });

    test('drivers see members\' requests first, the rest in order', () {
      expect(plusPriorityFirst([1, 2, 3, 4], (x) => x.isEven), [2, 4, 1, 3]);
    });
  });

  group('where the apps read it', () {
    test('the Vehicle Services editor keeps the Premium flag', () {
      ValuesResult build(bool? premium, Map<String, dynamic>? existing) => buildVehicleServiceValues(
        text: {'name': 'Premium'},
        numbers: {for (final f in vehicleServiceNumberFields) f.key: '1'},
        serviceTypes: const ['Car'],
        fuel: const [],
        status: true,
        premium: premium,
        existing: existing,
      );
      expect(build(true, null).values[premiumServiceKey], isTrue);
      expect(build(false, {'premium': true}).values.containsKey(premiumServiceKey), isFalse);
      expect(build(null, {'premium': true}).values[premiumServiceKey], isTrue, reason: 'kept when not edited');
      expect(vehicleServiceMeta({'premium': true}), contains('Premium'));
    });

    test('a Premium Vehicle Service is flagged on the booking list', () {
      final list = rideServicesFromCatalogue([
        (id: 'p', values: {'name': 'Premium', 'premium': true, 'status': true}),
        (id: 'r', values: {'name': 'Ride', 'status': true}),
      ], const {});
      expect({for (final s in list) s.name: s.premium}, {'Premium': true, 'Ride': false});
    });

    test('what is left to pay is less the member discount', () {
      final r = RideRequest({'id': 'x', 'status': 'completed', 'fare': 30, 'ride_fare': 30, 'plus_discount': 6,
        'plus_priority': true, 'currency': 'MYR'});
      expect([r.plusDiscount, r.plusPriority, r.cashDue], [6, true, 24]);
    });
  });

  group('the family plan (0323)', () {
    test('the benefits say whose plan covers the rider', () {
      final own = PlusBenefits.fromJson({'pct': 10, 'freeCancels': 2, 'freeCancelsLeft': 2, 'family': false})!;
      expect([own.family, own.hostName, own.familyLine], [false, null, null]);
      final fam = PlusBenefits.fromJson({'pct': 10, 'freeCancels': 2, 'freeCancelsLeft': 0, 'family': true,
        'hostName': ' Karpal Contoh '})!;
      expect(fam.family, isTrue);
      expect(fam.familyLine, "Covered by Karpal's family plan");
      expect(plusBannerLine(fam), "GET.Plus · Covered by Karpal's family plan: 10% off, no free cancels left this month");
      expect(plusFamilyLine(null), 'Covered by your family plan');
      expect(plusFamilyLine('James Tan'), "Covered by James' family plan");
      expect(plusBannerLine(const PlusBenefits(family: true, hostName: 'Aisha')), "GET.Plus · Covered by Aisha's family plan");
    });

    test('GET.Plus is a built Family module where only "Family pays" applies', () {
      final m = bookingModule(familyModuleGetPlus)!;
      expect([m.name, m.built, m.familyPaysOnly, m.tables], ['GET.Plus', true, true, isEmpty]);
      expect(m.screens, ['lib/src/features/wallet/plus_screen.dart']);
      expect(m.note, isNotNull);
      expect(bookingModules.where((x) => x.familyPaysOnly).map((x) => x.key), [familyModuleGetPlus]);
    });
  });
}
