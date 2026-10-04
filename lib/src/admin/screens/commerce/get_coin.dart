/// GET.coin settings — pure port of Expo `utils/getCoinStore.ts` (row
/// parsing, save validation/payload, market-rate model, conversions).
library;

import 'dart:math' as math;

const defaultCoinsPerCurrency = 1.0;
const defaultMaxSwingPct = 50.0;

double _numOr(Object? v, double fallback) {
  if (v is num) return v.isFinite ? v.toDouble() : fallback;
  if (v is String) {
    final n = double.tryParse(v.trim());
    return n != null && n.isFinite ? n : fallback;
  }
  return fallback;
}

bool _boolOr(Object? v, bool fallback) => v is bool ? v : fallback;

class GetCoinSettings {
  const GetCoinSettings({
    this.coinsPerCurrency = defaultCoinsPerCurrency,
    this.earnCoinsPerCurrency = 0,
    this.marketEnabled = false,
    this.signalTrading = true,
    this.signalRevenue = true,
    this.signalServices = true,
    this.signalSignups = true,
    this.signalMinting = true,
    this.maxSwingPct = defaultMaxSwingPct,
    this.maxSupply = 0,
    this.referralEnabled = true,
    this.referralReferrerCoins = 0,
    this.referralReferredCoins = 0,
    this.currency = 'RM',
    this.updatedAt,
    this.fromDatabase = false,
  });

  /// Parses a `get_coin_settings` row (id `master`), clamping like Expo.
  factory GetCoinSettings.fromRow(Map<String, dynamic> row) {
    final rate = _numOr(row['coins_per_currency'], defaultCoinsPerCurrency);
    return GetCoinSettings(
      coinsPerCurrency: rate == 0 ? defaultCoinsPerCurrency : rate,
      earnCoinsPerCurrency: math.max(_numOr(row['earn_coins_per_currency'], 0), 0),
      marketEnabled: _boolOr(row['market_enabled'], false),
      signalTrading: _boolOr(row['signal_trading'], true),
      signalRevenue: _boolOr(row['signal_revenue'], true),
      signalServices: _boolOr(row['signal_services'], true),
      signalSignups: _boolOr(row['signal_signups'], true),
      signalMinting: _boolOr(row['signal_minting'], true),
      maxSwingPct: math.max(_numOr(row['market_max_swing'], defaultMaxSwingPct), 0),
      maxSupply: math.max(_numOr(row['max_supply'], 0), 0),
      referralEnabled: _boolOr(row['referral_enabled'], true),
      referralReferrerCoins: math.max(_numOr(row['referral_referrer_coins'], 0), 0),
      referralReferredCoins: math.max(_numOr(row['referral_referred_coins'], 0), 0),
      currency: '${row['currency'] ?? 'RM'}',
      updatedAt: row['updated_at'] as String?,
      fromDatabase: true,
    );
  }

  final double coinsPerCurrency;
  final double earnCoinsPerCurrency;
  final bool marketEnabled;
  final bool signalTrading;
  final bool signalRevenue;
  final bool signalServices;
  final bool signalSignups;
  final bool signalMinting;
  final double maxSwingPct;
  final double maxSupply;
  final bool referralEnabled;
  final double referralReferrerCoins;
  final double referralReferredCoins;
  final String currency;
  final String? updatedAt;

  /// False when no row exists yet (defaults shown).
  final bool fromDatabase;

  /// Validates and builds the `get_coin_settings` upsert row (Expo
  /// `saveGetCoinSettings`): rate > 0, reward ≥ 0, swing clamped 0–95,
  /// supply and referral amounts ≥ 0. Returns an error string instead when
  /// invalid.
  ({Map<String, dynamic>? row, String? error}) toSaveRow() {
    if (!(coinsPerCurrency.isFinite && coinsPerCurrency > 0)) {
      return (row: null, error: 'Enter a rate greater than 0.');
    }
    if (!(earnCoinsPerCurrency.isFinite && earnCoinsPerCurrency >= 0)) {
      return (row: null, error: 'Enter a reward rate of 0 or more.');
    }
    return (
      row: {
        'id': 'master',
        'coins_per_currency': coinsPerCurrency,
        'earn_coins_per_currency': earnCoinsPerCurrency,
        'market_enabled': marketEnabled,
        'signal_trading': signalTrading,
        'signal_revenue': signalRevenue,
        'signal_services': signalServices,
        'signal_signups': signalSignups,
        'signal_minting': signalMinting,
        'market_max_swing': math.min(math.max(maxSwingPct.isFinite ? maxSwingPct : defaultMaxSwingPct, 0), 95),
        'max_supply': math.max(maxSupply.isFinite ? maxSupply : 0, 0),
        'referral_enabled': referralEnabled,
        'referral_referrer_coins': math.max(referralReferrerCoins.isFinite ? referralReferrerCoins : 0, 0),
        'referral_referred_coins': math.max(referralReferredCoins.isFinite ? referralReferredCoins : 0, 0),
      },
      error: null,
    );
  }

  GetCoinSettings copyWith({
    double? coinsPerCurrency,
    double? earnCoinsPerCurrency,
    bool? marketEnabled,
    bool? signalTrading,
    bool? signalRevenue,
    bool? signalServices,
    bool? signalSignups,
    bool? signalMinting,
    double? maxSwingPct,
    double? maxSupply,
    bool? referralEnabled,
    double? referralReferrerCoins,
    double? referralReferredCoins,
  }) =>
      GetCoinSettings(
        coinsPerCurrency: coinsPerCurrency ?? this.coinsPerCurrency,
        earnCoinsPerCurrency: earnCoinsPerCurrency ?? this.earnCoinsPerCurrency,
        marketEnabled: marketEnabled ?? this.marketEnabled,
        signalTrading: signalTrading ?? this.signalTrading,
        signalRevenue: signalRevenue ?? this.signalRevenue,
        signalServices: signalServices ?? this.signalServices,
        signalSignups: signalSignups ?? this.signalSignups,
        signalMinting: signalMinting ?? this.signalMinting,
        maxSwingPct: maxSwingPct ?? this.maxSwingPct,
        maxSupply: maxSupply ?? this.maxSupply,
        referralEnabled: referralEnabled ?? this.referralEnabled,
        referralReferrerCoins: referralReferrerCoins ?? this.referralReferrerCoins,
        referralReferredCoins: referralReferredCoins ?? this.referralReferredCoins,
        currency: currency,
        updatedAt: updatedAt,
        fromDatabase: fromDatabase,
      );
}

/// Columns added after migration 0061 (market 0063, referral later); a save
/// against an older database retries without them, as Expo does.
const getCoinBaseColumns = {'id', 'coins_per_currency', 'earn_coins_per_currency'};

/// 30-day economy signals from the `get_coin_market_stats` RPC.
class CoinMarketStats {
  const CoinMarketStats({
    this.tradeBuyGc = 0,
    this.tradeSellGc = 0,
    this.commissionRevenue = 0,
    this.completedServices = 0,
    this.newSignups = 0,
    this.mintedGc = 0,
    this.circulatingSupply = 0,
  });

  factory CoinMarketStats.fromRpc(Object? data) {
    final row = data is Map ? data : const {};
    double f(String k) => math.max(_numOr(row[k], 0), 0);
    return CoinMarketStats(
      tradeBuyGc: f('trade_buy_gc'),
      tradeSellGc: f('trade_sell_gc'),
      commissionRevenue: f('commission_revenue'),
      completedServices: f('completed_services'),
      newSignups: f('new_signups'),
      mintedGc: f('minted_gc'),
      circulatingSupply: f('circulating_supply'),
    );
  }

  final double tradeBuyGc;
  final double tradeSellGc;
  final double commissionRevenue;
  final double completedServices;
  final double newSignups;
  final double mintedGc;
  final double circulatingSupply;
}

class MarketSignalContribution {
  const MarketSignalContribution(this.key, this.label, this.pct);
  final String key;
  final String label;
  final double pct;
}

class CoinMarketRate {
  const CoinMarketRate({
    required this.baseRatePerGC,
    required this.ratePerGC,
    required this.multiplier,
    required this.coinsPerCurrency,
    required this.changePct,
    required this.contributions,
  });
  final double baseRatePerGC;
  final double ratePerGC;
  final double multiplier;
  final double coinsPerCurrency;
  final double changePct;
  final List<MarketSignalContribution> contributions;
}

double _log10(double x) => math.log(x) / math.ln10;

double _logNorm(double value, double divisor) => math.min(_log10(1 + math.max(value, 0)) / divisor, 1);

double _roundTo(double v, double factor) => (v * factor).roundToDouble() / factor;

/// Deterministic market price from in-app signals, clamped to ±maxSwingPct.
CoinMarketRate computeMarketRate(GetCoinSettings s, CoinMarketStats stats) {
  final peg = s.coinsPerCurrency > 0 ? 1 / s.coinsPerCurrency : 0.0;
  final contributions = <MarketSignalContribution>[];
  var pressure = 0.0;
  void add(String key, String label, double c) {
    pressure += c;
    contributions.add(MarketSignalContribution(key, label, c * 100));
  }

  if (s.marketEnabled && peg > 0) {
    if (s.signalTrading) {
      final total = stats.tradeBuyGc + stats.tradeSellGc;
      final net = total > 0 ? (stats.tradeBuyGc - stats.tradeSellGc) / (total + 50) : 0.0;
      add('trading', 'Trading activity', 0.35 * net);
    }
    if (s.signalRevenue) add('revenue', 'Commission revenue', 0.25 * _logNorm(stats.commissionRevenue, 4));
    if (s.signalServices) add('services', 'Completed services', 0.2 * _logNorm(stats.completedServices, 3));
    if (s.signalSignups) add('signups', 'New sign-ups', 0.1 * _logNorm(stats.newSignups, 2.5));
    if (s.signalMinting) add('minting', 'New coins minted', -0.3 * _logNorm(stats.mintedGc, 4));
    if (s.maxSupply > 0 && stats.circulatingSupply > 0) {
      final ratio = math.min(stats.circulatingSupply / s.maxSupply, 1.0);
      add('scarcity', 'Supply scarcity', 0.3 * ratio * ratio);
    }
  }

  final cap = math.max(s.maxSwingPct, 0) / 100;
  final clamped = math.min(math.max(pressure, -cap), cap);
  final multiplier = s.marketEnabled ? 1 + clamped : 1.0;
  final ratePerGC = _roundTo(peg * multiplier, 1e6);
  return CoinMarketRate(
    baseRatePerGC: peg,
    ratePerGC: ratePerGC,
    multiplier: multiplier,
    coinsPerCurrency: ratePerGC > 0 ? 1 / ratePerGC : s.coinsPerCurrency,
    changePct: ((multiplier - 1) * 10000).roundToDouble() / 100,
    contributions: contributions,
  );
}

double coinsToCurrency(double coins, double coinsPerCurrency) =>
    coinsPerCurrency > 0 ? _roundTo(coins / coinsPerCurrency, 100) : 0;

double currencyToCoins(double amount, double coinsPerCurrency) => _roundTo(amount * coinsPerCurrency, 100);

double rideRewardCoins(double fareTotal, double earnCoinsPerCurrency) =>
    fareTotal > 0 && earnCoinsPerCurrency > 0 ? _roundTo(fareTotal * earnCoinsPerCurrency, 100) : 0;

/// "10" for whole rates, "10.25" otherwise (4 dp max) — Expo `formatRate`.
String formatRate(double rate) {
  if (rate % 1 == 0) return rate.toStringAsFixed(0);
  final r = _roundTo(rate, 10000);
  return r % 1 == 0 ? r.toStringAsFixed(0) : r.toString();
}

String _grouped(int n) {
  final s = n.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// "125 GC" for whole values, "125.50 GC" otherwise.
String formatCoins(double coins) {
  final abs = coins.abs();
  final whole = (abs - abs.round()).abs() < 0.005;
  return '${whole ? _grouped(abs.round()) : abs.toStringAsFixed(2)} GC';
}

/// Parses an input like Expo: strips everything but digits and dots.
double? parseLooseNumber(String input) {
  final cleaned = input.replaceAll(RegExp(r'[^0-9.]'), '');
  if (cleaned.isEmpty) return 0;
  return double.tryParse(cleaned);
}
