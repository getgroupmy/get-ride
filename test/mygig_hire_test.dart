// myGiG part B (migration 0330): bookings for later and hire by time, the
// pure logic: lead times with the server's words, how a booking is paid
// (the owner's no-losses rule), what the app sends, a booking as Scheduled
// myGiG shows it, a hire's overtime, a booked day's money, and where it is
// wired in (the admin's parts, the menu row, the pushes, the module).
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart';
import 'package:get_ride/src/core/booking_modules.dart';
import 'package:get_ride/src/core/mygig.dart';
import 'package:get_ride/src/core/mygig_hire.dart';
import 'package:get_ride/src/core/push_logic.dart';
import 'package:get_ride/src/features/mygig/mygig_scheduled_screen.dart' show mygigEndHireLabel;
import 'package:get_ride/src/features/partner/partner_menu.dart';

const _s = MygigHireSettings({}, {});

void main() {
  final now = DateTime(2026, 10, 30, 9, 41);

  group('lead times', () {
    test('in words, as the server says them', () {
      expect(mygigLeadText(30), '30 min');
      expect(mygigLeadText(60), '1 hour');
      expect(mygigLeadText(720), '12 hours');
      expect(mygigLeadText(1440), '1 day');
      expect(mygigLeadText(2880), '2 days');
      expect(mygigLeadText(90), '1.5 hours');
    });

    test('the defaults: later ride 30 min, hourly 1 h, daily 12 h, weekly 24 h, monthly 48 h', () {
      expect([for (final k in MygigKind.values) _s.leadMin(k)], [30, 60, 720, 1440, 2880]);
    });

    test('a time passed, too soon, too far, fine', () {
      MygigBookingChoice at(MygigKind k, Duration d) => MygigBookingChoice(kind: k, later: true, at: now.add(d));
      expect(mygigWhenProblem(at(MygigKind.trip, const Duration(minutes: -5)), _s, now),
          'That time has passed. Choose a later time.');
      expect(mygigWhenProblem(at(MygigKind.trip, const Duration(minutes: 20)), _s, now),
          'A later ride must start at least 30 min from now.');
      expect(mygigWhenProblem(at(MygigKind.hourly, const Duration(minutes: 50)), _s, now),
          'Hourly hire must start at least 1 hour from now.');
      expect(mygigWhenProblem(at(MygigKind.daily, const Duration(hours: 11)), _s, now),
          'Daily hire must start at least 12 hours from now.');
      expect(mygigWhenProblem(at(MygigKind.weekly, const Duration(hours: 20)), _s, now),
          'Weekly hire must start at least 1 day from now.');
      expect(mygigWhenProblem(at(MygigKind.monthly, const Duration(hours: 47)), _s, now),
          'Monthly hire must start at least 2 days from now.');
      expect(mygigWhenProblem(at(MygigKind.trip, const Duration(days: 70)), _s, now), 'Bookings go up to 60 days ahead.');
      expect(mygigWhenProblem(at(MygigKind.trip, const Duration(hours: 2)), _s, now), isNull);
      expect(mygigWhenProblem(const MygigBookingChoice(kind: MygigKind.hourly), _s, now), isNull, reason: 'now');
      expect(mygigWhenProblem(const MygigBookingChoice(kind: MygigKind.daily), _s, now), 'Choose the start date and time.',
          reason: 'days always start later');
    });

    test('the admin switches later bookings off, or changes a lead time, per region', () {
      final s = MygigHireSettings.of({
        'later': {'enabled': false},
        'hire': {'leadMin': {'trip': 45}},
      });
      expect(s.leadMin(MygigKind.trip), 45);
      expect(mygigWhenProblem(MygigBookingChoice(later: true, at: now.add(const Duration(hours: 2))), s, now),
          'Bookings for later aren’t offered here.');
    });
  });

  group('how a booking is paid (no losses)', () {
    MygigPlan plan(MygigKind k, String pay, bool reg, {bool later = true, MygigHireSettings s = _s}) =>
        mygigPlanFor(MygigBookingChoice(kind: k, later: later), pay, registered: reg, s: s, total: 1000);

    test('now: as a myGiG ride', () {
      expect(plan(MygigKind.hourly, 'cash', false, later: false).kind, MygigPlanKind.now);
    });
    test('a later trip or hourly hire: in the app at the start, else by link first', () {
      expect(plan(MygigKind.trip, 'wallet', true).kind, MygigPlanKind.start);
      expect(plan(MygigKind.hourly, 'family', true).balanceByApp, isTrue);
      final l = plan(MygigKind.hourly, 'cash', false);
      expect((l.kind, l.payNow, l.payNowByLink), (MygigPlanKind.linkFirst, 1000.0, true));
      expect(plan(MygigKind.trip, 'wallet', false).kind, MygigPlanKind.linkFirst, reason: 'not registered: no in-app');
    });
    test('daily: the deposit, then the balance before day 1', () {
      final a = plan(MygigKind.daily, 'wallet', true);
      expect((a.kind, a.payNow, a.payNowByLink, a.balance, a.balanceByApp), (MygigPlanKind.deposit, 300.0, false, 700.0, true));
      final b = plan(MygigKind.daily, 'cash', false);
      expect((b.payNow, b.payNowByLink, b.balanceByApp), (300.0, true, false));
    });
    test('weekly and monthly: in full; business on the invoice', () {
      expect(plan(MygigKind.weekly, 'wallet', true).payNow, 1000);
      expect(plan(MygigKind.monthly, 'link', false).payNowByLink, isTrue);
      expect(plan(MygigKind.monthly, 'business', true).kind, MygigPlanKind.business);
    });
    test('not offered without in-app payment when the admin says so', () {
      const s = MygigHireSettings({}, {'nonApp': 'no'});
      expect(plan(MygigKind.daily, 'cash', false, s: s).problem,
          'Daily hire needs a registered passenger paying in the app (set by get.ride).');
      expect(plan(MygigKind.daily, 'wallet', true, s: s).problem, isNull);
      expect(plan(MygigKind.hourly, 'cash', false, s: s).problem, isNull, reason: 'link first, always');
    });
    test('no "pay day by day" and no "covers" setting', () {
      expect(MygigPlanKind.values.map((k) => k.name), isNot(contains('dayByDay')));
      expect(mygigFields.where((f) => f.path.toLowerCase().contains('cover')), isEmpty);
      expect(mygigFields.firstWhere((f) => f.path == 'hire.nonApp').choices.map((c) => c.$1), ['link', 'no']);
    });
    test('the payment box in plain words', () {
      final c = const MygigBookingChoice(kind: MygigKind.daily, later: true);
      final p = mygigPlanFor(c, 'cash', registered: false, s: _s, total: 1000);
      final text = mygigPlanText(c, p, _s, payName: 'Cash', balanceHow: 'in cash');
      expect(text.title, 'Deposit RM300.00 by link to confirm');
      expect(text.body, contains('The balance RM700.00 is paid before day 1 starts, in cash.'));
      expect(text.body, contains('Free to cancel until 24 h before the start; after that the deposit is kept.'));
      final w = mygigPlanText(const MygigBookingChoice(kind: MygigKind.weekly, later: true),
          mygigPlanFor(const MygigBookingChoice(kind: MygigKind.weekly, later: true), 'wallet', registered: true, s: _s, total: 1900),
          _s, payName: 'GET.wallet');
      expect(w.title, 'RM1900.00 in full when they accept');
      expect(w.body, contains('the payment is kept'));
    });
  });

  group('what the app sends', () {
    test('a later trip, an hourly hire now, a weekly hire', () {
      final at = DateTime.utc(2026, 11, 2, 0, 0);
      expect(MygigBookingChoice(later: true, at: at).toJson(), {'kind': 'trip', 'when': 'later', 'at': '2026-11-02T00:00:00.000Z'});
      expect(const MygigBookingChoice(kind: MygigKind.hourly, hours: 4).toJson(), {'kind': 'hourly', 'when': 'now', 'hours': 4.0});
      expect(MygigBookingChoice(kind: MygigKind.weekly, at: at, weekdays: const [1, 3, 5]).toJson(), {
        'kind': 'weekly', 'when': 'later', 'at': '2026-11-02T00:00:00.000Z', 'hoursPerDay': 10.0, 'periods': 1,
        'weekdays': [1, 3, 5],
      });
      expect(const MygigBookingChoice(kind: MygigKind.daily, days: 3, overnight: true).whatText,
          'Daily hire · 3 days, 10 h a day');
      expect(const MygigBookingChoice(kind: MygigKind.weekly).whatText, 'Weekly hire · 1 week, Mon to Fri, 10 h a day');
    });

    test('the packages the driver offers, which the admin allows', () {
      expect(mygigKindsOn(_s, const MygigHirePrefs({})), MygigKind.values);
      expect(mygigKindsOn(const MygigHireSettings({}, {'packages': {'weekly': false}}),
          const MygigHirePrefs({'offer': {'monthly': false}})), [MygigKind.trip, MygigKind.hourly, MygigKind.daily]);
      expect(mygigKindsOn(const MygigHireSettings({}, {'enabled': false}), const MygigHirePrefs({})), [MygigKind.trip]);
    });

    test('the hire card: the driver\'s own rates when allowed, get.ride\'s km', () {
      const own = MygigHirePrefs({'own': true, 'rates': {'hour': 45, 'day': 380}});
      expect(mygigHireCard(_s, own).hour, 45);
      expect(mygigHireCard(_s, own).kmDay, 200);
      expect(mygigHireCard(const MygigHireSettings({}, {'allowOwnRates': false}), own).hour, 40);
      expect(_s.dayHourChoices, [8, 10, 12]);
    });

    test('days, times and weekdays in words', () {
      expect(mygigDayText(DateTime(2026, 10, 30), now), 'Today');
      expect(mygigDayText(DateTime(2026, 10, 31), now), 'Tomorrow');
      expect(mygigDayText(DateTime(2026, 11, 2), now), 'Mon 2 Nov');
      expect(mygigClock(18 * 60 + 30), '6:30 pm');
      expect(mygigClock(0), '12:00 am');
      expect(mygigWeekdaysText([1, 2, 3, 4, 5]), 'Mon to Fri');
      expect(mygigWeekdaysText([1, 3, 5]), 'Mon, Wed, Fri');
      expect(mygigTimeChoices.length, 96);
    });
  });

  group('a booking', () {
    final b = MygigBooking({
      'id': 'b1', 'kind': 'daily', 'status': 'in_progress', 'days': 2, 'price': 1000, 'paid': 300, 'due': 700,
      'payNow': 300, 'plan': 'deposit', 'pay': 'cash', 'hoursPerDay': 10, 'linkOwed': 700,
      'freeCancelUntil': DateTime(2026, 10, 31, 8).toIso8601String(), 'keepIfCancelled': 300, 'dayText': 'Day 1 of 2',
      'trip': {'pickup': {'name': 'TTDI'}, 'drop': {'name': 'No drop-off · as directed'}, 'directed': true},
    });
    test('as Scheduled myGiG shows it', () {
      expect(b.whatText, 'Daily hire · 2 days, 10 h a day');
      expect(b.payText, 'RM300.00 paid, RM700.00 before day 1');
      expect(b.cancelText(now), 'Free to cancel until Tomorrow, 8:00 am');
      expect(b.cancelText(DateTime(2026, 11, 1)), 'Cancelling now keeps RM300.00 for the driver');
      expect(b.statusText, 'Going');
      expect(MygigBooking(const {'plan': 'business'}).payText, 'Monthly invoice');
      expect(MygigBooking(const {'status': 'awaiting_payment', 'linkOwed': 120}).payText, 'Waiting for RM120.00 by link');
      expect(MygigBooking(const {'plan': 'start', 'price': 20}).payText, 'Charged when the ride starts');
    });
    test('the driver\'s popup once accepted', () {
      expect(
        mygigBookedText(name: 'Ravi', booking: {'kind': 'weekly', 'at': DateTime(2026, 11, 2, 8).toIso8601String(),
            'plan': 'full', 'payNow': 1900, 'payNowBy': 'app'}, total: 1900, now: now),
        'Ravi · Weekly hire from Mon 2 Nov, 8:00 am, RM1900.00. RM1900.00 paid now. It is in your Scheduled myGiG, and you '
        'both get a reminder before.',
      );
      expect(
        mygigBookedText(name: 'Ben', booking: {'kind': 'hourly', 'plan': 'link_first', 'payNow': 120, 'payNowBy': 'link'},
            total: 120, now: now, status: 'awaiting_payment'),
        contains('It is confirmed once they pay RM120.00 by link'),
      );
    });
  });

  group('a hire\'s day', () {
    test('time used and overtime in the hire\'s steps', () {
      final h = mygigHireNow(startedAt: now.subtract(const Duration(hours: 10, minutes: 40)), hours: 10, stepMin: 30,
          overtimeRate: 45, now: now);
      expect((h.used, h.overtimeMin, h.overtime), ('10 h 40 min', 60, 45.0));
      expect(mygigHireNow(startedAt: null, hours: 3, stepMin: 30, overtimeRate: 45, now: now).overtimeMin, 0);
    });
    test('a booked day is paid from its booking; only what was added is owed', () {
      final r = MygigRide(const {
        'pay': 'cash', 'bookingId': 'b1', 'dayNo': 1, 'days': 2, 'prepaid': 300, 'cashPaid': 200,
        'quote': {'total': 500, 'approach': 12},
      });
      expect(r.paysFirst, isTrue);
      expect(r.owed, 0);
      expect(r.approachCashDue, 0, reason: 'coming to the pickup is in the booking\'s price');
      final end = MygigRide(const {
        'pay': 'wallet', 'bookingId': 'b1', 'prepaid': 500, 'quote': {'total': 500}, 'pendingFinal': {'due': 545},
      });
      expect(end.owed, 45);
      expect(MygigRide(const {'pay': 'business', 'bookingId': 'b1', 'quote': {'total': 500}}).owed, 0);
      expect(MygigRide(const {'pay': 'wallet', 'quote': {'total': 20}}).owed, 0, reason: 'part A: pays at the end');
    });
    test('the trip screen\'s button', () {
      expect(mygigEndHireLabel({'mygig': {'dayNo': 1, 'days': 5}}), 'End day 1 of 5');
      expect(mygigEndHireLabel({'mygig': {'dayNo': 5, 'days': 5}}), 'End hire');
      expect(mygigEndHireLabel({'mygig': {}}), 'End hire');
    });
  });

  group('wired in', () {
    test('the admin\'s parts: later bookings and hire by time, per region', () {
      expect(mygigParts.map((p) => p.$1), containsAll(['later', 'hire']));
      for (final f in mygigFields.where((f) => f.part == 'later' || f.part == 'hire')) {
        final keys = mygigParts.firstWhere((p) => p.$1 == f.part).$3;
        expect(keys, contains(f.path.split('.').first), reason: '${f.path} is in its part');
      }
      expect(mygigFields.map((f) => f.path),
          containsAll(['hire.packages.daily', 'hire.maxDays', 'hire.depositPct', 'hire.freeCancelHours.daily',
            'hire.leadMin.monthly', 'hire.allowOwnRates', 'hire.ownLimits.dayMax', 'later.enabled']));
    });
    test('Scheduled myGiG in the driver menu, with myGiG', () {
      expect(defaultPartnerMenuItems.map((e) => e.$1), contains(mygigScheduledMenuItemId));
      expect(partnerMenuRowShows(mygigScheduledMenuItemId, obdLinked: false, hasMyRideCode: false), isFalse);
      expect(partnerMenuRowShows(mygigScheduledMenuItemId, obdLinked: false, hasMyRideCode: false, mygig: true), isTrue);
    });
    test('the pushes open Scheduled myGiG or the passenger\'s scheduled rides', () {
      expect(pushRouteFor({'type': 'mygig_booking', 'role': 'partner'}), '/drive/mygig/scheduled');
      expect(pushRouteFor({'type': 'mygig_booking', 'role': 'rider'}), '/trips/scheduled');
      expect(pushRouteFor({'type': 'mygig_answer', 'booking_id': 'b1'}), '/drive/mygig/scheduled');
      expect(pushRouteFor({'type': 'mygig_answer', 'request_id': 'r1'}), '/drive/trip/r1');
    });
    test('the bookings are the myGiG module\'s', () {
      expect(bookingModule(familyModuleMygig)?.tables, contains('mygig_bookings'));
    });
  });
}
