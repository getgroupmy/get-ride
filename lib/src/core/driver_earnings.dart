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
