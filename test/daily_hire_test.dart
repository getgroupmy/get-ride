// Daily hire (migration 0327), the pure parts: the settings as the server
// keeps them, the quote, each day's amount and the totals the review shows
// (as ride_amount_due works them out), a booking, the labels and the hourly
// gaps fixed with it (cash turned off later, whole fares, a hire day's ride).
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/hourly_hire.dart';
import 'package:get_ride/src/core/multi_day_hire.dart';
import 'package:get_ride/src/core/region_pricing.dart';
import 'package:get_ride/src/core/scheduled_rides.dart';
import 'package:get_ride/src/features/ride/hire_parts.dart' show hireBase, hireTotal;
import 'package:get_ride/src/features/ride/multi_hire_parts.dart' show defaultFirstDay;

MultiHireQuote _quote({bool overnight = false, double perDay = 300, int days = 3}) => MultiHireQuote.fromJson({
  'available': true,
  'package': 'daily',
  'title': 'Daily hire',
  'days': days,
  'hours': 10,
  'dayRate': 300,
  'dayHours': 10,
  'perDay': perDay,
  'kmPerDay': 150,
  'overtimePerHour': 45,
  'extraKm': 1.5,
  'overnight': overnight,
  'nights': overnight ? days - 1 : 0,
  'overnightAllowance': 80,
  'mealAllowance': 20,
  'placeFees': [
    {'name': 'Plaza pickup fee', 'value': 5},
  ],
  'placeFeesPerDay': 5,
  'base': perDay * days,
  'total': 1135,
  'depositPercent': 30,
  'allowPrepay': true,
  'freeCancelUntil': '2026-11-01T01:00:00Z',
  'dates': ['2026-11-02T01:00:00Z', '2026-11-03T01:00:00Z', '2026-11-04T01:00:00Z'],
});

void main() {
  group('settings', () {
    test('the defaults, as the server keeps them', () {
      final c = MultiHireConfig.fromJson('daily', const {});
      expect(c.enabled, isFalse);
      expect(c.maxDays, 6);
      expect((c.minHoursPerDay, c.maxHoursPerDay, c.hoursPerDayDefault), (8, 12, 10));
      expect((c.leadHours, c.depositPercent, c.freeCancelHours), (12, 30, 24));
      expect(c.lateCancel, HireLateCancel.deposit);
      expect((c.sameDriverDefault, c.splitDays, c.splitAfterHours), (true, true, 6));
      expect((c.overnightAllowance, c.mealAllowance), (50, 0));
      expect((c.chipLabel, c.title), ('Daily', 'Daily hire'));
    });

    test('kept within the safe limits, round trip', () {
      final c = MultiHireConfig.fromJson('daily', {
        'enabled': true,
        'maxDays': 99,
        'minHoursPerDay': 9.3,
        'maxHoursPerDay': 2,
        'depositPercent': 130,
        'lateCancelMode': 'first_day',
        'labels': {'chip': '', 'title': 'Day hire'},
      });
      expect(c.maxDays, 60);
      expect(c.minHoursPerDay, 9.5);
      expect(c.maxHoursPerDay, 9.5);
      expect(c.depositPercent, 100);
      expect(c.lateCancel, HireLateCancel.firstDay);
      expect((c.chipLabel, c.title), ('Daily', 'Day hire'));
      final again = MultiHireConfig.fromJson('daily', c.toJson());
      expect(again.toJson(), c.toJson());
    });

    test('hours in half hours, days within the most, the first day', () {
      const c = MultiHireConfig(minHoursPerDay: 8, maxHoursPerDay: 10);
      expect(c.hourChoices, [8, 8.5, 9, 9.5, 10]);
      expect(c.clampHours(13), 10);
      expect(c.clampHours(8.3), 8.5);
      expect(c.clampDays(9), 6);
      final now = DateTime(2026, 11, 1, 10);
      expect(c.firstDayProblem(DateTime(2026, 11, 1, 20), now), 'Book at least 12 hours ahead.');
      expect(c.firstDayProblem(DateTime(2026, 12, 15, 9), now), 'Book up to 30 days ahead.');
      expect(c.firstDayProblem(DateTime(2026, 11, 3, 9), now), isNull);
      expect(defaultFirstDay(now, 12), DateTime(2026, 11, 2, 9));
      expect(defaultFirstDay(DateTime(2026, 11, 1, 6), 2), DateTime(2026, 11, 1, 9));
    });
  });

  group('the price', () {
    test('a day: the day price, its place fee, the meal, the night away', () {
      final q = _quote(overnight: true);
      final d1 = multiHireDay(q, RegionPricing.none, 1);
      final d3 = multiHireDay(q, RegionPricing.none, 3);
      expect((d1.base, d1.fees, d1.allowances, d1.total), (300, 5, 100, 405));
      expect((d3.allowances, d3.total), (20, 325), reason: 'no night after the last day');
    });

    test('the totals as the server charges them: deposit now, the rest on day 1', () {
      final q = _quote(overnight: true);
      final deposit = multiHireTotals(q, RegionPricing.none, HirePayPlan.deposit);
      expect((deposit.total, deposit.payNow, deposit.balance), (1135, 340.5, 794.5));
      final prepay = multiHireTotals(q, RegionPricing.none, HirePayPlan.prepay);
      expect((prepay.payNow, prepay.balance), (1135, 0));
      final business = multiHireTotals(q, RegionPricing.none, HirePayPlan.business);
      expect((business.payNow, business.balance), (0, 0));
    });

    test('a region\'s tax on every day, on the fare and its fixed charges', () {
      final q = _quote();
      const pricing = RegionPricing(tax: RegionTax(name: 'SST', kind: TaxKind.percent, value: 10));
      final x = multiHireTotals(q, pricing, HirePayPlan.deposit);
      // Each day: 300 + 5 + 20, the tax on the fare (30): 355; three days 1065.
      expect(x.total, 1065);
      expect(x.lines.keys.single, contains('SST'));
    });

    test('a whole-fare region rounds the day price up, as a ride\'s fare', () {
      final q = _quote(perDay: 299.7, days: 1);
      expect(multiHireDay(q, const RegionPricing(wholeFare: true), 1).base, 300);
      const h = HireQuote(available: true, hours: 3, base: 120.75, placeFeesTotal: 0);
      expect(hireBase(h, wholeFare: true), 121);
      expect(hireTotal(h, const [], wholeFare: true), 121);
      expect(hireTotal(h, const []), 120.75);
    });
  });

  group('a booking', () {
    test('read from its row, with its payment in plain words', () {
      final b = HireDaysBooking.fromRow({
        'id': 'b1',
        'package': 'daily',
        'service': 'Saloon',
        'status': 'booked',
        'first_at': '2026-11-02T01:00:00Z',
        'days': 3,
        'hours_per_day': 10,
        'same_driver': true,
        'payment_plan': 'deposit',
        'payment_state': 'deposit_paid',
        'price': 1135,
        'deposit_amount': 340.5,
        'balance_amount': 794.5,
        'paid_amount': 340.5,
        'quote': {'title': 'Daily hire'},
      });
      String money(double v) => 'RM ${v.toStringAsFixed(2)}';
      expect(b.title, 'Daily hire');
      expect(b.open, isTrue);
      expect(b.statusLabel, 'Finding a driver for every day');
      expect(b.paymentText(money), 'Deposit RM 340.50 paid, RM 794.50 on day 1');
      expect(HireDaysBooking.fromRow({'id': 'x', 'status': 'booked', 'same_driver': false}).statusLabel,
          'Finding a driver for each day');
      expect(HireDaysBooking.fromRow({'id': 'x', 'status': 'cancelled'}).open, isFalse);
    });

    test('a whole booking a driver can take, with its days', () {
      final o = OpenHireBooking.fromRow({
        'id': 'b1',
        'title': 'Daily hire',
        'service': 'Saloon',
        'first_at': '2026-11-02T01:00:00Z',
        'days': 2,
        'hours_per_day': 10,
        'fare': 600,
        'day_list': [
          {'day': 1, 'pickup_at': '2026-11-02T01:00:00Z', 'fare': 300},
          {'day': 2, 'pickup_at': '2026-11-03T01:00:00Z', 'fare': 300},
        ],
      });
      expect(o.dayList.map((d) => d.day), [1, 2]);
      expect(o.fare, 600);
    });

    test('a day of a booking on the lists and on its ride', () {
      final day = ScheduledRide.fromRow({
        'id': 's1',
        'pickup_at': '2026-11-03T01:00:00Z',
        'status': 'assigned',
        'fare': 300,
        'hire_package': 'daily',
        'hire_hours': 10,
        'hire_booking_id': 'b1',
        'hire_day_no': 2,
        'hire_days': 3,
        'hire_title': 'Daily hire',
      });
      expect(day.isHireDay, isTrue);
      expect(day.hireDayLabel, 'Daily hire · day 2 of 3');
      final ride = RideHire.fromRow({
        'hire_package': 'daily',
        'hire_hours': 10,
        'hire_day_no': 2,
        'hire_quote': {'title': 'Daily hire', 'days': 3},
      })!;
      expect(ride.isDay, isTrue);
      expect(ride.heading, 'Daily hire · day 2 of 3');
      expect(ride.lines(300).single.label, 'Daily hire · day 2 of 3');
      expect(RideHire.fromRow({'hire_package': 'hourly', 'hire_hours': 4})!.heading, 'Hourly hire · 4 hr');
    });

    test('the dates, the span and the late cancel in plain words', () {
      expect(hireDailyDates(DateTime(2026, 11, 30, 9), 3),
          [DateTime(2026, 11, 30, 9), DateTime(2026, 12, 1, 9), DateTime(2026, 12, 2, 9)]);
      expect(hireBookingSpan(DateTime(2026, 11, 2, 9), 3, 10), '3 days from Mon 2 Nov, 9:00 am · 10 hr a day');
      expect(hireDayText(2, 3), 'Day 2 of 3');
      expect(hireLateCancelText(const MultiHireConfig()), 'After that the deposit is kept.');
      expect(hireLateCancelText(const MultiHireConfig(lateCancel: HireLateCancel.percent, lateCancelPercent: 10)),
          'After that 10% of the price is kept.');
      expect(hireFreeCancelUntil(DateTime(2026, 11, 2, 9), 24), DateTime(2026, 11, 1, 9));
    });

    test('the server\'s refusals in plain words', () {
      expect(hireRefusalText('HIRE_WHOLE_BOOKING'), contains('all its days'));
      expect(hireRefusalText('HIRE_BOOKING_CANCEL'), contains('cancelled together'));
      expect(hireRefusalText('HIRE_LEAD'), 'Choose a later first day.');
      expect(hireRefusalText('HIRE_BUSINESS'), "This hire can't be charged to a business account.");
    });
  });

  group('hourly gaps', () {
    test('cash turned off after a cash booking: as the admin says', () {
      expect(HourlyHireConfig.fromJson(const {}).cashOffLater, HireCashOffLater.cash);
      final c = HourlyHireConfig.fromJson({'cashOffLater': 'cancel'});
      expect(c.cashOffLater, HireCashOffLater.cancel);
      expect(HourlyHireConfig.fromJson(c.toJson()).cashOffLater, HireCashOffLater.cancel);
      expect(HourlyHireConfig.fromJson({'cashOffLater': 'x'}).cashOffLater, HireCashOffLater.cash);
    });

    test('the pickup time sheet says the lead in hours or days', () {
      expect(pickupLeadText(30), '30 minutes');
      expect(pickupLeadText(720), '12 hours');
      expect(pickupLeadText(4320), '3 days');
      expect(pickupLeadText(90), '90 minutes');
    });
  });
}
