/// GET.coin buy/sell maths — pure port of the trade half of Expo
/// `app/wallet-trade.tsx` and `tradeCoins` in `utils/walletStore.ts`.
library;

import 'dart:math' as math;

import '../admin/screens/commerce/get_coin.dart';

enum CoinTradeDirection { buy, sell }

double _round2(double v) => (v * 100).roundToDouble() / 100;
double _floor2(double v) => (v * 100).floorToDouble() / 100;

/// RM paid (buy) or received (sell) for [coins] at [ratePerGC].
double coinTradeValue(double coins, double ratePerGC) => coins > 0 && ratePerGC > 0 ? _round2(coins * ratePerGC) : 0;

/// RM a trade settles for — rounded up on a buy and down on a sell, exactly
/// like `wallet_trade_coins` (migration 0089), so the total shown before the
/// trade is the total charged. Expo `tradeAmount`.
double coinTradeAmount(double coins, double ratePerGC, CoinTradeDirection direction) {
  if (!(coins > 0) || !(ratePerGC > 0)) return 0;
  final cents = coins * ratePerGC * 100;
  // The tolerance absorbs float noise (0.1 × 3 = 0.30000000000000004).
  return (direction == CoinTradeDirection.buy ? (cents - 1e-6).ceilToDouble() : (cents + 1e-6).floorToDouble()) / 100;
}

/// What one GC costs to buy and pays to sell (Expo `CoinTradeQuote`). The
/// market rate only widens a spread around the peg: buys at max(market,
/// peg), sells at min(market, peg), so no sequence of trades can return more
/// RM than it put in. The server prices every trade this way and ignores the
/// rate the app sends.
class CoinTradePrices {
  const CoinTradePrices({
    required this.peg,
    required this.marketRate,
    required this.buyRate,
    required this.sellRate,
    this.fromServer = false,
  });

  /// The same rule the server applies, worked out on the device — for a
  /// database without `get_coin_trade_quote`.
  factory CoinTradePrices.fromMarket(CoinMarketRate market) => CoinTradePrices(
    peg: market.baseRatePerGC,
    marketRate: market.ratePerGC,
    buyRate: math.max(market.ratePerGC, market.baseRatePerGC),
    sellRate: math.min(market.ratePerGC, market.baseRatePerGC),
  );

  /// The `get_coin_trade_quote` answer, or null when it carries no usable
  /// rate.
  static CoinTradePrices? fromRpc(Object? data) {
    if (data is! Map) return null;
    double f(String k) {
      final v = data[k];
      if (v is num) return v.toDouble();
      return double.tryParse('${v ?? ''}') ?? 0;
    }

    final prices = CoinTradePrices(
      peg: f('peg'),
      marketRate: f('market_rate'),
      buyRate: f('buy_rate'),
      sellRate: f('sell_rate'),
      fromServer: true,
    );
    return prices.buyRate > 0 && prices.sellRate > 0 ? prices : null;
  }

  final double peg;
  final double marketRate;
  final double buyRate;
  final double sellRate;
  final bool fromServer;

  double rateFor(CoinTradeDirection direction) => direction == CoinTradeDirection.buy ? buyRate : sellRate;
}

/// GC still mintable before the supply cap, or null when uncapped.
double? remainingSupply(GetCoinSettings settings, CoinMarketStats stats) =>
    settings.maxSupply > 0 ? math.max(_round2(settings.maxSupply - stats.circulatingSupply), 0) : null;

/// The most GC this account can trade: a buy is what GET.wallet affords at
/// the rate (never past the supply cap), a sell is the GET.coin balance.
double maxTradeCoins({
  required CoinTradeDirection direction,
  required double walletBalance,
  required double coinBalance,
  required double ratePerGC,
  required GetCoinSettings settings,
  required CoinMarketStats stats,
}) {
  if (direction == CoinTradeDirection.sell) return math.max(_floor2(coinBalance), 0);
  if (!(ratePerGC > 0)) return 0;
  var affordable = math.max(_floor2(walletBalance / ratePerGC), 0.0);
  // Buys round up to the sen, so step back while the rounded cost overshoots.
  while (affordable > 0 && coinTradeAmount(affordable, ratePerGC, CoinTradeDirection.buy) > walletBalance) {
    affordable = _round2(affordable - 0.01);
  }
  final left = remainingSupply(settings, stats);
  if (left != null) affordable = math.min(affordable, _floor2(left));
  return affordable;
}

/// Why a trade cannot be sent as entered, or null when it can.
String? coinTradeProblem({
  required CoinTradeDirection direction,
  required double coins,
  required double maxCoins,
  required double ratePerGC,
  required GetCoinSettings settings,
  required CoinMarketStats stats,
}) {
  if (!(coins > 0)) return 'Enter an amount greater than 0.';
  if (!(ratePerGC > 0)) return 'Coin rate unavailable. Try again.';
  if (!(coinTradeAmount(coins, ratePerGC, direction) > 0)) return 'Amount is too small to trade.';
  if (direction == CoinTradeDirection.buy) {
    final left = remainingSupply(settings, stats);
    if (left != null && left <= 0) return 'Supply cap reached — no more GC can be minted.';
    if (left != null && coins > left + 0.0001) return 'Only ${formatCoins(left)} left before the supply cap.';
  }
  if (coins > maxCoins + 0.0001) {
    return direction == CoinTradeDirection.buy ? 'Not enough balance in GET.wallet.' : 'Not enough GET.coin to sell.';
  }
  return null;
}

/// The words for a `wallet_trade_coins` failure (Expo's mapping).
String coinTradeErrorMessage(Object error) {
  final msg = '$error'.toLowerCase();
  if (msg.contains('insufficient_balance')) return 'Not enough balance in GET.wallet.';
  if (msg.contains('insufficient_coins')) return 'Not enough GET.coin to sell.';
  if (msg.contains('supply_cap_reached')) return 'Supply cap reached — no more GC can be minted.';
  if (msg.contains('rate_unavailable')) return 'Coin rate unavailable. Try again.';
  if (msg.contains('invalid_amount')) return 'Enter an amount greater than 0.';
  if (msg.contains('not_authorized') || msg.contains('42501') || msg.contains('permission denied')) {
    return 'Sign in again to trade GET.coin.';
  }
  if (msg.contains('could not find the function') || msg.contains('pgrst202')) {
    return 'Coin trading is not set up on this server yet.';
  }
  return 'Trade failed. Please try again.';
}

/// "RM0.1000" — the rate shown beside a trade.
String formatCoinRate(double ratePerGC, String currency) => '$currency${ratePerGC.toStringAsFixed(4)}';

/// The settled trade the server answered with.
class CoinTradeResult {
  const CoinTradeResult({required this.coins, required this.amount, required this.ratePerGC});

  factory CoinTradeResult.fromRpc(Object? data, {required double coins, required double amount, required double rate}) {
    final row = data is Map ? data : const {};
    double f(String k, double fallback) {
      final v = row[k];
      if (v is num) return v.toDouble();
      return double.tryParse('${v ?? ''}') ?? fallback;
    }

    return CoinTradeResult(
      coins: f('coins', coins),
      amount: f('amount_currency', amount),
      ratePerGC: f('rate_per_gc', rate),
    );
  }

  final double coins;
  final double amount;
  final double ratePerGC;
}
