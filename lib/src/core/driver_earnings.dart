/// The driver's Earnings page (driver menu → Earnings): what the completed
/// trips came to over a day, a week or a month, and what the driver kept
/// once the platform commission was taken from GET.credit.
///
/// Expo never built this page (its row said "coming soon" and the driver
/// home's "today's earnings" was always 0); the user guide promised today's
/// earnings and daily totals, which is what this works out. Each trip is
/// priced exactly as its driver's receipt prices it ([TripReceipt.fromRide]),
/// so the page and the receipts can never disagree. Pure.
library;

import '../data/models.dart';
import 'trip_receipt.dart';

/// The spans the page can total.
enum EarningsPeriod {
  today('Today'),
  week('This week'),
  month('This month');

  const EarningsPeriod(this.label);
  final String label;
}

/// Where [period] starts for a device clock reading [now] (local time):
/// midnight today, Monday's midnight, or the 1st of the month.
DateTime earningsPeriodStart(EarningsPeriod period, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  return switch (period) {
    EarningsPeriod.today => today,
    EarningsPeriod.week => today.subtract(Duration(days: today.weekday - DateTime.monday)),
    EarningsPeriod.month => DateTime(now.year, now.month),
  };
}

/// The totals for a set of trips.
class EarningsTotals {
  const EarningsTotals({this.trips = 0, this.gross = 0, this.commission = 0, this.distanceKm = 0});

  final int trips;

  /// What passengers owed: fares plus tolls, surcharges and other charges.
  final double gross;

  /// The platform commission charged on those trips.
  final double commission;
  final double distanceKm;

  /// What the driver kept.
  double get net => gross - commission;

  EarningsTotals add(TripReceipt r) => EarningsTotals(
    trips: trips + 1,
    gross: gross + r.gross,
    commission: commission + (r.commission ?? 0),
    distanceKm: distanceKm + (r.distanceKm ?? 0),
  );
}

/// One day of the period, newest first on the page.
class EarningsDay {
  const EarningsDay(this.date, this.totals);

  /// Local midnight of the day.
  final DateTime date;
  final EarningsTotals totals;
}

class EarningsSummary {
  const EarningsSummary({required this.currency, required this.totals, required this.days});

  /// The currency of the trips (the first one's; a driver works one region).
  final String currency;
  final EarningsTotals totals;

  /// Only days with a trip, newest first.
  final List<EarningsDay> days;
}

/// Totals [rides] driven by [driverId] and completed within [period] of
/// [now]. Anything else in the list (rides taken as a passenger, cancelled
/// or unfinished requests, trips before the period) is left out, so the
/// caller can hand over a plain trip history. Days are the device's local
/// days, by when the trip was completed.
EarningsSummary summarizeEarnings(
  List<RideRequest> rides, {
  required String driverId,
  required EarningsPeriod period,
  required DateTime now,
}) {
  final start = earningsPeriodStart(period, now);
  var totals = const EarningsTotals();
  final byDay = <DateTime, EarningsTotals>{};
  String? currency;
  for (final r in rides) {
    if (r.partnerId != driverId || r.status != RideStatus.completed) continue;
    final at = (r.completedAt ?? r.createdAt)?.toLocal();
    if (at == null || at.isBefore(start) || at.isAfter(now)) continue;
    final receipt = TripReceipt.fromRide(r, asDriver: true);
    currency ??= r.currency;
    totals = totals.add(receipt);
    final day = DateTime(at.year, at.month, at.day);
    byDay[day] = (byDay[day] ?? const EarningsTotals()).add(receipt);
  }
  final days = [for (final e in byDay.entries) EarningsDay(e.key, e.value)]..sort((a, b) => b.date.compareTo(a.date));
  return EarningsSummary(currency: currency ?? 'MYR', totals: totals, days: days);
}

/// How many weeks the Earnings chart shows.
const earningsChartWeeks = 8;

/// One week of the chart: Monday's midnight and that week's totals.
class EarningsWeek {
  const EarningsWeek(this.start, this.totals);
  final DateTime start;
  final EarningsTotals totals;
}

/// Where the page's trip history must start for [now]: far enough back for
/// both the month and the chart's [weeks] weeks.
DateTime earningsHistoryStart(DateTime now, {int weeks = earningsChartWeeks}) {
  final month = earningsPeriodStart(EarningsPeriod.month, now);
  final firstWeek = earningsPeriodStart(EarningsPeriod.week, now).subtract(Duration(days: 7 * (weeks - 1)));
  return month.isBefore(firstWeek) ? month : firstWeek;
}

/// The last [weeks] weeks (Monday to Sunday, device time), oldest first,
/// including weeks with no trips, totalled as [summarizeEarnings] totals.
/// Pure.
List<EarningsWeek> weeklyEarnings(
  List<RideRequest> rides, {
  required String driverId,
  required DateTime now,
  int weeks = earningsChartWeeks,
}) {
  final thisWeek = earningsPeriodStart(EarningsPeriod.week, now);
  final starts = [
    for (var i = weeks - 1; i >= 0; i--) DateTime(thisWeek.year, thisWeek.month, thisWeek.day - 7 * i),
  ];
  final totals = List<EarningsTotals>.filled(weeks, const EarningsTotals());
  for (final r in rides) {
    if (r.partnerId != driverId || r.status != RideStatus.completed) continue;
    final at = (r.completedAt ?? r.createdAt)?.toLocal();
    if (at == null || at.isBefore(starts.first) || at.isAfter(now)) continue;
    var i = weeks - 1;
    while (i > 0 && at.isBefore(starts[i])) {
      i--;
    }
    totals[i] = totals[i].add(TripReceipt.fromRide(r, asDriver: true));
  }
  return [for (var i = 0; i < weeks; i++) EarningsWeek(starts[i], totals[i])];
}

/// The trips of [period] as CSV, one row per trip, oldest first: what a
/// driver hands an accountant. Amounts are plain numbers (two decimals, no
/// currency sign) so a spreadsheet adds them up; the currency has its own
/// column. Pure.
String earningsCsv(
  List<RideRequest> rides, {
  required String driverId,
  required EarningsPeriod period,
  required DateTime now,
}) {
  final start = earningsPeriodStart(period, now);
  final rows = <({DateTime at, RideRequest ride})>[];
  for (final r in rides) {
    if (r.partnerId != driverId || r.status != RideStatus.completed) continue;
    final at = (r.completedAt ?? r.createdAt)?.toLocal();
    if (at == null || at.isBefore(start) || at.isAfter(now)) continue;
    rows.add((at: at, ride: r));
  }
  rows.sort((a, b) => a.at.compareTo(b.at));
  String two(int n) => n.toString().padLeft(2, '0');
  String amount(double v) => v.toStringAsFixed(2);
  final out = StringBuffer(
    'Date,Time,Booking no.,From,To,Distance (km),Passengers paid,Commission,You earned,Currency\r\n',
  );
  for (final (:at, :ride) in rows) {
    final receipt = TripReceipt.fromRide(ride, asDriver: true);
    out.write(
      [
        '${at.year}-${two(at.month)}-${two(at.day)}',
        '${two(at.hour)}:${two(at.minute)}',
        receipt.bookingNo,
        ride.pickupLabel,
        ride.dropLabel,
        ride.distanceKm == null ? '' : ride.distanceKm!.toStringAsFixed(1),
        amount(receipt.gross),
        amount(receipt.commission ?? 0),
        amount(receipt.earnings),
        ride.currency,
      ].map(csvField).join(','),
    );
    out.write('\r\n');
  }
  return out.toString();
}

/// One CSV field: quoted when it holds a comma, quote or line break, with
/// quotes doubled; a leading = + - @ is prefixed with ' so a spreadsheet
/// never runs an address as a formula. Pure.
String csvField(String v) {
  var s = v;
  if (s.isNotEmpty && '=+-@'.contains(s[0]) && double.tryParse(s) == null) s = "'$s";
  if (s.contains(RegExp(r'[",\r\n]'))) return '"${s.replaceAll('"', '""')}"';
  return s;
}

/// The export's file name, e.g. `earnings-this-week-2026-10-12.csv`. Pure.
String earningsCsvFileName(EarningsPeriod period, DateTime now) {
  final d = earningsPeriodStart(period, now);
  String two(int n) => n.toString().padLeft(2, '0');
  return 'earnings-${period.label.toLowerCase().replaceAll(' ', '-')}-${d.year}-${two(d.month)}-${two(d.day)}.csv';
}
