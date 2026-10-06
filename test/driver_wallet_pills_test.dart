import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/format.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/partner/driver_wallet_pills.dart';
import 'package:get_ride/src/features/wallet/wallet_screen.dart' show walletBalancesProvider;
import 'package:go_router/go_router.dart';

void main() {
  test('the driver reads GET.credit and GET.wallet, zero for one not opened', () {
    final w = driverWallets([WalletBalance('get_credit', -12.5, 'MYR'), WalletBalance('get_coin', 40, 'MYR')]);
    expect(w.credit, -12.5);
    expect(w.wallet, 0);
    expect(driverWallets(const []).currency, 'MYR');
  });

  test('GET.credit has its own label', () {
    expect(WalletBalance('get_credit', 0, 'MYR').label, 'GET.credit');
  });

  Future<void> pump(WidgetTester tester, List<WalletBalance> balances) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: DriverWalletPills()),
        ),
        GoRoute(
          path: '/wallet',
          builder: (_, _) => const Scaffold(body: Text('wallet')),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [walletBalancesProvider.overrideWith((ref) async => balances)],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('both balances show; owed commission is flagged; a tap opens the wallet', (tester) async {
    await pump(tester, [WalletBalance('get_credit', -12.5, 'MYR'), WalletBalance('get_wallet', 80, 'MYR')]);
    expect(find.text(formatMoney(-12.5, 'MYR')), findsOneWidget);
    expect(find.textContaining('80.00'), findsOneWidget);
    final credit = tester.widget<Card>(find.byKey(const ValueKey('wallet-pill-credit')));
    final theme = Theme.of(tester.element(find.byKey(const ValueKey('wallet-pill-credit'))));
    expect(credit.color, theme.colorScheme.errorContainer);
    await tester.tap(find.byKey(const ValueKey('wallet-pill-wallet')));
    await tester.pumpAndSettle();
    expect(find.text('wallet'), findsOneWidget);
  });
}
