// What a fixed-fare vehicle's (i) and the demand band say (inDrive's fare
// details): the rate card the fare is priced on, what an in-app fare does and
// doesn't cover, and the headline for a fare off the usual. Pure and tested in
// test/fare_info_test.dart.
library;

import 'fare.dart';
import 'fare_tariff.dart';
import 'format.dart';
import 'route_estimate.dart' show FareTrendDirection;

/// A metered taxi: its fare in the app is an estimate, the meter decides.
bool isMeteredService(RideService s) {
  bool taxi(String v) {
    final l = v.toLowerCase();
    return l.contains('teksi') || l.contains('taxi');
  }

  return taxi(s.name) || s.serviceTypes.any(taxi);
}

/// A rate as the card prints it: whole amounts without decimals, others with.
String rateMoney(double v, String currency) => formatMoney(v, currency, v == v.roundToDouble() ? 0 : 2);

/// The rates [s] is priced on at the pickup, one per line ("Base fare: RM 4").
/// [card] is the pickup's tariff card for it; null is the built-in TEKSI
/// tariff. The vehicle's own multiplier is applied where the fare applies it.
List<String> fareRateLines(FareTariff? card, RideService s, {String fallbackCurrency = 'MYR'}) {
  if (card == null) {
    final m = s.multiplier;
    String money(double v) => rateMoney(double.parse((v * m).toStringAsFixed(2)), fallbackCurrency);
    return ['Flag fall (first km): ${money(4)}', 'Then: ${money(0.35)} per 200 m or 36 s'];
  }
  final m = card.vehicleService == null ? s.multiplier : 1.0;
  String money(double v) => rateMoney(double.parse(v.toStringAsFixed(2)), card.currency);
  return [
    'Base fare: ${money(card.baseFare * m)}',
    'Fare per km: ${money(card.perKm * m)}',
    'Fare per minute: ${money(card.perMinute * m)}',
    if (card.minimumFare > 0) 'Minimum fare: ${money(card.minimumFare)}',
    if (card.bookingFee > 0) 'Booking fee: ${money(card.bookingFee)}',
  ];
}

/// What a metered taxi's fare in the app means.
const meteredFareNote =
    'The fare in the app is an estimate. The final fare is based on the taximeter. '
    'The fare on the taximeter may be higher due to traffic and other factors.';

/// What every other fixed fare in the app does and doesn't cover.
const appFareNotesTitle = 'Fares in the app:';
const appFareNotes = [
  'take traffic into account',
  'are calculated before your ride starts',
  'do not include tolls or waiting fees',
];

/// The band over the list, and the line in its details, for a fare off the
/// usual.
String demandHeadline(FareTrendDirection d) =>
    d == FareTrendDirection.up ? 'High demand — fare is higher' : 'Low demand — fare is lower';

String demandDetail(FareTrendDirection d) =>
    d == FareTrendDirection.up ? 'High demand — fare is temporarily higher' : 'Low demand — fare is temporarily lower';

/// What the demand trend adds to a fare: [withTrend] is the fare priced on
/// the AI's traffic-aware distance and time (what is booked), [usual] the
/// same fare priced on the plain road route. Null when it adds nothing.
({double amount, double factor})? demandUplift(double withTrend, double usual) {
  if (!(usual > 0) || withTrend - usual < 0.005) return null;
  return (amount: withTrend - usual, factor: withTrend / usual);
}

/// The uplift beside a price ("+RM1").
String demandUpliftLabel(String money) => '+$money';

/// The fare line's note while the trend raises the fare.
String demandIncludesNote(String money) => 'Includes high demand +$money';

/// The demand sheet's first line: how much higher, from the real [factor]
/// when known (else without a number).
String demandHigherLine(double? factor) {
  final pct = factor == null ? 0 : ((factor - 1) * 100).round();
  final how = pct > 0 ? '$pct% higher' : 'higher';
  return 'Fares are $how right now because of demand and traffic on this route. '
      'They come back down as it eases.';
}
