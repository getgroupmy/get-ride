import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/commerce/get_coin.dart';
import 'package:get_ride/src/core/coin_trade.dart';
import 'package:get_ride/src/data/coin_trade_repository.dart';
import 'package:get_ride/src/features/wallet/coin_trade_screen.dart';

class _FakeRepo implements CoinTradeRepository {
  _FakeRepo({this.settings = const GetCoinSettings(coinsPerCurrency: 10), this.fail});

  double wallet = 50;
  double coin = 30;
  final GetCoinSettings settings;
  final Object? fail;
  final trades = <(CoinTradeDirection, double, double)>[];

  @override
  Future<CoinTradeQuote> quote() async => CoinTradeQuote(
    walletBalance: wallet,
    coinBalance: coin,
    settings: settings,
    stats: const CoinMarketStats(circulatingSupply: 900),
  );

  @override
  Future<CoinTradeResult> trade(CoinTradeDirection direction, double coins, double ratePerGC) async {
    if (fail != null) throw fail!;
    trades.add((direction, coins, ratePerGC));
    final value = coinTradeValue(coins, ratePerGC);
    if (direction == CoinTradeDirection.buy) {
      wallet -= value;
      coin += coins;
    } else {
      wallet += value;
      coin -= coins;
    }
    return CoinTradeResult(coins: coins, amount: value, ratePerGC: ratePerGC);
  }
}

void main() {
  group('coin trade maths', () {
    const s = GetCoinSettings(coinsPerCurrency: 10);
    const stats = CoinMarketStats(circulatingSupply: 900);

    test('trade value rounds to sen', () {
      expect(coinTradeValue(12.5, 0.1), 1.25);
      expect(coinTradeValue(3, 0.333333), 1.0);
      expect(coinTradeValue(0, 0.1), 0);
    });

    test('max buy is what GET.wallet affords, capped by remaining supply', () {
      double max(GetCoinSettings s) => maxTradeCoins(
        direction: CoinTradeDirection.buy,
        walletBalance: 50,
        coinBalance: 0,
        ratePerGC: 0.1,
        settings: s,
        stats: stats,
      );
      expect(max(s), 500);
      expect(max(s.copyWith(maxSupply: 1000)), 100);
      expect(max(s.copyWith(maxSupply: 800)), 0);
    });

    test('max sell is the coin balance', () {
      expect(
        maxTradeCoins(
          direction: CoinTradeDirection.sell,
          walletBalance: 0,
          coinBalance: 12.349,
          ratePerGC: 0.1,
          settings: s,
          stats: stats,
        ),
        12.34,
      );
    });

    test('problems', () {
      String? p(CoinTradeDirection d, double coins, {double max = 100, GetCoinSettings? settings}) => coinTradeProblem(
        direction: d,
        coins: coins,
        maxCoins: max,
        ratePerGC: 0.1,
        settings: settings ?? s,
        stats: stats,
      );
      expect(p(CoinTradeDirection.buy, 0), 'Enter an amount greater than 0.');
      expect(p(CoinTradeDirection.buy, 0.01), 'Amount is too small to trade.');
      expect(p(CoinTradeDirection.buy, 50), isNull);
      expect(p(CoinTradeDirection.buy, 150), 'Not enough balance in GET.wallet.');
      expect(p(CoinTradeDirection.sell, 150), 'Not enough GET.coin to sell.');
      expect(
        p(CoinTradeDirection.buy, 150, max: 1000, settings: s.copyWith(maxSupply: 1000)),
        'Only 100 GC left before the supply cap.',
      );
      expect(
        p(CoinTradeDirection.buy, 5, settings: s.copyWith(maxSupply: 900)),
        'Supply cap reached — no more GC can be minted.',
      );
      // The supply cap never limits a sell.
      expect(p(CoinTradeDirection.sell, 5, settings: s.copyWith(maxSupply: 900)), isNull);
    });

    test('RPC errors map to plain words', () {
      expect(coinTradeErrorMessage(Exception('insufficient_balance')), 'Not enough balance in GET.wallet.');
      expect(coinTradeErrorMessage('P0001: insufficient_coins'), 'Not enough GET.coin to sell.');
      expect(coinTradeErrorMessage('supply_cap_reached'), 'Supply cap reached — no more GC can be minted.');
      expect(coinTradeErrorMessage('rate_unavailable'), 'Coin rate unavailable. Try again.');
      expect(coinTradeErrorMessage('not_authorized'), 'Sign in again to trade GET.coin.');
      expect(coinTradeErrorMessage('boom'), 'Trade failed. Please try again.');
    });

    test('settled result prefers the server figures', () {
      final r = CoinTradeResult.fromRpc(
        {'coins': '10', 'amount_currency': 1.05, 'rate_per_gc': 0.105},
        coins: 10,
        amount: 1,
        rate: 0.1,
      );
      expect((r.coins, r.amount, r.ratePerGC), (10.0, 1.05, 0.105));
      final fallback = CoinTradeResult.fromRpc(null, coins: 10, amount: 1, rate: 0.1);
      expect((fallback.coins, fallback.amount, fallback.ratePerGC), (10.0, 1.0, 0.1));
    });
  });

  group('trade screen', () {
    Future<_FakeRepo> pump(WidgetTester tester, _FakeRepo repo) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [coinTradeRepositoryProvider.overrideWithValue(repo)],
          child: const MaterialApp(home: CoinTradeScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return repo;
    }

    testWidgets('buys at the fixed rate after confirming', (tester) async {
      final repo = await pump(tester, _FakeRepo());
      expect(find.textContaining('Fixed rate'), findsOneWidget);
      expect(find.text('RM0.1000'), findsOneWidget);

      await tester.tap(find.text('50'));
      await tester.pump();
      expect(find.text('RM5.00'), findsOneWidget);

      await tester.tap(find.text('Buy GET.coin'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Buy'));
      await tester.pumpAndSettle();

      expect(repo.trades, [(CoinTradeDirection.buy, 50.0, 0.1)]);
      expect(find.text('Bought 50 GC for RM5.00.'), findsOneWidget);
      expect(repo.coin, 80);
    });

    testWidgets('blocks a sell past the balance and shows server refusals', (tester) async {
      final repo = await pump(tester, _FakeRepo(fail: Exception('insufficient_coins')));
      await tester.tap(find.text('Sell'));
      await tester.pump();

      await tester.enterText(find.byKey(const ValueKey('coin-amount')), '40');
      await tester.pump();
      expect(find.text('Not enough GET.coin to sell.'), findsOneWidget);
      final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Sell GET.coin'));
      expect(button.onPressed, isNull);

      await tester.tap(find.text('MAX'));
      await tester.pump();
      await tester.tap(find.text('Sell GET.coin'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Sell'));
      await tester.pumpAndSettle();
      expect(find.text('Not enough GET.coin to sell.'), findsOneWidget);
      expect(repo.trades, isEmpty);
    });

    testWidgets('market pricing shows the change and its signals', (tester) async {
      await pump(
        tester,
        _FakeRepo(settings: const GetCoinSettings(coinsPerCurrency: 10, marketEnabled: true, maxSupply: 1000)),
      );
      expect(find.textContaining('Market rate'), findsOneWidget);
      expect(find.text("What's moving the price"), findsOneWidget);
      expect(find.textContaining('Supply scarcity'), findsOneWidget);
      expect(find.textContaining('100 GC left'), findsOneWidget);
    });
  });
}
