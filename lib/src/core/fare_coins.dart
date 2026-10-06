import '../admin/screens/commerce/get_coin.dart' show formatCoins;
import 'format.dart';
import 'wallet_qr.dart';

/// What GET.coin would take off [fare] at drop-off (Expo ride-confirm's
/// "Use GET.coin" row): as much as the balance covers at the admin rate,
/// never more than the fare. Null when coins can't be used at all, which is
/// when the booking sheet hides the switch.
CoinSplit? fareCoinOffer(double fare, double coinBalance, double coinsPerCurrency) {
  if (!(coinBalance > 0) || !(coinsPerCurrency > 0)) return null;
  return computeCoinSplit(fare > 0 ? fare : 0, coinBalance, coinsPerCurrency);
}

/// The booking-sheet subtitle for the switch: the balance and what it is
/// worth while off, the saving while on.
String fareCoinSubtitle({
  required bool on,
  required double fare,
  required double coinBalance,
  required double coinsPerCurrency,
  String currency = 'MYR',
}) {
  final worth = (coinBalance / coinsPerCurrency * 100).floorToDouble() / 100;
  if (!on) return '${formatCoins(coinBalance)} ≈ ${formatMoney(worth, currency)}';
  final off = fare > 0 && fare < worth ? fare : worth;
  return '−${formatMoney(off, currency)} off the fare at drop-off';
}

/// What `wallet_redeem_fare_coins` took for a ride.
typedef FareCoinRedemption = ({double coinsUsed, double coinValue});

FareCoinRedemption fareCoinRedemptionFrom(Object? data) {
  double n(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
  if (data is Map) return (coinsUsed: n(data['coins_used']), coinValue: n(data['coin_value']));
  return (coinsUsed: 0, coinValue: 0);
}
