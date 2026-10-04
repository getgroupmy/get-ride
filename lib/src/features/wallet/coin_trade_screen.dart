import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../admin/screens/commerce/get_coin.dart';
import '../../core/coin_trade.dart';
import '../../core/format.dart';
import '../../data/coin_trade_repository.dart';
import '../../widgets/common.dart';
import 'wallet_screen.dart';

/// Buy and sell GET.coin against GET.wallet (Expo `app/wallet-trade.tsx`,
/// Buy / Sell tabs). Priced at the admin rate, or the market rate when
/// market pricing is on; the server settles at its own anchored rate.
class CoinTradeScreen extends ConsumerStatefulWidget {
  const CoinTradeScreen({super.key});

  @override
  ConsumerState<CoinTradeScreen> createState() => _CoinTradeScreenState();
}

class _CoinTradeScreenState extends ConsumerState<CoinTradeScreen> {
  final _amount = TextEditingController();
  var _direction = CoinTradeDirection.buy;
  var _busy = false;
  String? _error;
  String? _done;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  double get _coins => _round2(parseLooseNumber(_amount.text) ?? 0);

  static double _round2(double v) => (v * 100).roundToDouble() / 100;

  void _setAmount(double v) {
    _amount.text = v > 0 ? formatRate(v) : '';
    setState(() {
      _error = null;
      _done = null;
    });
  }

  Future<void> _confirm(CoinTradeQuote q, double rate) async {
    final coins = _coins;
    final value = coinTradeValue(coins, rate);
    final buy = _direction == CoinTradeDirection.buy;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(buy ? 'Buy GET.coin?' : 'Sell GET.coin?'),
        content: Text(
          buy
              ? 'Buy ${formatCoins(coins)} for ${formatMoney(value)} from GET.wallet at '
                    '${formatCoinRate(rate, 'RM')}/GC.'
              : 'Sell ${formatCoins(coins)} for ${formatMoney(value)} into GET.wallet at '
                    '${formatCoinRate(rate, 'RM')}/GC.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(buy ? 'Buy' : 'Sell')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _done = null;
    });
    try {
      final r = await ref.read(coinTradeRepositoryProvider).trade(_direction, coins, rate);
      if (!mounted) return;
      _amount.clear();
      setState(
        () => _done = buy
            ? 'Bought ${formatCoins(r.coins)} for ${formatMoney(r.amount)}.'
            : 'Sold ${formatCoins(r.coins)} for ${formatMoney(r.amount)}.',
      );
      ref.invalidate(coinTradeQuoteProvider);
      ref.invalidate(walletBalancesProvider);
      ref.invalidate(walletTxProvider);
    } catch (e) {
      if (mounted) setState(() => _error = coinTradeErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final quote = ref.watch(coinTradeQuoteProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Trade GET.coin')),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(coinTradeQuoteProvider.future),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ResponsiveCenter(
              maxWidth: 560,
              child: AsyncView(value: quote, onRetry: () => ref.invalidate(coinTradeQuoteProvider), data: _body),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(CoinTradeQuote q) {
    final t = Theme.of(context);
    final market = q.market;
    final rate = market.ratePerGC;
    final buy = _direction == CoinTradeDirection.buy;
    final coins = _coins;
    final value = coinTradeValue(coins, rate);
    final max = maxTradeCoins(
      direction: _direction,
      walletBalance: q.walletBalance,
      coinBalance: q.coinBalance,
      ratePerGC: rate,
      settings: q.settings,
      stats: q.stats,
    );
    final problem = coinTradeProblem(
      direction: _direction,
      coins: coins,
      maxCoins: max,
      ratePerGC: rate,
      settings: q.settings,
      stats: q.stats,
    );
    final showProblem = coins > 0 && problem != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RateCard(quote: q, market: market),
        const SizedBox(height: 16),
        SegmentedButton<CoinTradeDirection>(
          segments: const [
            ButtonSegment(value: CoinTradeDirection.buy, label: Text('Buy'), icon: Icon(Icons.add_circle_outline)),
            ButtonSegment(value: CoinTradeDirection.sell, label: Text('Sell'), icon: Icon(Icons.remove_circle_outline)),
          ],
          selected: {_direction},
          onSelectionChanged: _busy
              ? null
              : (s) => setState(() {
                  _direction = s.first;
                  _error = null;
                  _done = null;
                }),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('coin-amount'),
          controller: _amount,
          enabled: !_busy,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          decoration: InputDecoration(
            labelText: buy ? 'GC to buy' : 'GC to sell',
            suffixText: 'GC',
            helperText: buy
                ? 'GET.wallet ${formatMoney(q.walletBalance)} · up to ${formatCoins(max)}'
                : 'GET.coin ${formatCoins(q.coinBalance)}',
            errorText: showProblem ? problem : null,
          ),
          onChanged: (_) => setState(() {
            _error = null;
            _done = null;
          }),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final v in const [10.0, 50.0, 100.0])
              ActionChip(label: Text(formatRate(v)), onPressed: _busy ? null : () => _setAmount(v)),
            ActionChip(label: const Text('MAX'), onPressed: _busy || max <= 0 ? null : () => _setAmount(max)),
          ],
        ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            title: Text(buy ? 'You pay' : 'You receive'),
            subtitle: Text('at ${formatCoinRate(rate, 'RM')}/GC'),
            trailing: Text(formatMoney(value), style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          ),
        ),
        if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: TextStyle(color: t.colorScheme.error))],
        if (_done != null) ...[
          const SizedBox(height: 8),
          Text(
            _done!,
            style: const TextStyle(color: Colors.green, fontWeight: FontWeight.w600),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy || problem != null ? null : () => _confirm(q, rate),
          child: _busy
              ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(buy ? 'Buy GET.coin' : 'Sell GET.coin'),
        ),
        const SizedBox(height: 8),
        Text(
          'The final rate is checked by the server when the trade settles.',
          style: t.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _RateCard extends StatelessWidget {
  const _RateCard({required this.quote, required this.market});

  final CoinTradeQuote quote;
  final CoinMarketRate market;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = quote.settings;
    final change = market.changePct;
    final left = remainingSupply(s, quote.stats);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('1 GC', style: t.textTheme.labelLarge),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatCoinRate(market.ratePerGC, 'RM'),
                  style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(width: 8),
                if (s.marketEnabled)
                  Text(
                    '${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)}%',
                    style: TextStyle(
                      color: change > 0 ? Colors.green : (change < 0 ? t.colorScheme.error : null),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            if (!s.marketEnabled)
              const Text('Fixed rate — set by admin, market pricing is off.')
            else ...[
              Text(
                'Market rate · base ${formatCoinRate(market.baseRatePerGC, 'RM')}, '
                'moves at most ±${formatRate(s.maxSwingPct)}%',
              ),
              if (market.contributions.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text("What's moving the price", style: t.textTheme.labelLarge),
                for (final c in market.contributions)
                  Row(
                    children: [
                      Expanded(child: Text(c.label)),
                      Text('${c.pct >= 0 ? '+' : ''}${c.pct.toStringAsFixed(2)}%'),
                    ],
                  ),
              ],
            ],
            if (left != null) ...[
              const SizedBox(height: 8),
              Text(
                'Coin supply: ${formatCoins(quote.stats.circulatingSupply)} of ${formatCoins(s.maxSupply)} '
                '(${formatCoins(left)} left)',
              ),
            ],
          ],
        ),
      ),
    );
  }
}
