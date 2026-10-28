// Family (migration 0317), the app's pure side: the admin's values and the
// module switches by place (as family_settings_at / family_module_rule_at
// resolve them; supabase/tests/family_core_0317.sql checks the server on the
// same cases), the plain terms an invitee reads, the payment row, refusals.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/commission.dart' show Geo;
import 'package:get_ride/src/core/family.dart';
import 'package:get_ride/src/core/payment_types.dart';

String _m(num v) => 'RM ${v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2)}';

void main() {
  group('values by place', () {
    const kl = Geo(country: 'Malaysia', state: 'Kuala Lumpur', city: 'Kuala Lumpur');
    final rows = [
      const FamilyPlaceRules(place: FamilyPlace(), rules: {'maxMembers': 6, 'locationRule': 'ride'}),
      const FamilyPlaceRules(place: FamilyPlace(level: 'country', country: 'Malaysia'), rules: {'maxMembers': 8}),
      const FamilyPlaceRules(
        place: FamilyPlace(level: 'city', country: 'Malaysia', state: 'Kuala Lumpur', city: 'Kuala Lumpur'),
        rules: {'locationRule': 'always', 'aloneAge': 13},
      ),
    ];

    test('the place keys go from Default down', () {
      expect(familyPlaceKeys(kl), ['', 'malaysia', 'malaysia|kuala lumpur', 'malaysia|kuala lumpur|kuala lumpur']);
      expect(familyPlaceKeys(const Geo()), ['']);
      expect(const FamilyPlace(level: 'state', country: 'Malaysia', state: 'Perak').key, 'malaysia|perak');
      expect(const FamilyPlace().label, 'Default (everywhere)');
    });

    test('each value from the smallest place that sets it', () {
      final s = resolveFamilySettings(rows, kl);
      expect(s.maxMembers, 8, reason: 'the country');
      expect(s.locationRule, FamilyLocationRule.always, reason: 'the city');
      expect(s.aloneAge, 13);
      expect(s.codeTries, 3, reason: 'built in');
      final perak = resolveFamilySettings(rows, const Geo(country: 'Malaysia', state: 'Perak'));
      expect(perak.locationRule, FamilyLocationRule.ride);
      expect(perak.aloneAge, 12);
      expect(resolveFamilySettings(rows, const Geo(country: 'Singapore')).maxMembers, 6);
    });

    test("a place's values are checked as the server checks them", () {
      expect(familyRulesProblem({'maxMembers': 6, 'locationRule': 'never', 'enabled': false}), isNull);
      expect(familyRulesProblem({'maxMembers': 0}), contains('Most members'));
      expect(familyRulesProblem({'aloneAge': 30}), isNotNull);
      expect(familyRulesProblem({'perRideChoices': [20, 0]}), isNotNull);
      expect(familyRulesProblem({'locationRule': 'secret'}), isNotNull);
      expect(familyRulesProblem({'hidden': true}), isNotNull);
    });

    test('settings read and written', () {
      final s = FamilySettings.fromJson({'monthCap': 500, 'perRideChoices': [10, 30], 'locationRule': 'never'});
      expect(s.monthCap, 500);
      expect(s.perRideChoices, [10, 30]);
      expect(s.locationRule, FamilyLocationRule.never);
      expect(FamilySettings.fromJson(s.toJson()).toJson(), s.toJson());
      expect(const FamilySettings().maxMembers, 6);
    });
  });

  group('module switches', () {
    const kl = Geo(country: 'Malaysia', state: 'Kuala Lumpur');
    final rules = [
      const FamilyModuleRule(place: FamilyPlace(), moduleKey: 'ride', familyPays: true, bookForMember: true,
          childAllowed: true, liveShare: true),
      const FamilyModuleRule(place: FamilyPlace(level: 'state', country: 'Malaysia', state: 'Kuala Lumpur'),
          moduleKey: 'ride', childAllowed: false),
    ];

    test('a place overrides only what it sets', () {
      final s = resolveModuleSwitches(rules, 'ride', kl);
      expect(s.list, [true, true, false, true]);
      expect(resolveModuleSwitches(rules, 'ride', const Geo(country: 'Malaysia')).childAllowed, isTrue);
    });

    test('a new module is off until the admin turns it on', () {
      expect(resolveModuleSwitches(rules, 'seat_trip', kl).list, [false, false, false, false]);
    });

    test('a switch changes one box', () {
      final r = rules.first.withSwitch(2, null);
      expect(r.list, [true, true, null, true]);
      expect(r.toRow()['child_allowed'], isNull);
      expect(FamilyModuleRule.fromRow(r.toRow()).list, r.list);
    });
  });

  group('location', () {
    test('never more than the admin allows', () {
      expect(FamilyLocationRule.always.atMost(FamilyLocationRule.ride), FamilyLocationRule.ride);
      expect(FamilyLocationRule.never.atMost(FamilyLocationRule.always), FamilyLocationRule.never);
      expect(FamilyLocationRule.parse('nope'), FamilyLocationRule.ride);
    });
  });

  group('an invite', () {
    final invite = FamilyInvite.fromJson({
      'id': 'm1',
      'name': 'Aisha',
      'status': 'invited',
      'monthlyLimit': 200,
      'perRideLimit': 50,
      'location': 'always',
      'hostName': 'Karpal Contoh',
      'adminLocationRule': 'ride',
      'modules': ['Ride', 'City to City', 'Courier'],
    });

    test('the plain terms: what is paid, what is seen, who can see, leave at once', () {
      final terms = familyJoinTerms(invite, _m);
      expect([for (final (i, _) in terms) i], ['payments', 'location_on', 'visibility', 'logout']);
      expect(terms[0].$2, "You can pay with Karpal's GET.wallet, up to RM 200 a month and RM 50 a trip, "
          'for Ride, City to City and Courier.');
      expect(invite.location, FamilyLocationRule.ride, reason: 'the admin allows "while on a ride" at most');
      expect(terms[1].$2, contains('while you are on a ride'));
      expect(terms[1].$2, contains('"Shared with family"'));
      expect(terms[2].$2, 'You can always see who can see you. Nobody can watch you without you knowing.');
      expect(terms[3].$2, 'You can leave at any time; sharing stops at once.');
    });

    test('GET.Plus covered by the host\'s membership: its own line, not a GET.wallet payment (0323)', () {
      final i = FamilyInvite.fromJson({'id': 'm3', 'name': 'Amir', 'location': 'ride', 'hostName': 'Karpal Contoh',
        'modules': ['Ride', 'GET.Plus']});
      final terms = familyJoinTerms(i, _m);
      expect([for (final (k, _) in terms) k], ['payments', 'workspace_premium', 'location_on', 'visibility', 'logout']);
      expect(terms[0].$2, endsWith('for Ride.'));
      expect(terms[1].$2, startsWith("Karpal's GET.Plus covers you too while Karpal is a member"));
      expect(familyJoinTerms(invite, _m).any((t) => t.$1 == 'workspace_premium'), isFalse,
          reason: 'not listed when the family doesn\'t cover GET.Plus');
    });

    test('no location: said so', () {
      final i = FamilyInvite.fromJson({'id': 'm2', 'name': 'Raj', 'location': 'never', 'hostName': 'Karpal'});
      expect(familyJoinTerms(i, _m)[1].$2, contains("doesn't see your location"));
      expect(familyJoinTerms(i, _m)[0].$2, contains('no services yet'));
    });
  });

  group('booking', () {
    test('the payment row', () {
      expect(familyPayLabel('Karpal Contoh'), "Family · Karpal's GET.wallet");
      expect(familyPayLabel('James'), "Family · James' GET.wallet");
      const base = [PaymentChoice('Cash', 'Cash', PaymentKind.cash)];
      const on = FamilyPayOption(available: true, hostName: 'Karpal', left: 115.8);
      const off = FamilyPayOption(available: false, hostName: 'Karpal', message: 'Not for Freight');
      expect(withFamilyPayment(base, on).first.value, familyPaymentMode);
      expect(withFamilyPayment(base, on).first.label, "Family · Karpal's GET.wallet");
      expect(withFamilyPayment(base, off), base);
      expect(withFamilyPayment(base, null), base);
      expect(on.note(_m), 'RM 115.80 left this month for you');
      expect(off.note(_m), 'Not for Freight');
      expect(FamilyPayOption.fromJson(null), isNull);
    });

    test('who it is for, on the booking', () {
      expect(familyBookingColumns(), isEmpty);
      expect(familyBookingColumns(passengerId: 'c1', withAdult: true), {
        'family': {'passenger': 'c1', 'withAdult': true},
      });
      expect(familyBookingColumns(passengerId: 'm1'), {
        'family': {'passenger': 'm1'},
      });
    });

    test("a refusal in plain words: the server's hint, else the code's", () {
      final r = familyRefusal('FAMILY_LIMIT_REACHED', 'Your family limit has RM 2 left this month.');
      expect(r?.code, 'FAMILY_LIMIT_REACHED');
      expect(r?.message, 'Your family limit has RM 2 left this month.');
      expect(familyRefusal('FAMILY_MODULE_OFF', null)?.message, "Family payment isn't available for this service.");
      expect(familyRefusal('insufficient_balance', null), isNull);
      expect(familyProblem(const FamilyException('X', 'Words')), 'Words');
      expect(familyProblem(Exception('FAMILY_FULL')), 'Your family is full. Ask for more members.');
    });

    test('a passenger', () {
      final p = FamilyPassenger.fromJson({'id': 'c1', 'name': 'Iman', 'kind': 'child', 'age': 8, 'allowed': true,
          'needsAdult': true});
      expect(p.label, 'Iman (child)');
      expect(p.isChild && p.needsAdult, isTrue);
    });
  });

  group('the trip', () {
    test('who can see: the host only while shared, then the logged safety team', () {
      final s = FamilyTripStatus.fromJson({
        'family': true,
        'shared': true,
        'familyPays': true,
        'payer': 'Karpal',
        'left': 115.8,
        'viewers': [
          {'name': 'Karpal', 'what': 'Live location until drop-off'},
        ],
      });
      expect(whoCanSeeLines(s), [
        'Karpal (family host): live location until drop-off.',
        'GET.ride safety team: only when they open it for a report or SOS; every look is logged and you can ask to '
            'see the log.',
      ]);
      expect(whoCanSeeLines(const FamilyTripStatus()).length, 1);
    });

    test("a child's code and check", () {
      expect(isPickupCode('4827'), isTrue);
      expect(isPickupCode('48 27'), isFalse);
      expect(FamilyChildCode.fromJson({'code': '4827', 'triesLeft': 3})?.spaced, '4 8 2 7');
      final c = FamilyChildCheck.fromJson({'name': 'Iman Contoh', 'age': 12, 'bookedBy': 'Karpal'})!;
      expect(c.intro, 'Iman Contoh, 12, booked by Karpal. Check the photo and ask for the 4-digit code before they get in.');
      expect(c.first, 'Iman');
      expect(FamilyChildCheck.fromJson(null), isNull);
    });
  });

  group('the family', () {
    test('read from the server', () {
      final v = FamilyView.fromJson({
        'role': 'host',
        'family': {'id': 'f1', 'hostName': 'Karpal', 'cap': 6, 'count': 6, 'spent': 184.2,
            'capRequest': {'wanted': 8, 'status': 'pending'}},
        'members': [
          {'id': 'm1', 'name': 'Aisha Contoh', 'status': 'active', 'limit': 200, 'spent': 84.2, 'left': 115.8,
              'locationNow': 'ride'},
          {'id': 'c1', 'name': 'Iman', 'kind': 'child', 'birthDate': '2014-05-01'},
        ],
        'settings': {'maxMembers': 6},
        'modules': [
          {'key': 'ride', 'name': 'Ride', 'familyPays': true},
          {'key': 'freight', 'name': 'Freight', 'familyPays': false},
        ],
      });
      expect(v.role, FamilyRole.host);
      expect(v.full, isTrue);
      expect(v.capRequest?.wanted, 8);
      expect(v.members.first.initials, 'AC');
      expect(v.members.last.isChild, isTrue);
      expect([for (final m in v.payModules) m.key], ['ride']);
      expect(FamilyView.fromJson(null).role, FamilyRole.none);
    });

    test("the host's line under a member", () {
      final now = DateTime(2026, 10, 28);
      expect(familyMemberLine(FamilyMember.fromJson({'id': 'm', 'name': 'Raj', 'status': 'invited',
          'expiresAt': DateTime(2026, 11, 2, 9).toUtc().toIso8601String()}), _m, now), 'Invited · expires in 5 days');
      expect(familyMemberLine(const FamilyMember(id: 'm', name: 'A', spent: 84.2, limit: 200), _m, now),
          'RM 84.20 of RM 200 this month');
      expect(familyMemberLine(const FamilyMember(id: 'c', name: 'I', kind: 'child'), _m, now),
          'Child profile · you book their rides');
      expect(childAge(DateTime(2014, 10, 29), now), 11);
      expect(childAge(DateTime(2014, 10, 28), now), 12);
    });

    test("an admin's reason", () {
      expect(familyReasonOk('report', 'Rider report about a trip'), isTrue);
      expect(familyReasonOk('report', 'short'), isFalse);
      expect(familyReasonOk('curious', 'Just looking around here'), isFalse);
    });
  });
}
