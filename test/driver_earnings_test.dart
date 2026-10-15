import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/driver_earnings.dart';
import 'package:get_ride/src/data/models.dart';

RideRequest ride(
  String id, {
  String partner = 'me',
  String rider = 'r1',
  String status = 'completed',
  required DateTime completed,
  double fare = 20,
  double? tolls,
  double? commission,
  double? km,
}) => RideRequest({
  'id': id,
  'rider_id': rider,
  'partner_id': partner,
  'status': status,
  'fare': fare,
  'ride_fare': fare,
  'toll_charges': ?tolls,
  'commission_amount': ?commission,
  'distance_km': ?km,
  'currency': 'MYR',
  'created_at': completed.subtract(const Duration(minutes: 30)).toUtc().toIso8601String(),
  'completed_at': completed.toUtc().toIso8601String(),
});

void main() {
  // Thursday 15 October 2026, 18:00 local.
  final now = DateTime(2026, 10, 15, 18);

  test('periods start at midnight, on Monday, on the 1st', () {
    expect(earningsPeriodStart(EarningsPeriod.today, now), DateTime(2026, 10, 15));
    expect(earningsPeriodStart(EarningsPeriod.week, now), DateTime(2026, 10, 12));
    expect(earningsPeriodStart(EarningsPeriod.month, now), DateTime(2026, 10));
    // A Monday is its own week's start.
    expect(earningsPeriodStart(EarningsPeriod.week, DateTime(2026, 10, 12, 9)), DateTime(2026, 10, 12));
  });

  final rides = [
    ride('a', completed: DateTime(2026, 10, 15, 9), fare: 20, commission: 3, km: 8),
    ride('b', completed: DateTime(2026, 10, 15, 12), fare: 30, tolls: 2.5, commission: 4.5, km: 12.5),
    ride('c', completed: DateTime(2026, 10, 13, 22), fare: 15, commission: 2.25, km: 5),
    ride('d', completed: DateTime(2026, 10, 2, 8), fare: 50, commission: 7.5, km: 30),
    // Not counted: taken as a passenger, cancelled, before the month.
    ride('e', partner: 'someone', rider: 'me', completed: DateTime(2026, 10, 15, 10), fare: 99),
    ride('f', status: 'cancelled', completed: DateTime(2026, 10, 15, 11), fare: 99),
    ride('g', completed: DateTime(2026, 9, 30, 23), fare: 99),
  ];

  test('today: fares and tolls in, commission out', () {
    final s = summarizeEarnings(rides, driverId: 'me', period: EarningsPeriod.today, now: now);
    expect(s.totals.trips, 2);
    expect(s.totals.gross, 52.5);
    expect(s.totals.commission, 7.5);
    expect(s.totals.net, 45);
    expect(s.totals.distanceKm, 20.5);
    expect(s.days.single.date, DateTime(2026, 10, 15));
    expect(s.currency, 'MYR');
  });

  test('the week and month add up by day, newest first', () {
    final week = summarizeEarnings(rides, driverId: 'me', period: EarningsPeriod.week, now: now);
    expect(week.totals.trips, 3);
    expect([for (final d in week.days) d.date], [DateTime(2026, 10, 15), DateTime(2026, 10, 13)]);
    expect(week.days.last.totals.net, 12.75);

    final month = summarizeEarnings(rides, driverId: 'me', period: EarningsPeriod.month, now: now);
    expect(month.totals.trips, 4);
    expect(month.totals.net, 45 + 12.75 + 42.5);
    expect(month.days.map((d) => d.date.day), [15, 13, 2]);
  });

  test('a commission not yet charged leaves the whole fare', () {
    final s = summarizeEarnings(
      [ride('x', completed: DateTime(2026, 10, 15, 9), fare: 20)],
      driverId: 'me',
      period: EarningsPeriod.today,
      now: now,
    );
    expect(s.totals.net, 20);
  });

  test('nothing driven: zeros and no days', () {
    final s = summarizeEarnings(const [], driverId: 'me', period: EarningsPeriod.today, now: now);
    expect(s.totals.trips, 0);
    expect(s.totals.net, 0);
    expect(s.days, isEmpty);
  });

  group('trip history', () {
    test('history reaches back for the month and the eight weeks', () {
      expect(earningsHistoryStart(now), DateTime(2026, 8, 24));
      // With a short chart late in the month, the month start is the earlier.
      expect(earningsHistoryStart(DateTime(2026, 12, 31), weeks: 2), DateTime(2026, 12));
    });
  });

  group('CSV export', () {
    test('one row per trip of the period, oldest first, plain amounts', () {
      final csv = earningsCsv(rides, driverId: 'me', period: EarningsPeriod.today, now: now);
      final lines = csv.split('\r\n')..removeLast();
      expect(lines.first, startsWith('Date,Time,Booking no.,From,To'));
      expect(lines, hasLength(3));
      expect(lines[1], startsWith('2026-10-15,09:00,GR-'));
      expect(lines[1], endsWith(',8.0,20.00,3.00,17.00,MYR'));
      expect(lines[2], endsWith(',12.5,32.50,4.50,28.00,MYR'));
    });

    test('nothing in the period: the header alone', () {
      final csv = earningsCsv(const [], driverId: 'me', period: EarningsPeriod.month, now: now);
      expect(csv.split('\r\n').where((l) => l.isNotEmpty), hasLength(1));
    });

    test('fields are quoted, and never run as a formula', () {
      expect(csvField('Jalan Ampang, KL'), '"Jalan Ampang, KL"');
      expect(csvField('say "hi"'), '"say ""hi"""');
      expect(csvField('=HYPERLINK("x")'), '"\'=HYPERLINK(""x"")"');
      expect(csvField('-12.50'), '-12.50');
      expect(csvField('plain'), 'plain');
    });

    test('file names say which period', () {
      expect(earningsCsvFileName(EarningsPeriod.week, now), 'earnings-this-week-2026-10-12.csv');
      expect(earningsCsvFileName(EarningsPeriod.today, now), 'earnings-today-2026-10-15.csv');
    });
  });
}
