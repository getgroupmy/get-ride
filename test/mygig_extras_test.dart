// myGiG part C (migration 0331): the pure logic. When drivers may
// reassign, what each side reads of a reassign, hotspots' hours, splitting
// a fare, tips and e-Invoice details, regulars, the dashboard's shares, the
// admin's settings parts, the side menu row and the push routes.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart';
import 'package:get_ride/src/core/mygig.dart';
import 'package:get_ride/src/core/mygig_extras.dart';
import 'package:get_ride/src/core/mygig_hire.dart';
import 'package:get_ride/src/core/push_logic.dart';
import 'package:get_ride/src/features/partner/partner_menu.dart';

Map<String, dynamic> _reassign({String stage = 'driver', String way = 'sms', double paid = 13.45, double kept = 0}) => {
  'id': 'ra1',
  'rideId': 'r1',
  'stage': stage,
  'reason': 'Car problem',
  'during': false,
  'way': way,
  'answerBy': DateTime(2026, 10, 30, 10).toIso8601String(),
  'kind': 'trip',
  'kindName': 'myGiG ride',
  'when': 'now',
  'trip': {
    'pickup': {'name': 'Bangsar South'},
    'drop': {'name': 'KL Sentral'},
    'stops': [{'name': 'Mid Valley'}],
  },
  'pax': 2,
  'bags': {'small': 1, 'medium': 1, 'large': 0},
  'total': 25.45,
  'pay': 'link',
  'paidMoves': paid,
  'kept': kept,
  'noAnswer': 'keep',
  'from': {'id': 'd1', 'name': 'Hafiz', 'rating': 4.9, 'vehicle': 'Perodua Bezza', 'plate': 'WXY 2481'},
  'to': {'id': 'd2', 'name': 'Lee', 'rating': 4.8, 'vehicle': 'Toyota Innova', 'plate': 'VBC 7720', 'colour': 'White'},
  'passenger': 'Ben',
  'registered': false,
  'plan': {'mode': 'trip', 'amount': 1, 'unit': 'RM'},
  'me': 'to',
};

void main() {
  group('when drivers may reassign', () {
    test('the default: before pickup and scheduled, not during the trip', () {
      const r = MygigReassignRule({});
      expect(r.allows(status: 'accepted'), isTrue);
      expect(r.allows(status: 'arrived'), isTrue);
      expect(r.allows(status: 'on_trip'), isFalse);
      expect(r.allows(status: 'accepted', booked: true), isTrue);
      expect(r.allows(status: 'completed'), isFalse);
      expect(r.answerMin, 10);
      expect(r.keepOnNoAnswer, isTrue);
      expect(r.sameOrBigger, isTrue);
    });

    test('scheduled only, during, off', () {
      expect(const MygigReassignRule({'when': 'scheduled'}).allows(status: 'accepted'), isFalse);
      expect(const MygigReassignRule({'when': 'scheduled'}).allows(status: 'accepted', booked: true), isTrue);
      expect(const MygigReassignRule({'when': 'during'}).allows(status: 'on_trip'), isTrue);
      expect(const MygigReassignRule({'enabled': false}).allows(status: 'accepted', booked: true), isFalse);
      expect(MygigReassignRule.of({'reassign': {'noAnswer': 'cancel'}}).keepOnNoAnswer, isFalse);
    });

    test('the button and the no-answer rule in words', () {
      expect(mygigReassignLabel(onTrip: false), 'Reassign to another driver');
      expect(mygigReassignLabel(onTrip: true), 'Hand over to another driver');
      expect(mygigNoAnswerText(keep: false), 'the ride is cancelled with no charge');
      expect(mygigNoAnswerText(keep: true), 'the first driver keeps the ride');
    });
  });

  group('a reassign as each side reads it', () {
    test('the new driver: the order, the price, the money that moves, their plan', () {
      final r = MygigReassign(_reassign());
      expect(r.open, isTrue);
      expect((r.pickupName, r.dropName), ('Bangsar South', 'KL Sentral'));
      expect(r.stopNames, ['Mid Valley']);
      expect(r.whoText, '2 passengers · 2 bags');
      expect(r.moneyLine, 'Payment: Pay by link; RM13.45 already paid moves to you.');
      expect(r.plan!.text, 'RM1.00 a trip');
      expect(r.to.carText, 'Toyota Innova · White · VBC 7720');
      expect(r.to.ratingText, '★ 4.8');
    });

    test('the passenger: same price, the money that moves', () {
      final r = MygigReassign(_reassign(stage: 'passenger'));
      expect(r.passengerMoneyLine(), 'Pay by link. The RM13.45 you paid moves to Lee. Nothing else changes.');
      expect(MygigReassign(_reassign(paid: 0)..['pay'] = 'cash').passengerMoneyLine(), 'Cash. Nothing else changes.');
    });

    test('what the first driver reads at each stage', () {
      expect(mygigReassignStatusText(MygigReassign(_reassign())), contains('must tick that they accept it at the agreed price'));
      expect(mygigReassignStatusText(MygigReassign(_reassign(stage: 'passenger'))),
          'Lee accepted. Waiting for the passenger: on the link sent by SMS. They confirm Lee, keep you, or cancel free.');
      expect(mygigReassignStatusText(MygigReassign(_reassign(stage: 'done', kept: 12))),
          'Handed over to Lee. You keep RM12.00 for coming to the pickup.');
      expect(mygigReassignStatusText(MygigReassign(_reassign(stage: 'expired'))), 'No answer in time. The ride is still yours.');
      expect(mygigReassignReach('here'), 'on your phone (show it to them)');
      expect(mygigReassignStageFrom('kept'), MygigReassignStage.kept);
      expect(mygigReassignStageFrom('nonsense'), MygigReassignStage.expired);
    });

    test('the history in words', () {
      expect(mygigReassignStepText({'what': 'asked', 'to': 'Lee', 'reason': 'Car problem'}), 'Asked Lee (Car problem)');
      expect(mygigReassignStepText({'what': 'reassign_new_driver_accepted'}), 'New driver accepted at the agreed price');
      expect(mygigReassignStepText({'what': 'kept', 'by': 'rule'}), 'No answer: the first driver kept it');
      expect(mygigReassignStepText({'what': 'cancelled', 'by': 'passenger'}), 'Passenger cancelled with no charge');
      expect(mygigReassignStepText({'what': 'split', 'parts': 3}), 'Fare split 3 ways');
    });

    test('the options: eligible drivers and why not', () {
      const o = MygigReassignOptions({
        'reasons': ['Car problem', 'Other'],
        'drivers': [
          {'id': 'd2', 'name': 'Lee', 'km': 0.3, 'why': null},
          {'id': 'd3', 'name': 'Tan', 'km': 0.4, 'why': 'Smaller vehicle'},
        ],
        'answerMin': 15,
        'noAnswer': 'cancel',
      });
      expect(o.reasons, ['Car problem', 'Other']);
      expect([for (final d in o.drivers) (d.name, d.eligible, d.why)], [('Lee', true, null), ('Tan', false, 'Smaller vehicle')]);
      expect((o.answerMin, o.keepOnNoAnswer), (15, false));
    });
  });

  group('hotspots', () {
    test('hours, the best hours in words', () {
      expect(mygigHourLabel(0), '12 am');
      expect(mygigHourLabel(18), '6 pm');
      expect(mygigHourLabel(12), '12 pm');
      final counts = List<int>.filled(24, 0)..[18] = 9..[20] = 7..[8] = 7..[3] = 1;
      expect(mygigBestHours(counts), [18, 8, 20]);
      expect(mygigBestHoursText(counts), 'Busiest at 6 pm, 8 am and 8 pm.');
      expect(mygigBestHoursText(List<int>.filled(24, 0)), 'Not enough myGiG rides here on this day yet.');
    });

    test('the server''s counts', () {
      const h = MygigHotspots({
        'enabled': true,
        'weeks': 4,
        'areas': [{'name': 'Bangsar South', 'lat': 3.11, 'lng': 101.66, 'count': 21, 'nowCount': 4, 'km': 1.2}],
        'hours': [{'hour': 18, 'count': 9}, {'hour': 7, 'count': 2}],
      });
      expect(h.areas.single.name, 'Bangsar South');
      expect(h.hours.length, 24);
      expect((h.hours[18], h.hours[7], h.hours[0]), (9, 2, 0));
      expect(h.hasHours, isTrue);
      expect(const MygigHotspots({}).hasHours, isFalse);
    });
  });

  group('after the trip', () {
    test('a split: the others an even share, the first the rest, nothing lost', () {
      expect(mygigSplitShares(25.45, 2), [12.73, 12.72]);
      expect(mygigSplitShares(10, 3), [3.34, 3.33, 3.33]);
      for (final (owed, n) in [(25.45, 2), (10.0, 3), (7.01, 3), (100.0, 2)]) {
        expect(mygigSplitShares(owed, n).fold<double>(0, (a, b) => a + b), closeTo(owed, 0.001));
      }
      expect(mygigSplitShares(9, 1), [9]);
    });

    test('a tip', () {
      expect(mygigTipProblem(null, 100), 'Enter a tip.');
      expect(mygigTipProblem(0, 100), 'Enter a tip.');
      expect(mygigTipProblem(150, 100), 'The most tip is RM100.00.');
      expect(mygigTipProblem(5, 100), isNull);
    });

    test('e-Invoice details: a name, an email, and a TIN or an ID', () {
      expect(mygigEinvoiceProblem(name: '', email: 'a@b.co'), 'Enter the name on the invoice.');
      expect(mygigEinvoiceProblem(name: 'Siti', email: 'nope'), 'Enter an email address for the e-Invoice.');
      expect(mygigEinvoiceProblem(name: 'Siti', email: 'siti@example.com'), 'Enter your TIN, or your ID or passport number.');
      expect(mygigEinvoiceProblem(name: 'Siti', email: 'siti@example.com', tin: 'IG 12'), 'A TIN is 6 to 20 letters and numbers.');
      expect(mygigEinvoiceProblem(name: 'Siti', email: 'siti@example.com', tin: 'IG12345678'), isNull);
      expect(mygigEinvoiceProblem(name: 'Siti', email: 'siti@example.com', idType: 'nric', idNo: '900101145678'), isNull);
      expect(mygigEinvoiceSavedText, contains('LHDN MyInvois'));
      expect(mygigEinvoiceIdTypes.map((e) => e.$1), ['nric', 'passport', 'brn', 'army']);
    });

    test('the view: what the passenger may do; the app offer', () {
      const a = MygigAfter({
        'rideId': 'r1', 'status': 'completed', 'inApp': false,
        'driver': {'name': 'Hafiz'},
        'receipt': {'total': 27.45, 'tolls': 2, 'pay': 'link', 'paymentStatus': 'paid'},
        'can': {'rate': true, 'tip': true, 'split': false, 'einvoice': true, 'bookAgain': true},
        'tipMax': 50, 'splitMax': 5,
        'appOffer': {'code': 'HAFIZ5', 'coins': 5, 'enabled': true, 'driver': 'Hafiz'},
      });
      expect((a.completed, a.paid, a.total, a.tolls), (true, true, 27.45, 2.0));
      expect((a.canRate, a.canTip, a.canSplit, a.canEinvoice), (true, true, false, true));
      expect(a.tipPresets, [2.0, 5.0, 10.0]);
      expect(a.splitMax, 3, reason: 'never more than 3 people');
      expect(a.appOffer!.body, 'Sign up with Hafiz’s code HAFIZ5 and get 5 GET.coin. Book Hafiz or any driver, follow your rides and keep your receipts.');
    });
  });

  group('regulars and quick trips', () {
    test('a regular and its usual drop-off', () {
      final r = MygigRegular.of({'trips': 6, 'drop': {'name': 'KL Sentral', 'lat': 3.134, 'lng': 101.686}})!;
      expect((r.title, r.subtitle), ('Usually goes to KL Sentral', '6 myGiG rides with you'));
      expect(MygigRegular.of(null), isNull);
      expect(mygigSamePlace(3.1340, 101.6860, 3.1344, 101.6863), isTrue);
      expect(mygigSamePlace(3.134, 101.686, 3.140, 101.686), isFalse);
    });
  });

  group('the admin', () {
    test('the dashboard''s shares of how passengers accepted', () {
      const d = MygigDashboard({'tiles': {'viaApp': 46, 'viaLink': 38, 'viaHere': 16, 'takings': 3412}});
      expect((d.share(d.viaApp), d.share(d.viaLink), d.share(d.viaHere)), ('46%', '38%', '16%'));
      expect(const MygigDashboard({}).share(0), '0%');
    });

    test('the new settings parts and their fields', () {
      final parts = {for (final p in mygigParts) p.$1: p.$3};
      expect(parts.keys, containsAll(['reassign', 'hotspots', 'after', 'driverExtras']));
      for (final f in mygigFields.where((f) => ['reassign', 'hotspots', 'after', 'driverExtras'].contains(f.part))) {
        expect(parts[f.part], contains(f.path.split('.').first), reason: f.path);
      }
      expect(mygigFields.firstWhere((f) => f.path == 'reassign.when').choices.map((c) => c.$1), ['scheduled', 'before', 'during']);
      expect(mygigFields.firstWhere((f) => f.path == 'reassign.noAnswer').choices.map((c) => c.$1), ['keep', 'cancel']);
      expect(mygigFields.where((f) => f.path.toLowerCase().contains('absorb') || f.path.toLowerCase().contains('cover')), isEmpty);
    });

    test('the booking filters', () {
      expect(mygigBookingKinds.map((k) => k.$1), ['', 'trip', 'hourly', 'daily', 'weekly', 'monthly']);
      expect(mygigBookingStatuses.first.$1, 'open');
    });
  });

  test('part B follow-up: a late cancel of an in-app later trip shows its fee', () {
    final until = DateTime(2026, 10, 30, 12);
    final b = MygigBooking({'freeCancelUntil': until.toIso8601String(), 'lateFee': 5, 'keepIfCancelled': 0, 'plan': 'start'});
    expect(b.lateFee, 5);
    expect(b.cancelText(DateTime(2026, 10, 30, 13)), 'Cancelling now costs a RM5.00 cancellation fee');
    expect(const MygigBooking({}).cancelText(DateTime(2026, 10, 30)), 'Cancelling now is free');
  });

  test('the side menu''s myGiG hotspots row shows with myGiG', () {
    expect(defaultPartnerMenuItems.map((e) => e.$1), contains(mygigHotspotsMenuItemId));
    expect(partnerMenuRowShows(mygigHotspotsMenuItemId, obdLinked: false, hasMyRideCode: false), isFalse);
    expect(partnerMenuRowShows(mygigHotspotsMenuItemId, obdLinked: false, hasMyRideCode: false, mygig: true), isTrue);
  });

  test('push routes: the new driver, the passenger, the first driver', () {
    expect(pushRouteFor({'type': 'mygig_reassign_offer', 'reassign_id': 'ra 1', 'role': 'partner'}), '/drive/mygig/reassign/ra%201');
    expect(pushRouteFor({'type': 'mygig_reassign', 'reassign_id': 'ra1', 'role': 'rider'}), '/mygig/reassign/ra1');
    expect(pushRouteFor({'type': 'mygig_reassign', 'reassign_id': 'ra1', 'request_id': 'r1', 'role': 'partner'}),
        '/drive/mygig/reassign?ride=r1');
    expect(pushRouteFor({'type': 'mygig_reassign', 'reassign_id': 'ra1', 'booking_id': 'b1', 'role': 'partner'}),
        '/drive/mygig/reassign?booking=b1');
    expect(pushRouteFor({'type': 'mygig_reassign', 'role': 'partner'}), '/drive/mygig/scheduled');
  });
}
