import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/commerce/get_coin.dart';
import 'package:get_ride/src/core/coin_trade.dart';
import 'package:get_ride/src/core/wallet_qr.dart';
import 'package:get_ride/src/data/coin_trade_repository.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/wallet_pay_repository.dart';
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

class _FakePay implements WalletPayRepository {
  _FakePay({this.error});
  final Object? error;
  final calls = <({double amount, String note, bool coins})>[];

  @override
  Future<WalletPayResult> pay(double amount, {required String note, bool redeemCoins = false}) async {
    calls.add((amount: amount, note: note, coins: redeemCoins));
    if (error != null) throw error!;
    return redeemCoins
        ? WalletPayResult(walletPaid: amount - 3, coinsUsed: 300, coinValue: 3)
        : WalletPayResult(walletPaid: amount, coinsUsed: 0, coinValue: 0);
  }
}

Widget _app(Widget home, {WalletPayRepository? pay}) => ProviderScope(
  overrides: [
    currentUserIdProvider.overrideWithValue(_me),
    profileProvider.overrideWith((ref) async => Profile({'id': _me, 'name': 'Aina Hassan'})),
    coinTradeRepositoryProvider.overrideWithValue(_FakeTrade()),
    if (pay != null) walletPayRepositoryProvider.overrideWithValue(pay),
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

    expect(find.text('AINA HASSAN'), findsOneWidget);
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
    expect(find.text('Scan to send GET.coin to AINA HASSAN'), findsOneWidget);
    expect(find.text(_me), findsOneWidget);
    expect(find.textContaining('GET.coin 300'), findsOneWidget);
    expect(find.byKey(const ValueKey('qr-amount')), findsNothing);
  });

  group('merchant pay', () {
    Future<void> pump(WidgetTester tester, _FakePay pay) async {
      tester.view.physicalSize = const Size(1000, 2400);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          MerchantPayView(qr: const MerchantQr('KEDAI RUNCIT 88'), onScanAgain: () {}),
          pay: pay,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('pays from GET.wallet with the code as the note', (tester) async {
      final pay = _FakePay();
      await pump(tester, pay);
      await tester.enterText(find.byKey(const ValueKey('pay-amount')), '12');
      await tester.pump();
      expect(find.text('Not enough balance in GET.wallet.'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('pay-amount')), '8.5');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('pay-confirm')));
      // The button spins behind the confirm dialog until it is answered.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.widgetWithText(FilledButton, 'Pay'));
      await tester.pumpAndSettle();

      expect(pay.calls.single.amount, 8.5);
      expect(pay.calls.single.note, 'QR payment — KEDAI RUNCIT 88');
      expect(pay.calls.single.coins, isFalse);
      expect(find.text('Payment Successful'), findsOneWidget);
    });

    testWidgets('GET.coin covers part, so a larger amount becomes payable', (tester) async {
      final pay = _FakePay();
      await pump(tester, pay);
      await tester.enterText(find.byKey(const ValueKey('pay-amount')), '12');
      await tester.tap(find.byKey(const ValueKey('pay-coins')));
      await tester.pump();
      expect(find.textContaining('covers RM'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pay-confirm')));
      // The button spins behind the confirm dialog until it is answered.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('from GET.coin'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Pay'));
      await tester.pumpAndSettle();
      expect(pay.calls.single.coins, isTrue);
      expect(find.textContaining('paid with GET.coin'), findsOneWidget);
    });

    testWidgets('shows a server refusal', (tester) async {
      final pay = _FakePay(error: Exception('insufficient_balance'));
      await pump(tester, pay);
      await tester.enterText(find.byKey(const ValueKey('pay-amount')), '5');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('pay-confirm')));
      // The button spins behind the confirm dialog until it is answered.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.widgetWithText(FilledButton, 'Pay'));
      await tester.pumpAndSettle();
      expect(find.text('Not enough balance in GET.wallet.'), findsOneWidget);
      expect(find.text('Payment Successful'), findsNothing);
    });
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
