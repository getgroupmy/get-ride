import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/commerce/get_coin.dart';
import 'package:get_ride/src/core/coin_trade.dart';
import 'package:get_ride/src/core/wallet_qr.dart';
import 'package:get_ride/src/data/coin_trade_repository.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/wallet/coin_trade_screen.dart';
import 'package:get_ride/src/features/wallet/wallet_qr_screens.dart';
import 'package:get_ride/src/features/wallet/wallet_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:qr_flutter/qr_flutter.dart';

const _me = '11111111-1111-1111-1111-111111111111';
const _friend = '22222222-2222-2222-2222-222222222222';

class _FakeTrade implements CoinTradeRepository {
  @override
  Future<CoinTradeQuote> quote() async => const CoinTradeQuote(
    walletBalance: 10,
    coinBalance: 300,
    settings: GetCoinSettings(coinsPerCurrency: 100),
    stats: CoinMarketStats(),
  );

  @override
  Future<CoinTradeResult> trade(CoinTradeDirection direction, double coins, double ratePerGC) =>
      throw UnimplementedError();
}

Widget _app(Widget home) => ProviderScope(
  overrides: [
    currentUserIdProvider.overrideWithValue(_me),
    profileProvider.overrideWith((ref) async => Profile({'id': _me, 'name': 'Aina Hassan'})),
    coinTradeRepositoryProvider.overrideWithValue(_FakeTrade()),
    walletBalancesProvider.overrideWith((ref) async => const []),
    walletTxProvider.overrideWith((ref) async => const []),
  ],
  child: MaterialApp(home: home),
);

void main() {
  testWidgets('receive shows the account code and an amount code that expires', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(const ReceiveQrScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Aina Hassan'), findsOneWidget);
    expect(tester.widget<QrImageView>(find.byKey(const ValueKey('wallet-qr'))), isNotNull);
    expect(find.text(walletAccountNumber(_me)), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('qr-amount')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '12.5');
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(find.text('Valid for 60s'), findsOneWidget);

    await tester.pump(const Duration(seconds: 61));
    expect(find.text('QR code expired'), findsOneWidget);
    await tester.tap(find.text('Regenerate'));
    await tester.pump();
    expect(find.text('Valid for 60s'), findsOneWidget);
    await tester.tap(find.text('Cancel amount'));
    await tester.pump();
    expect(find.textContaining('Valid for'), findsNothing);
  });

  testWidgets('the GET.coin code shows the wallet id and coin balance', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(const ReceiveQrScreen(coin: true)));
    await tester.pumpAndSettle();
    expect(find.text('Scan to send GET.coin to Aina Hassan'), findsOneWidget);
    expect(find.text(_me), findsOneWidget);
    expect(find.textContaining('GET.coin 300'), findsOneWidget);
    expect(find.byKey(const ValueKey('qr-amount')), findsNothing);
  });

  testWidgets('a scanned GET code opens Send addressed to that account', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(const CoinTradeScreen(sendTo: _friend, requestedAmount: 12.5)));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, _friend), findsOneWidget);
    expect(find.text('The code asks for RM12.50'), findsOneWidget);
    await tester.tap(find.text('Use'));
    await tester.pump();
    expect(find.widgetWithText(TextField, '1250'), findsOneWidget);
  });
}
