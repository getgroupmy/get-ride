// The admin dashboard's periods (Malaysia's days, Monday weeks, the same
// length before), its answers, the change against the previous period and
// whether it is good news (lib/src/core/admin_dashboard.dart). Pure.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/admin_dashboard.dart';

DateTime _myt(int y, int m, int d, [int h = 0, int min = 0]) => DateTime.utc(y, m, d, h, min).subtract(const Duration(hours: 8));

void main() {
  // Wednesday 21 October 2026, 10:30 in Kuala Lumpur (02:30 UTC).
  final now = _myt(2026, 10, 21, 10, 30);

  group('periods', () {
    test('today runs from Malaysian midnight to now, against yesterday to the same time', () {
      final r = dashboardRange(DashboardPeriod.today, now);
      expect(r.from, DateTime.utc(2026, 10, 20, 16));
      expect(r.to, now);
      expect(r.prevFrom, DateTime.utc(2026, 10, 19, 16));
      expect(r.prevTo, now.subtract(const Duration(days: 1)));
      expect(r.bucket, DashboardBucket.hour);
      expect(r.oneDay, isTrue);
      expect(r.axisSlots(11), 24);
      expect(r.first, DateTime.utc(2026, 10, 21));
    });

    test("Malaysia's day, not UTC's: 07:00 on the 21st in KL is still the 20th in UTC", () {
      final early = _myt(2026, 10, 21, 7);
      expect(early.day, 20);
      final r = dashboardRange(DashboardPeriod.today, early);
      expect(r.first, DateTime.utc(2026, 10, 21));
      expect(r.from, DateTime.utc(2026, 10, 20, 16));
      // A minute before midnight in KL is still the 20th there.
      final late = _myt(2026, 10, 20, 23, 59);
      expect(dashboardRange(DashboardPeriod.today, late).first, DateTime.utc(2026, 10, 20));
    });

    test('just after midnight the period still spans a moment', () {
      final r = dashboardRange(DashboardPeriod.today, _myt(2026, 10, 21));
      expect(r.to.isAfter(r.from), isTrue);
      expect(r.prevTo.difference(r.prevFrom), r.to.difference(r.from));
    });

    test('yesterday against the day before', () {
      final r = dashboardRange(DashboardPeriod.yesterday, now);
      expect(r.from, _myt(2026, 10, 20));
      expect(r.to, _myt(2026, 10, 21));
      expect(r.prevFrom, _myt(2026, 10, 19));
      expect(r.prevTo, _myt(2026, 10, 20));
      expect(r.bucket, DashboardBucket.hour);
    });

    test('this week starts on Monday and is compared with the same days and time of last week', () {
      final r = dashboardRange(DashboardPeriod.week, now);
      expect(r.first, DateTime.utc(2026, 10, 19)); // Monday
      expect(r.from, _myt(2026, 10, 19));
      expect(r.to, now);
      expect(r.prevFrom, _myt(2026, 10, 12));
      expect(r.prevTo, _myt(2026, 10, 14, 10, 30));
      expect(r.bucket, DashboardBucket.day);
      expect(r.axisSlots(3), 7);
      // On a Sunday the week began six days before.
      final sunday = dashboardRange(DashboardPeriod.week, _myt(2026, 10, 25, 9));
      expect(sunday.first, DateTime.utc(2026, 10, 19));
      // On a Monday it began that day.
      final monday = dashboardRange(DashboardPeriod.week, _myt(2026, 10, 19, 9));
      expect(monday.first, DateTime.utc(2026, 10, 19));
    });

    test('this month against the same days of last month', () {
      final r = dashboardRange(DashboardPeriod.month, now);
      expect(r.from, _myt(2026, 10, 1));
      expect(r.prevFrom, _myt(2026, 9, 1));
      expect(r.prevTo, _myt(2026, 9, 21, 10, 30));
      expect(r.prevTo.difference(r.prevFrom), r.to.difference(r.from));
      expect(r.bucket, DashboardBucket.day);
    });

    test('a long month against a short one stops at the end of the short one', () {
      final r = dashboardRange(DashboardPeriod.month, _myt(2026, 3, 31, 12));
      expect(r.prevFrom, _myt(2026, 2, 1));
      expect(r.prevTo, _myt(2026, 3, 1));
      // January against December crosses the year.
      final jan = dashboardRange(DashboardPeriod.month, _myt(2026, 1, 10, 12));
      expect(jan.prevFrom, _myt(2025, 12, 1));
    });

    test('custom: whole days, either order, against as many days just before', () {
      final r = dashboardRange(
        DashboardPeriod.custom,
        now,
        first: DateTime(2026, 10, 21),
        last: DateTime(2026, 10, 1),
      );
      expect(r.first, DateTime.utc(2026, 10, 1));
      expect(r.last, DateTime.utc(2026, 10, 21));
      expect(r.days, 21);
      expect(r.from, _myt(2026, 10, 1));
      expect(r.to, _myt(2026, 10, 22));
      expect(r.prevTo, r.from);
      expect(r.prevFrom, _myt(2026, 9, 10));
      expect(r.prevTo.difference(r.prevFrom), r.to.difference(r.from));
      expect(r.bucket, DashboardBucket.day);
      expect(r.axisSlots(21), 21);
    });

    test('a one-day custom period is hourly, and a long one is capped', () {
      final one = dashboardRange(DashboardPeriod.custom, now, first: DateTime(2026, 5, 5), last: DateTime(2026, 5, 5));
      expect(one.bucket, DashboardBucket.hour);
      expect(one.prevFrom, _myt(2026, 5, 4));
      final long = dashboardRange(DashboardPeriod.custom, now, first: DateTime(2020, 1, 1), last: DateTime(2026, 10, 21));
      expect(long.days, dashboardMaxDays);
    });

    test('the range line', () {
      expect(
        dashboardRangeText(dashboardRange(DashboardPeriod.today, now), now),
        'Wed 21 Oct 2026, 00:00 to 10:30 · compared with yesterday to 10:30',
      );
      expect(
        dashboardRangeText(dashboardRange(DashboardPeriod.yesterday, now), now),
        'Tue 20 Oct 2026 · compared with Mon 19 Oct',
      );
      expect(
        dashboardRangeText(dashboardRange(DashboardPeriod.week, now), now),
        'Mon 19 to Wed 21 Oct 2026 · compared with the same days last week',
      );
      expect(
        dashboardRangeText(dashboardRange(DashboardPeriod.month, now), now),
        '1 to 21 Oct 2026 · compared with 1 to 21 Sep',
      );
      final custom = dashboardRangeText(
        dashboardRange(DashboardPeriod.custom, now, first: DateTime(2026, 10, 1), last: DateTime(2026, 10, 21)),
        now,
      );
      expect(custom, endsWith(' · compared with the 21 days before'));
      expect(custom, isNot(contains('→')));
    });

    test('axis labels: hours, weekdays, days', () {
      expect(dashboardSlotLabel(dashboardRange(DashboardPeriod.today, now), 9), '09:00');
      expect(dashboardSlotLabel(dashboardRange(DashboardPeriod.week, now), 0), 'Mon');
      expect(dashboardSlotLabel(dashboardRange(DashboardPeriod.month, now), 20), '21 Oct');
    });

    test('the chosen period round-trips', () {
      final c = DashboardChoice(DashboardPeriod.custom, first: DateTime(2026, 10, 1), last: DateTime(2026, 10, 7));
      expect(DashboardChoice.fromJson(c.toJson()), c);
      expect(DashboardChoice.fromJson(const DashboardChoice(DashboardPeriod.week).toJson()).period, DashboardPeriod.week);
      expect(DashboardChoice.fromJson({'period': 'custom'}), DashboardChoice.initial);
      expect(DashboardChoice.fromJson('junk'), DashboardChoice.initial);
    });
  });

  group('change against the previous period', () {
    test('counts and money: relative, up is good', () {
      final d = DashboardDelta.of(108.4, 100)!;
      expect(d.text, '▲ 8.4%');
      expect(d.tone, DeltaTone.good);
      final down = DashboardDelta.of(7, 8)!;
      expect(down.text, '▼ 12.5%');
      expect(down.tone, DeltaTone.bad);
      expect(DashboardDelta.of(5, 5)!.tone, DeltaTone.flat);
      expect(DashboardDelta.of(5, 0)!.text, 'new');
      expect(DashboardDelta.of(0, 0)!.text, 'same');
      expect(DashboardDelta.of(null, 4), isNull);
    });

    test('cancellations: down is good', () {
      final k = DashboardKpi.cancellation;
      expect(k.lowerIsBetter, isTrue);
      final better = k.delta(
        const DashboardKpis(requests: 100, cancelled: 10),
        const DashboardKpis(requests: 100, cancelled: 12),
      )!;
      expect(better.text, '▼ 2.0 pts');
      expect(better.tone, DeltaTone.good);
      final worse = k.delta(
        const DashboardKpis(requests: 100, cancelled: 14),
        const DashboardKpis(requests: 100, cancelled: 12),
      )!;
      expect(worse.tone, DeltaTone.bad);
      expect(worse.up, isTrue);
    });

    test('acceptance: up is good, in points', () {
      final d = DashboardKpi.acceptance.delta(
        const DashboardKpis(requests: 50, accepted: 44),
        const DashboardKpis(requests: 50, accepted: 43),
      )!;
      expect(d.text, '▲ 2.0 pts');
      expect(d.tone, DeltaTone.good);
      // Nothing to divide by: no change to tell.
      expect(DashboardKpi.acceptance.delta(const DashboardKpis(), const DashboardKpis()), isNull);
    });

    test('a rating and a wait: plain differences', () {
      final r = DashboardDelta.of(4.85, 4.82, kind: DeltaKind.absolute, decimals: 2)!;
      expect(r.text, '+0.03');
      expect(r.tone, DeltaTone.good);
      final w = DashboardDelta.of(6.1, 5.6, kind: DeltaKind.absolute, lowerIsBetter: true)!;
      expect(w.text, '+0.5');
      expect(w.tone, DeltaTone.bad);
      expect(DashboardDelta.of(5.6, 5.6, kind: DeltaKind.absolute)!.tone, DeltaTone.flat);
    });
  });

  group('the answers', () {
    final json = {
      'current': {
        'currency': 'MYR',
        'kpis': {'trips': 3, 'bookings': 60, 'commission': 6, 'requests': 6, 'accepted': 4, 'cancelled': 2},
        'buckets': [
          {'start': '2021-03-10T09:00', 'trips': 2, 'bookings': 50, 'requests': 2, 'accepted': 2, 'riders': 2},
          {'start': '2021-03-10T10:00', 'trips': 1, 'bookings': 10, 'requests': 4, 'accepted': 2, 'cancelled': 2},
        ],
        'funnel': {'requests': 6, 'offered': 5, 'accepted': 4, 'picked_up': 3, 'completed': 3},
        'services': [
          {'name': 'Ride', 'trips': 2, 'bookings': 30},
        ],
        'heat': [
          {'dow': 3, 'hour': 9, 'n': 2},
          {'dow': 4, 'hour': 9, 'n': 1},
        ],
        'quality': {'rating_avg': 4.5, 'driver_cancels': 1, 'rider_cancels': 1, 'pickup_min': 5.3},
      },
      'previous': {
        'kpis': {'trips': 1, 'bookings': 15, 'requests': 2, 'cancelled': 1},
      },
      'areas': [
        {'name': 'Petaling Jaya', 'trips': 2, 'bookings': 30, 'prev_trips': 1},
      ],
      'drivers': [
        {'profile_id': 'u1', 'partner_id': 'p1', 'name': 'Ahmad', 'trips': 2, 'earned': 45, 'rating': 4.9, 'online_seconds': 14400},
      ],
      'online_recorded': true,
      'airports': [
        {'id': 'a1', 'kind': 'airport', 'name': 'KLIA T1', 'waiting': 8, 'pickups': 24, 'prev_pickups': 20},
      ],
      'attention': {'partners_pending': 4, 'vehicles_no_permit': 5},
    };

    test('parse, with KPIs and rates worked out', () {
      final s = DashboardSummary.fromJson(json);
      expect(s.current.kpis.averageFare, 20);
      expect(s.current.kpis.cancellationRate, closeTo(1 / 3, 1e-9));
      expect(s.current.kpis.acceptanceRate, closeTo(4 / 6, 1e-9));
      expect(s.current.driverCancelRate, 0.25);
      expect(s.current.riderCancelRate, closeTo(1 / 6, 1e-9));
      expect(s.current.buckets.first.start, DateTime.utc(2021, 3, 10, 9));
      expect(s.current.funnel.steps.map((x) => x.count), [6, 5, 4, 3, 3]);
      expect(s.current.funnel.steps.first.share, isNull);
      expect(s.areas.single.averageFare, 15);
      expect(s.drivers.single.partnerId, 'p1');
      expect(s.attention.vehiclesNoPermit, 5);
      expect(DashboardKpi.trips.delta(s.current.kpis, s.previous.kpis)!.text, '▲ 200.0%');
      expect(DashboardKpi.cancellation.spark(s.current.buckets), [0, 0.5]);
      expect(DashboardKpi.averageFare.format(s.current.kpis.averageFare, 'MYR'), 'RM20.00');
      expect(DashboardKpi.cancellation.format(s.current.kpis.cancellationRate, 'MYR'), '33.3%');
    });

    test('demand: one row for one day, a row per weekday otherwise', () {
      final cells = DashboardSummary.fromJson(json).current.heat;
      final one = dashboardHeatRows(cells, oneRow: true);
      expect(one, hasLength(1));
      expect(one.single[9], 3);
      final week = dashboardHeatRows(cells, oneRow: false);
      expect(week, hasLength(7));
      expect(week[2][9], 2); // Wednesday
      expect(week[3][9], 1);
    });

    test('live', () {
      final l = DashboardLive.fromJson({
        'drivers_online': 48,
        'first_offer_seconds': 134,
        'queues': [
          {'name': 'KLIA T1', 'waiting': 11},
        ],
        'sos_open': 1,
      });
      expect(l.driversOnline, 48);
      expect(formatDashboardWait(l.firstOfferSeconds!), '2:14');
      expect(l.queues.single.waiting, 11);
      expect(DashboardLive.fromJson(const {}).firstOfferSeconds, isNull);
    });

    test('formatting', () {
      expect(formatDashboardCount(1234), '1,234');
      expect(formatDashboardOnline(33000), '9h 10m');
      expect(formatDashboardOnline(2700), '45m');
      expect(formatDashboardAxis(1250), '1.3k');
      expect(formatDashboardShare(1, 4), '25%');
      expect(dashboardNiceCeil(37), 50);
      expect(dashboardNiceCeil(0), 1);
    });
  });
}
