// myGiG (migration 0329), the app's pure half: the charge to drivers and
// the plan line, the phone as typed, what a number allows (ways to accept,
// ways to pay, the fee line under Payment), the price lines as the driver
// set them to show, the driver's settings and the live example, the admin's
// settings parts and region rules, the push routes, the partner type rule
// and the Family module.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart' show defaultPartnerMenuItems, mygigMenuItemId;
import 'package:get_ride/src/core/booking_modules.dart';
import 'package:get_ride/src/core/mygig.dart';
import 'package:get_ride/src/core/partner_type_rules.dart';
import 'package:get_ride/src/core/push_logic.dart';
import 'package:get_ride/src/features/mygig/mygig_new_screen.dart' show mygigSendProblem, mygigTripJson, MygigStop;
import 'package:get_ride/src/features/partner/partner_menu.dart' show partnerMenuRowShows;
import 'package:latlong2/latlong.dart';

void main() {
  group('the charge to drivers', () {
    test('words', () {
      expect(const MygigFee().text, 'No charge');
      expect(const MygigFee(mode: MygigFeeMode.trip, amount: 1).text, 'RM1.00 a trip');
      expect(const MygigFee(mode: MygigFeeMode.trip, amount: 5, percent: true).text, '5% of each fare');
      expect(const MygigFee(mode: MygigFeeMode.month, amount: 30).text, 'RM30.00 a month');
      expect(const MygigFee(mode: MygigFeeMode.half, amount: 150).text, 'RM150.00 every 6 months');
    });

    test('the per-trip fee, RM or % of the fare', () {
      expect(const MygigFee(mode: MygigFeeMode.trip, amount: 5, percent: true).tripFeeOn(20), 1);
      expect(const MygigFee(mode: MygigFeeMode.trip, amount: 1.5).tripFeeOn(20), 1.5);
      expect(const MygigFee(mode: MygigFeeMode.month, amount: 30).tripFeeOn(20), 0);
    });

    test('the plan line', () {
      expect(mygigPlanLine(const MygigFee(), null), 'No myGiG charge for you.');
      expect(mygigPlanLine(const MygigFee(mode: MygigFeeMode.trip, amount: 1), null),
          'myGiG fee: RM1.00 a trip, from your GET.credit when each ride ends.');
      expect(mygigPlanLine(const MygigFee(mode: MygigFeeMode.week, amount: 10), null), 'myGiG pass needed: RM10.00 a week.');
      final pass = MygigPass(mode: MygigFeeMode.week, amount: 10, endsAt: DateTime(2026, 11, 6));
      expect(mygigPlanLine(const MygigFee(mode: MygigFeeMode.week, amount: 10), pass), 'myGiG pass active until Fri 6 Nov 2026.');
    });

    test('read from the server', () {
      final f = MygigFee.fromJson({'mode': 'trip', 'amount': 5, 'unit': '%', 'own': true});
      expect([f.mode, f.amount, f.percent, f.own], [MygigFeeMode.trip, 5, true, true]);
      expect(f.toJson(), {'mode': 'trip', 'amount': 5.0, 'unit': '%'});
      expect(MygigFee.fromJson('nonsense').mode, MygigFeeMode.none);
    });
  });

  group('the driver\'s state', () {
    test('what the button does', () {
      final c = MygigConfig.fromJson({
        'ok': false, 'code': 'LIMIT', 'message': 'You took 10.', 'today': 10, 'limit': 10,
        'fee': {'mode': 'none'}, 'settings': {'dailyLimit': 10},
        'pricing': {'taxName': 'SST', 'taxKind': 'percent', 'taxValue': 6, 'wholeFare': false},
      });
      expect(c.offered, isTrue);
      expect(c.atLimit, isTrue);
      expect(c.todayText, 'myGiG today: 10 of 10');
      expect(c.taxPct, 6);
      expect(mygigBlockedDialog(c)?.title, 'Daily myGiG limit reached');
      expect(MygigConfig.fromJson({'code': 'TYPE'}).offered, isFalse);
      expect(mygigBlockedDialog(MygigConfig.fromJson({'code': 'BLOCKED'}))?.title, 'myGiG is off for you');
      expect(mygigBlockedDialog(MygigConfig.fromJson({'ok': true})), isNull);
      expect(MygigConfig.fromJson({'code': 'PASS_NEEDED'}).needsPass, isTrue);
      expect(const MygigConfig(today: 3).todayText, 'myGiG today: 3');
    });
  });

  group('the phone', () {
    test('as typed after +60', () {
      expect(mygigPhoneDigits('12 345 6789'), '60123456789');
      expect(mygigPhoneDigits('012-345 6789'), '60123456789');
      expect(mygigPhoneDigits('+60 12 345 6789'), '60123456789');
      expect(mygigPhoneDigits(''), isNull);
      expect(mygigPhoneComplete('12 345'), isFalse);
      expect(mygigPhoneComplete('12 345 6789'), isTrue);
      expect(mygigPhoneText('60123456789'), '+60 12 345 6789');
    });

    test('what the number is', () {
      final l = MygigLookup.fromJson({
        'state': 'latest', 'name': 'Ai**a', 'idType': 'MyKad', 'id': '•••• 5678', 'version': '1.4.11',
        'family': {'host': 'Farid', 'left': 150}, 'businesses': [{'id': 'b1', 'name': 'Tech Corp'}],
      });
      expect(l.registered, isTrue);
      expect(l.idLine, 'MyKad •••• 5678');
      expect(l.note, contains('You can send the fare to their app'));
      expect(mygigPayOptions(l), [MygigPay.cash, MygigPay.wallet, MygigPay.link, MygigPay.family, MygigPay.business]);
      final none = MygigLookup.fromJson({'state': 'none', 'repeat': 4, 'flagged': true});
      expect(none.needsName, isTrue);
      expect(mygigPayOptions(none), [MygigPay.cash, MygigPay.link]);
      final old = MygigLookup.fromJson({'state': 'old', 'version': '1.4.6', 'latest': '1.4.11'});
      expect(old.note, contains('not the latest (1.4.11)'));
    });

    test('the ways to accept, as the admin allows them', () {
      const s = MygigSettings({'ways': {'sms': false}});
      expect(mygigWays(s, MygigLookupState.latest, hasPhone: true), [MygigWay.app, MygigWay.whatsapp, MygigWay.here]);
      expect(mygigWays(s, MygigLookupState.none, hasPhone: true), [MygigWay.whatsapp, MygigWay.here]);
      expect(mygigWays(MygigSettings.fallback, MygigLookupState.short, hasPhone: false), [MygigWay.here]);
      expect(mygigWays(MygigSettings.fallback, MygigLookupState.blocked, hasPhone: true), isEmpty);
    });

    test('the line under Payment: a fee only for a registered passenger paying in the app', () {
      const reg = MygigLookup(state: MygigLookupState.latest, name: 'Ai**a', familyHost: 'Farid');
      const none = MygigLookup(state: MygigLookupState.none);
      expect(mygigFeeNote(none, MygigPay.cash, cancelFee: 5, noShowFee: 5, freeMin: 2), contains('there is no account to charge'));
      expect(mygigFeeNote(reg, MygigPay.cash, cancelFee: 5, noShowFee: 5, freeMin: 2),
          'Paying by cash: no cancellation or no-show fee. Choose GET.wallet, Family to cover them.');
      expect(mygigFeeNote(reg, MygigPay.wallet, cancelFee: 5, noShowFee: 0, freeMin: 2),
          'If they cancel after accepting (after 2 min) or don’t come: RM5.00 cancellation fee, no no-show fee.');
      expect(mygigFeeNote(const MygigLookup(), MygigPay.cash, cancelFee: 5, noShowFee: 5, freeMin: 2), isNull);
    });
  });

  group('sending', () {
    test('why it can\'t be sent yet', () {
      const q = MygigQuote({'total': 13.45});
      String? why({String phone = '', String name = '', MygigPay pay = MygigPay.cash, MygigWay? way = MygigWay.here,
              MygigLookup lookup = const MygigLookup(), MygigQuote? quote = q, bool required = false}) =>
          mygigSendProblem(quote: quote, lookup: lookup, phone: phone, name: name, pay: pay, way: way, phoneRequired: required);
      expect(why(), isNull);
      expect(why(way: null), 'Choose how the passenger accepts the fare.');
      expect(why(pay: MygigPay.link), 'Pay by link needs the passenger’s phone.');
      expect(why(required: true), 'Enter the passenger’s phone number.');
      expect(why(phone: '12 34'), 'Finish the phone number, or clear it.');
      expect(why(phone: '17 888 4040', lookup: const MygigLookup(state: MygigLookupState.none)),
          'Enter the passenger’s name: this number isn’t registered.');
      expect(why(lookup: const MygigLookup(state: MygigLookupState.blocked)), 'You blocked this number.');
      expect(why(quote: const MygigQuote({'problem': {'message': 'myGiG pickups aren\'t allowed at KLIA.'}})),
          'myGiG pickups aren\'t allowed at KLIA.');
    });

    test('the trip as the server reads it', () {
      final j = mygigTripJson(
        pickup: const MygigStop(name: 'Current location', at: LatLng(3.11, 101.66), here: true),
        drop: const MygigStop(name: 'KL Sentral', at: LatLng(3.13, 101.68)),
        stops: const [MygigStop(name: 'Mid Valley', at: LatLng(3.12, 101.67))],
        km: 6.6,
        bags: const {'medium': 2},
        pay: MygigPay.wallet,
      );
      expect(j['pickup'], containsPair('here', true));
      expect((j['drop'] as Map).containsKey('here'), isFalse);
      expect(j['bags'], {'small': 0, 'medium': 2, 'large': 0});
      expect(j['km'], 6.6);
      expect(j.containsKey('min'), isFalse);
      expect(j['pay'], 'wallet');
      expect((j['stops'] as List).single, containsPair('name', 'Mid Valley'));
    });
  });

  group('the price', () {
    const q = MygigQuote({
      'km': 6.6, 'min': 16, 'fare': 13.45, 'busy': 2.69, 'busyLabel': 'Night +20%', 'luggage': 4,
      'approach': 0, 'approachFull': 7.5, 'approachKm': 3.5, 'approachWaived': true,
      'pickupFee': 5, 'pickupFeeName': 'KLIA kerbside fee', 'tax': 1.51, 'taxName': 'SST', 'showTax': true,
      'rounded': 0.35, 'total': 27, 'appPrice': 20, 'guard': true,
      'terms': {'canCharge': true, 'cancelFee': 5, 'noShowFee': 3},
    });

    test('the lines', () {
      final lines = q.lines(what: 'myGiG', bags: const {'medium': 2});
      expect([for (final l in lines) l.label], [
        'Fare · myGiG · 6.6 km',
        'Busy time · Night +20%',
        'Luggage · 2 medium bags',
        'Coming to the pickup · 3.5 km (waived)',
        'KLIA kerbside fee · pickup',
        'SST',
        'Rounded up',
      ]);
      final waived = lines.firstWhere((l) => l.label.startsWith('Coming'));
      expect([waived.amount, waived.struck, waived.was], [0, true, 7.5]);
      expect(q.taxNote, isNull);
      expect([q.guard, q.canCharge, q.cancelFee, q.noShowFee], [true, true, 5, 3]);
    });

    test('one price that includes the tax: no tax line, still charged', () {
      final one = MygigQuote({...q.raw, 'showTax': false});
      expect(one.lines(what: 'x').any((l) => l.label == 'SST'), isFalse);
      expect(one.taxNote, 'Price includes service tax');
      expect(one.total, 27);
    });

    test('bags in words', () {
      expect(mygigBagsText(const {}), 'No luggage');
      expect(mygigBagsText(const {'small': 1}), '1 small bag');
      expect(mygigBagsText(const {'small': 1, 'large': 2}), '1 small, 2 large bags');
    });

    test('the waiting charge past the free minutes', () {
      expect(mygigWaitCharge(2, 3, 0.3), (over: 0, charge: 0.0));
      expect(mygigWaitCharge(10, 3, 0.3), (over: 7, charge: 2.1));
    });
  });

  group('the driver\'s own settings', () {
    test('set by path and the live example', () {
      const s = MygigSettings({'fare': {'base': 4, 'perKm': 0.95, 'perMin': 0.25, 'min': 8}, 'allowOwnFare': true});
      var p = const MygigPrefs({});
      expect(p.waitOn, isTrue);
      expect(p.busyOn, isFalse);
      p = p.set('busy.on', true).set('roundUp', true);
      expect(p.busyOn, isTrue);
      // 4 + 0.95 × 6.6 + 0.25 × 16 = 14.27; SST 6% = 0.86; 15.13, rounded up to 16.
      final ex = p.example(s, taxPct: 6);
      expect([ex.fare, ex.tax, ex.total], [14.27, 0.86, 16]);
      expect(ex.rounded, closeTo(0.87, 0.001));
      final own = p.set('ownFare', true).set('fare', {'base': 10, 'perKm': 2.5, 'perMin': 0.25, 'min': 8});
      expect(own.example(s).fare, 10 + 16.5 + 4);
      expect(own.example(const MygigSettings({'allowOwnFare': false})).fare, 14.27, reason: 'own fares off: get.ride\'s');
    });

    test('the fare card in words', () {
      expect(const MygigFareCard().text, 'RM4.00 + RM0.95/km + RM0.25/min, min. RM8.00');
      expect(const MygigFareCard().fareFor(1, 1), 8, reason: 'at least the minimum');
    });
  });

  group('a myGiG ride', () {
    test('its terms', () {
      final g = MygigRide.of({
        'mygig': {
          'way': 'sms', 'pay': 'wallet', 'registered': true, 'phone': '+60123456789',
          'terms': {'canCharge': true, 'noShowFee': 5, 'cancelFee': 10, 'cancelFreeMin': 2},
          'quote': {'total': 20, 'wait': {'on': true, 'freeMin': 3, 'perMin': 0.3}},
          'stopWaitMin': 4, 'stopWaitCharge': 1.2, 'tripFee': {'mode': 'trip', 'amount': 1}, 'tripFeeAmount': 1,
        },
      })!;
      expect([g.way, g.pay, g.canCharge, g.noShowFee, g.cancelFee, g.waitFreeMin], [MygigWay.sms, MygigPay.wallet, true, 5, 10, 3]);
      expect(g.following, 'Following on the trip link');
      expect(g.tripFee.text, 'RM1.00 a trip');
      expect(MygigRide.of({'mygig': null}), isNull);
    });

    test('no losses: what a pay-by-link passenger owes, and a cash passenger\'s pickup', () {
      MygigRide g(Map<String, dynamic> m) => MygigRide.of({'mygig': m})!;
      expect(g({'pay': 'link', 'quote': {'total': 20}}).owed, 20, reason: 'the agreed price at acceptance');
      expect(g({'pay': 'link', 'quote': {'total': 20}, 'linkPaid': 20}).owed, 0);
      expect(g({'pay': 'link', 'quote': {'total': 20}, 'linkPaid': 20, 'pendingFinal': {'due': 23.5}}).owed, 3.5,
          reason: 'what was added, before the trip ends');
      expect(g({'pay': 'link', 'quote': {'total': 20}, 'cashPaid': 20}).owed, 0, reason: 'cash instead');
      expect(g({'pay': 'cash', 'quote': {'total': 20}}).owed, 0);
      expect(g({'pay': 'cash', 'quote': {'approach': 12}}).approachCashDue, 12);
      expect(g({'pay': 'cash', 'quote': {'approach': 12}, 'approachCashAt': 'now'}).approachCashDue, 0);
      expect(g({'pay': 'wallet', 'quote': {'approach': 12}}).approachCashDue, 0, reason: 'in the app: charged with the fare');
    });
  });

  group('the admin\'s settings', () {
    test('parts a region rule sets', () {
      final base = {'fare': {'base': 4}, 'allowOwnFare': true, 'ownFareLimits': {}, 'luggage': {'maxBags': 5}};
      var r = <String, dynamic>{};
      expect(mygigPartSet(r, 'fare'), isFalse);
      r = mygigSetPart(r, 'fare', on: true, from: base);
      expect(r.keys, containsAll(['fare', 'allowOwnFare', 'ownFareLimits']));
      expect(mygigPartSet(r, 'fare'), isTrue);
      r = mygigPut(r, 'fare.base', 5);
      expect(mygigGet(r, 'fare.base'), 5);
      expect(mygigMerge(base, r), containsPair('fare', {'base': 5}));
      expect(mygigMerge({'busy': {'maxPct': 50, 'allowed': true}}, {'busy': {'maxPct': 30}}),
          {'busy': {'maxPct': 30, 'allowed': true}}, reason: 'a region rule only overrides what it sets');
      r = mygigSetPart(r, 'fare', on: false, from: base);
      expect(r, isEmpty);
    });

    test('every field belongs to a part and times are checked', () {
      final parts = {for (final p in mygigParts) p.$1: p.$3};
      for (final f in mygigFields) {
        expect(parts[f.part], contains(f.path.split('.').first), reason: f.path);
      }
      expect(mygigTimeOk('06:00'), isTrue);
      expect(mygigTimeOk('25:00'), isFalse);
      expect(mygigTimeOk('6'), isFalse);
    });
  });

  group('wired in', () {
    test('the pushes open the right page', () {
      expect(pushRouteFor({'type': 'mygig_offer', 'offer_id': 'o1'}), '/mygig/offer/o1');
      expect(pushRouteFor({'type': 'mygig_answer', 'request_id': 'r1'}), '/drive/trip/r1');
      expect(pushRouteFor({'type': 'mygig_cancelled'}), '/drive');
    });

    test('the Family module and the ride module', () {
      expect(bookingModule(familyModuleMygig)?.name, 'myGiG');
      expect(bookingModule(familyModuleMygig)?.tables, ['ride_requests']);
      expect(rideBookingModule(mygig: true, hire: true), 'mygig');
    });

    test('the side-menu row shows only where myGiG does', () {
      expect(defaultPartnerMenuItems.map((e) => e.$1), contains(mygigMenuItemId));
      expect(partnerMenuRowShows(mygigMenuItemId, obdLinked: false, hasMyRideCode: false), isFalse);
      expect(partnerMenuRowShows(mygigMenuItemId, obdLinked: false, hasMyRideCode: false, mygig: true), isTrue);
      expect(partnerMenuRowShows(mygigMenuItemId, obdLinked: false, hasMyRideCode: false, mygig: true, approved: false), isFalse);
    });

    test('the partner type\'s myGiG switch, never TEKSI', () {
      const rules = PartnerTypeRules(mygigAllowed: true, mygigRegions: RegionList(all: false, regions: [RegionScope(country: 'Malaysia', state: 'Selangor')]));
      final back = PartnerTypeRules.fromValues({'rules': rules.toJson()});
      expect([back.mygigAllowed, back.mygigRegions.regions.single.state], [true, 'Selangor']);
      final car = EffectiveTypeRules(name: 'eHailing', vehicleRequired: true, rules: back);
      expect(car.mygigAt((country: 'Malaysia', state: 'Selangor', city: '', suburb: '')), isTrue);
      expect(car.mygigAt((country: 'Malaysia', state: 'Johor', city: '', suburb: '')), isFalse);
      expect(car.mygigAt(unknownPlace), isTrue, reason: 'a place that can\'t be told is not refused');
      expect(EffectiveTypeRules(name: 'TEKSI', vehicleRequired: true, rules: back).mygigOn, isFalse);
      expect(const PartnerTypeRules(mygigAllowed: true, mygigRegions: RegionList(all: false)).problem(vehicleRequired: false),
          'Pick the regions where myGiG is allowed, or choose All regions.');
      expect(const PartnerTypeRules().mygigAllowed, isFalse, reason: 'off until the admin turns it on');
    });
  });
}
