// Hourly hire (migration 0326), the app's sums: the settings as the server
// keeps them, the quote, the hire on a ride, the extension amount and the
// settled breakdown (the same numbers as supabase/tests/hourly_hire_0326.sql),
// the labels, the refusals, the home tile target and the Family module.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart' show allAppRoutes, routeLabel;
import 'package:get_ride/src/core/booking_modules.dart';
import 'package:get_ride/src/core/hourly_hire.dart';
import 'package:get_ride/src/core/scheduled_rides.dart';
import 'package:get_ride/src/core/trip_receipt.dart';
import 'package:get_ride/src/data/models.dart';

String rm(double v) => 'RM ${v.toStringAsFixed(2)}';

void main() {
  group('settings', () {
    test('defaults, as hourly_hire_normalize keeps them', () {
      final c = HourlyHireConfig.fromJson(const {});
      expect(c.enabled, isFalse);
      expect(c.allowNow && c.allowLater, isTrue);
      expect([c.minHours, c.maxHours, c.hourStep], [2, 12, 1]);
      expect(c.stepMinutes, 30);
      expect(c.extendChoices, [30, 60, 120]);
      expect(c.extendNeedsRider && c.riderCanEndEarly && c.holdInWallet, isTrue);
      expect(c.earlyEndPays, HireEarlyEndPays.booked);
      expect(c.allowCash, isFalse);
      expect(c.kmPerHourDefault, 20);
      expect([c.reminderBeforeEndMin, c.autoEndAfterMin], [15, 30]);
      expect([c.tileTitle, c.tripLabel, c.hireLabel], ['Hire a driver', 'Go somewhere', 'Hire by time']);
      expect(HourlyHireConfig.fromJson(null).bookable, isFalse);
    });

    test('kept within the safe limits, and read back the same', () {
      final c = HourlyHireConfig.fromJson(const {
        'enabled': true,
        'minHours': 1.2,
        'maxHours': 99,
        'hourStep': 0.5,
        'extendChoices': [120, 30, 1, 30, 'x'],
        'earlyEndPays': 'minimum',
        'holdBufferPercent': 300,
        'tileTitle': '',
        'panelLabels': {'trip': 'Ride', 'hire': 'By the hour'},
      });
      expect(c.minHours, 1.5);
      expect(c.maxHours, 72);
      expect(c.hourStep, 0.5);
      expect(c.extendChoices, [30, 120]);
      expect(c.earlyEndPays, HireEarlyEndPays.minimum);
      expect(c.holdBufferPercent, 100);
      expect(c.tileTitle, 'Hire a driver');
      expect([c.tripLabel, c.hireLabel], ['Ride', 'By the hour']);
      final back = HourlyHireConfig.fromJson(c.toJson());
      expect(back.toJson(), c.toJson());
      expect(HourlyHireConfig.fromJson(const {'hourStep': 0.3}).hourStep, 1);
    });

    test('the hours the stepper offers', () {
      const c = HourlyHireConfig(minHours: 2, maxHours: 4, hourStep: 0.5);
      expect(c.hourChoices, [2, 2.5, 3, 3.5, 4]);
      expect(c.clampHours(1), 2);
      expect(c.clampHours(3.3), 3.5);
      expect(c.clampHours(9), 4);
    });
  });

  group('the quote', () {
    final q = HireQuote.fromJson(const {
      'available': true,
      'hours': 4,
      'rate': 40,
      'kmIncluded': 60,
      'overtimePerHour': 50,
      'stepMinutes': 30,
      'extraKm': 1.2,
      'base': 160,
      'placeFees': [
        {'name': 'Plaza pickup fee', 'value': 5},
      ],
      'placeFeesTotal': 5,
      'total': 165,
      'hold': 165,
    });

    test('read as the server sends it', () {
      expect(q.available, isTrue);
      expect(q.base, 160);
      expect(q.placeFees.single, (name: 'Plaza pickup fee', amount: 5.0));
      expect(q.total, 165);
    });

    test('the card and terms lines', () {
      expect(hireRateLine(q, rm), 'RM 40.00 / hr · 60 km included');
      expect(hireTermsLine(q, rm), 'Overtime RM 50.00 / hr, extra km RM 1.20 / km, fuel included');
      expect(HireQuote.fromJson(const {'available': false, 'reason': 'HIRE_CASH', 'hint': 'Pay in the app'}).hint,
          'Pay in the app');
    });
  });

  group('labels', () {
    test('hours and minutes', () {
      expect(hireHoursText(4), '4 hr');
      expect(hireHoursText(1.5), '1.5 hr');
      expect(hireMinutesText(30), '30 min');
      expect(hireMinutesText(60), '1 hr');
      expect(hireMinutesText(90), '1 hr 30 min');
      expect(hireTitle(4), 'Hourly hire · 4 hr');
    });

    test('a booking for later shows its span', () {
      expect(hireSpanText(4, DateTime(2026, 11, 2, 9)), 'Hourly hire · 4 hr, 9:00 am to 1:00 pm');
      final s = ScheduledRide.fromRow({
        'id': 's1',
        'pickup_at': DateTime(2026, 11, 2, 9).toUtc().toIso8601String(),
        'status': 'scheduled',
        'fare': 160,
        'hire_package': 'hourly',
        'hire_hours': 4,
      });
      expect(s.isHire, isTrue);
      expect(s.hireHours, 4);
      expect(ScheduledRide.fromRow({'id': 's2', 'status': 'scheduled', 'hire_hours': 4}).isHire, isFalse);
      // The drivers' lists (scheduled_rides_open / _upcoming / _offers_open)
      // carry 0325's place_fees and the hire columns together.
      final listed = UpcomingBooking.fromRow({
        'id': 's3',
        'pickup_at': DateTime(2026, 11, 2, 9).toUtc().toIso8601String(),
        'fare': 160,
        'place_fees': [
          {'kind': 'surcharge', 'name': 'Plaza pickup fee', 'charge': 'fixed', 'value': 5, 'airport': 'pick',
           'place_fee': 'f1', 'locked': true},
        ],
        'hire_package': 'hourly',
        'hire_hours': 3,
      }).ride;
      expect(listed.hireHours, 3);
      expect(listed.placeFees, hasLength(1));
      expect(listed.total, 165);
    });

    test('a refusal in plain words', () {
      expect(hireRefusalText('HIRE_CASH'), 'Hourly hire is paid in the app. Choose GET.wallet.');
      expect(hireRefusalText('HIRE_BALANCE'), contains('Top up'));
      expect(hireRefusalText('something else'), isNull);
      expect(hireEarlyEndText(HireEarlyEndPays.minimum, 2), 'Ending early pays the hours used, at least 2 hr.');
    });
  });

  group('overtime and the end', () {
    test('overtime is charged per started step', () {
      expect(hireOvertimeAmount(30, 30, 50), 25);
      expect(hireOvertimeAmount(31, 30, 50), 50);
      expect(hireOvertimeAmount(1, 30, 50), 25);
      expect(hireOvertimeAmount(0, 30, 50), 0);
      expect(hireOvertimeAmount(45, 15, 60), 45);
    });

    final started = DateTime(2026, 11, 2, 9);
    Map<String, dynamic> row({List<Map<String, dynamic>> ext = const []}) => {
      'hire_package': 'hourly',
      'hire_hours': 4,
      'hire_rate': 40,
      'hire_km_included': 60,
      'hire_overtime_rate': 50,
      'hire_step_min': 30,
      'hire_extra_km_rate': 1.2,
      'hire_quote': {'kmPerHour': 15, 'minHours': 2, 'hourStep': 1, 'placeFeesTotal': 5},
      'hire_started_at': started.toUtc().toIso8601String(),
      'hire_ends_at': started.add(const Duration(hours: 6)).toUtc().toIso8601String(),
      'hire_extensions': ext,
    };

    test('a hire on a ride row; none on a normal ride', () {
      expect(RideHire.fromRow(const {'id': 'r'}), isNull);
      final h = RideHire.fromRow(row(ext: [
        {'id': 'e1', 'minutes': 30, 'amount': 25, 'asked_by': 'driver', 'status': 'approved'},
        {'id': 'e2', 'minutes': 60, 'amount': 50, 'asked_by': 'driver', 'status': 'declined'},
        {'id': 'e3', 'minutes': 60, 'amount': 50, 'asked_by': 'rider', 'status': 'approved'},
        {'id': 'e4', 'minutes': 30, 'amount': 25, 'asked_by': 'driver', 'status': 'pending'},
      ]))!;
      expect(h.approvedMinutes, 90);
      expect(h.totalMinutes, 330);
      expect(h.pending?.id, 'e4');
      expect(h.extensionAmount(30), 25);
      expect(h.usedText(started.add(const Duration(minutes: 80))), '1 hr 20 min of 5 hr 30 min');
    });

    test('settled as the server does: overtime in steps up to what was approved, extra km', () {
      final h = RideHire.fromRow(row(ext: [
        {'id': 'e1', 'minutes': 30, 'amount': 25, 'asked_by': 'driver', 'status': 'approved'},
        {'id': 'e3', 'minutes': 60, 'amount': 50, 'asked_by': 'rider', 'status': 'approved'},
        {'id': 'e5', 'minutes': 30, 'amount': 25, 'asked_by': 'driver', 'status': 'approved'},
      ]))!;
      // Five hours ten minutes: 70 past four, billed as 90; km included 60 + 2 × 15.
      final s = h.settle(at: started.add(const Duration(hours: 5, minutes: 10)), km: 102.5);
      expect(s.base, 160);
      expect(s.overtimeMinutes, 90);
      expect(s.overtime, 75);
      expect(s.extraKm, 12.5);
      expect(s.extraKmAmount, 15);
      expect(s.fare, 250);
      expect(s.early, isFalse);
    });

    test('an early end, each way it may pay', () {
      final h = RideHire.fromRow(row())!;
      final at = started.add(const Duration(hours: 1));
      expect(h.settle(at: at).fare, 160);
      expect(h.settle(at: at, pays: HireEarlyEndPays.minimum).fare, 80);
      expect(h.settle(at: at, pays: HireEarlyEndPays.used).fare, 40);
      expect(h.settle(at: at).early, isTrue);
    });

    test('the receipt and the admin read the settled lines', () {
      final r = RideRequest({
        'id': '00000000-0000-0000-0000-000000000326',
        'status': 'completed',
        'fare': 250,
        'ride_fare': 250,
        'currency': 'MYR',
        ...row(),
        'hire_settled': {
          'fare': 250,
          'lines': [
            {'label': 'Hourly hire 4 hr', 'amount': 160},
            {'label': 'Overtime 90 min', 'amount': 75},
            {'label': 'Extra km 12.5 km', 'amount': 15},
          ],
        },
      });
      final lines = TripReceipt.fromRide(r).lines;
      expect(lines.take(3).map((l) => l.label), ['Hourly hire 4 hr', 'Overtime 90 min', 'Extra km 12.5 km']);
      final d = hireAdminDetails(RideHire.fromRow(r.raw)!, rm);
      expect(d['Hourly hire'], '4 hr at RM 40.00 / hr, 60 km included');
      expect(d['Hire settled'], 'Hourly hire 4 hr RM 160.00 · Overtime 90 min RM 75.00 · Extra km 12.5 km RM 15.00');
      // Before it is settled: the booked hours at the fare.
      expect(RideHire.fromRow(row())!.lines(160), [(label: 'Hourly hire 4 hr', amount: 160.0)]);
    });
  });

  test('the home tile target and the Family module', () {
    expect(allAppRoutes, contains(hireTileRoute));
    expect(routeLabel(hireTileRoute), 'Hire a driver — opens Hire by time');
    expect(rideBookingModule(hire: true, scheduled: true), 'hire');
    expect(bookingModule('hire')?.name, 'Hire');
    expect(bookingModule('hire')?.tables, ['ride_requests', 'hire_bookings']);
  });
}
