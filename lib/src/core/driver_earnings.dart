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
import 'partner_statement.dart' show earningsRange, earningsWeeksRange, malaysiaDate;
import 'trip_receipt.dart';

/// The spans the page can total.
enum EarningsPeriod {
  today('Today'),
  week('This week'),
  month('This month');

  const EarningsPeriod(this.label);
  final String label;
}

/// The day [period] starts on, in Malaysia, at the instant [now]: today,
/// the week's first day (Monday, or Sunday with [sunday]) or the 1st; a UTC
/// date with no time, as [malaysiaDate]. The same days the server's totals
/// on the page use ([earningsRange]), whatever the device's time zone.
DateTime earningsPeriodStart(EarningsPeriod period, DateTime now, {bool sunday = false}) =>
    malaysiaDate(earningsRange(period, now, sunday: sunday).from);

/// [at] as Malaysia's wall clock (a UTC DateTime holding Malaysia's date and
/// time), for a day or a time printed beside the page's totals.
DateTime malaysiaWallClock(DateTime at) => at.toUtc().add(const Duration(hours: 8));

/// The totals for a set of trips.
class EarningsTotals {
  const EarningsTotals({
    this.trips = 0,
    this.gross = 0,
    this.commission = 0,
    this.platformFees = 0,
    this.distanceKm = 0,
  });

  final int trips;

  /// What passengers owed: fares plus tolls, surcharges and other charges.
  final double gross;

  /// The platform commission charged on those trips.
  final double commission;

  /// The platform's fees taken back from those trips (0189).
  final double platformFees;
  final double distanceKm;

  /// What the driver kept, as the statement counts it.
  double get net => gross - commission - platformFees;

  EarningsTotals add(TripReceipt r) => EarningsTotals(
    trips: trips + 1,
    gross: gross + r.gross,
    commission: commission + (r.commission ?? 0),
    platformFees: platformFees + r.platformFees,
    distanceKm: distanceKm + (r.distanceKm ?? 0),
  );
}

/// One day of the period, newest first on the page.
class EarningsDay {
  const EarningsDay(this.date, this.totals);

  /// The day in Malaysia (a UTC date with no time).
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
/// caller can hand over a plain trip history. Periods and days are
/// Malaysia's, as the page's totals ([earningsRange]), by when the trip was
/// completed.
EarningsSummary summarizeEarnings(
  List<RideRequest> rides, {
  required String driverId,
  required EarningsPeriod period,
  required DateTime now,
  bool sunday = false,
}) {
  final range = earningsRange(period, now, sunday: sunday);
  var totals = const EarningsTotals();
  final byDay = <DateTime, EarningsTotals>{};
  String? currency;
  for (final r in rides) {
    if (r.partnerId != driverId || r.status != RideStatus.completed) continue;
    final done = r.completedAt ?? r.createdAt;
    if (done == null || done.isBefore(range.from) || !done.isBefore(range.to)) continue;
    final receipt = TripReceipt.fromRide(r, asDriver: true);
    currency ??= r.currency;
    totals = totals.add(receipt);
    final day = malaysiaDate(done);
    byDay[day] = (byDay[day] ?? const EarningsTotals()).add(receipt);
  }
  final days = [for (final e in byDay.entries) EarningsDay(e.key, e.value)]..sort((a, b) => b.date.compareTo(a.date));
  return EarningsSummary(currency: currency ?? 'MYR', totals: totals, days: days);
}

/// How many weeks the Earnings chart shows.
const earningsChartWeeks = 8;

/// The instant the page's trip history must start from at [now]: far
/// enough back, in Malaysia's days, for both the month and the chart's
/// [weeks] weeks (counted from Sunday, the earlier of the two week starts,
/// so either admin setting is covered).
DateTime earningsHistoryStart(DateTime now, {int weeks = earningsChartWeeks}) {
  final month = earningsRange(EarningsPeriod.month, now).from;
  final firstWeek = earningsWeeksRange(now, weeks: weeks, sunday: true).from;
  return month.isBefore(firstWeek) ? month : firstWeek;
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
  bool sunday = false,
}) {
  // The page's own period, in Malaysia's days: "Today" here is the totals
  // card's today, whatever the device's time zone.
  final range = earningsRange(period, now, sunday: sunday);
  final rows = <({DateTime at, RideRequest ride})>[];
  for (final r in rides) {
    if (r.partnerId != driverId || r.status != RideStatus.completed) continue;
    final done = r.completedAt ?? r.createdAt;
    if (done == null || done.isBefore(range.from) || !done.isBefore(range.to)) continue;
    // Dated and timed on Malaysia's clock, as the totals.
    rows.add((at: malaysiaWallClock(done), ride: r));
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
String earningsCsvFileName(EarningsPeriod period, DateTime now, {bool sunday = false}) {
  final d = earningsPeriodStart(period, now, sunday: sunday);
  String two(int n) => n.toString().padLeft(2, '0');
  return 'earnings-${period.label.toLowerCase().replaceAll(' ', '-')}-${d.year}-${two(d.month)}-${two(d.day)}.csv';
}
