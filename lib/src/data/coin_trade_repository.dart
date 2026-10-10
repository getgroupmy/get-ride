import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../admin/screens/commerce/get_coin.dart';
import '../core/coin_trade.dart';
import '../providers.dart';
import 'live_tables.dart';

/// What the trade screen prices against: the two balances it moves between,
/// the admin's GET.coin settings, the 30-day market signals and the server's
/// buy/sell prices.
class CoinTradeQuote {
  const CoinTradeQuote({
    required this.walletBalance,
    required this.coinBalance,
    required this.settings,
    required this.stats,
    this.serverPrices,
  });

  final double walletBalance;
  final double coinBalance;
  final GetCoinSettings settings;
  final CoinMarketStats stats;

  /// `get_coin_trade_quote` (migration 0089); null on an older database.
  final CoinTradePrices? serverPrices;

  CoinMarketRate get market => computeMarketRate(settings, stats);

  /// The server's prices, or the same rule applied on the device. A
  /// pre-0089 server still settles at the rate the app sends, so this keeps
  /// an unmodified app on the spread there too.
  CoinTradePrices get prices => serverPrices ?? CoinTradePrices.fromMarket(market);
}

/// Buying and selling GET.coin against GET.wallet (Expo `tradeCoins`). The
/// balances only ever move through the owner-scoped `wallet_trade_coins`
/// RPC, which prices the trade itself (buy at max(market, peg), sell at
/// min(market, peg)) and re-checks the balances and supply cap server-side.
class CoinTradeRepository {
  CoinTradeRepository(this._db);
  final SupabaseClient _db;

  String get _uid {
    final id = _db.auth.currentUser?.id;
    if (id == null) throw StateError('Not signed in');
    return id;
  }

  Future<CoinTradeQuote> quote() async {
    final results = await Future.wait<Object?>([
      _db.from('wallets').select('wallet_type, balance').eq('user_id', _uid),
      _db.from('get_coin_settings').select().eq('id', 'master').maybeSingle(),
      _db.rpc('get_coin_market_stats').then<Object?>((v) => v, onError: (_) => null),
      _db.rpc('get_coin_trade_quote').then<Object?>((v) => v, onError: (_) => null),
    ]);
    double balance(String type) {
      for (final r in results[0] as List) {
        if (r['wallet_type'] == type) {
          final v = r['balance'];
          return v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
        }
      }
      return 0;
    }

    final row = results[1] as Map<String, dynamic>?;
    return CoinTradeQuote(
      walletBalance: balance('get_wallet'),
      coinBalance: balance('get_coin'),
      settings: row == null ? const GetCoinSettings() : GetCoinSettings.fromRow(row),
      stats: CoinMarketStats.fromRpc(results[2]),
      serverPrices: CoinTradePrices.fromRpc(results[3]),
    );
  }

  /// Settles a trade at the server's price for [direction] ([ratePerGC] is
  /// only a fallback for the result figures); throws with the RPC's error
  /// string on refusal (map it with [coinTradeErrorMessage]).
  Future<CoinTradeResult> trade(CoinTradeDirection direction, double coins, double ratePerGC) async {
    final data = await _db.rpc(
      'wallet_trade_coins',
      params: {'p_user': _uid, 'p_direction': direction.name, 'p_coins': coins, 'p_rate_per_gc': ratePerGC},
    );
    return CoinTradeResult.fromRpc(
      data,
      coins: coins,
      amount: coinTradeAmount(coins, ratePerGC, direction),
      rate: ratePerGC,
    );
  }
}

final coinTradeRepositoryProvider = Provider((ref) => CoinTradeRepository(ref.watch(supabaseProvider)));

final coinTradeQuoteProvider = FutureProvider.autoDispose((ref) {
  ref.watchLive('get_coin_settings');
  return ref.watch(coinTradeRepositoryProvider).quote();
});

/// The last 48 recorded GET.coin rates, oldest first, for the price line.
/// Empty when they can't be read: the chart then says it is still building.
final coinRateHistoryProvider = FutureProvider.autoDispose<List<double>>((ref) async {
  ref.watchLive('get_coin_rate_history');
  try {
    final rows = await ref
        .watch(supabaseProvider)
        .from('get_coin_rate_history')
        .select('rate_per_gc, recorded_at')
        .order('recorded_at', ascending: false)
        .limit(48);
    return [
      for (final r in rows.reversed)
        if (r['rate_per_gc'] is num) (r['rate_per_gc'] as num).toDouble(),
    ];
  } catch (_) {
    return const [];
  }
});

/// The admin's GET.coin settings alone (no wallets or market), for screens
/// that only show what the programme pays. Null when unreadable.
final coinSettingsProvider = FutureProvider.autoDispose<GetCoinSettings?>((ref) async {
  ref.watchLive('get_coin_settings');
  try {
    final row = await ref.watch(supabaseProvider).from('get_coin_settings').select().eq('id', 'master').maybeSingle();
    return row == null ? const GetCoinSettings() : GetCoinSettings.fromRow(row);
  } catch (_) {
    return null;
  }
});
