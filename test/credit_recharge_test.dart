import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/credit_recharge.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/wallet_pay_repository.dart';
import 'package:get_ride/src/features/wallet/wallet_screen.dart';
import 'package:get_ride/src/providers.dart';

class _FakeRecharge implements CreditRechargeRepository {
  _FakeRecharge({this.error});
  final Object? error;
  final calls = <double>[];

  @override
  Future<void> recharge(double amount) async {
    calls.add(amount);
    if (error != null) throw error!;
  }
}

void main() {
  group('rules', () {
    test('parses amounts with at most two decimals', () {
      expect(parseRechargeAmount('12'), 12);
      expect(parseRechargeAmount(' 1,000.5 '), 1000.5);
      expect(parseRechargeAmount('3.25'), 3.25);
      expect(parseRechargeAmount('3.255'), isNull);
      expect(parseRechargeAmount('-5'), isNull);
      expect(parseRechargeAmount('abc'), isNull);
      expect(parseRechargeAmount(''), isNull);
    });

    test('blocks empty, zero and over-balance amounts', () {
      expect(rechargeCreditProblem(null, 50), 'Enter an amount greater than 0.');
      expect(rechargeCreditProblem(0, 50), 'Enter an amount greater than 0.');
      expect(rechargeCreditProblem(50.01, 50), 'Not enough balance in GET.wallet.');
      expect(rechargeCreditProblem(50, 50), isNull);
    });

    test('maps RPC refusals', () {
      expect(rechargeCreditErrorMessage(Exception('insufficient_balance')), 'Not enough balance in GET.wallet.');
      expect(rechargeCreditErrorMessage(Exception('not_authorized')), contains('sign in again'));
      expect(rechargeCreditErrorMessage(Exception('boom')), 'Recharge failed. Please try again.');
    });
  });

  group('wallet screen', () {
    Future<void> pump(WidgetTester tester, _FakeRecharge repo, {bool partner = true}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1200);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            walletBalancesProvider.overrideWith(
              (ref) async => [WalletBalance('get_wallet', 40, 'MYR'), WalletBalance('get_credit', 5, 'MYR')],
            ),
            walletTxProvider.overrideWith((ref) async => const <WalletTransaction>[]),
            partnerProvider.overrideWith((ref) async => partner ? Partner({'id': 'p1'}) : null),
            creditRechargeRepositoryProvider.overrideWithValue(repo),
          ],
          child: const MaterialApp(home: WalletScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('riders do not see the recharge', (tester) async {
      await pump(tester, _FakeRecharge(), partner: false);
      expect(find.byKey(const ValueKey('wallet-recharge-open')), findsNothing);
    });

    testWidgets('an amount over GET.wallet is refused before the RPC', (tester) async {
      final repo = _FakeRecharge();
      await pump(tester, repo);
      await tester.tap(find.byKey(const ValueKey('wallet-recharge-open')));
      await tester.pumpAndSettle();
      expect(find.text('GET.wallet balance: RM40.00'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('recharge-amount')), '41');
      await tester.tap(find.byKey(const ValueKey('recharge-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('Not enough balance in GET.wallet.'), findsOneWidget);
      expect(repo.calls, isEmpty);
    });

    testWidgets('a valid amount recharges and closes', (tester) async {
      final repo = _FakeRecharge();
      await pump(tester, repo);
      await tester.tap(find.byKey(const ValueKey('wallet-recharge-open')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('recharge-amount')), '25.50');
      await tester.tap(find.byKey(const ValueKey('recharge-confirm')));
      await tester.pumpAndSettle();
      expect(repo.calls, [25.5]);
      expect(find.byKey(const ValueKey('recharge-amount')), findsNothing);
    });

    testWidgets('a refusal stays in the dialog with the reason', (tester) async {
      final repo = _FakeRecharge(error: Exception('insufficient_balance'));
      await pump(tester, repo);
      await tester.tap(find.byKey(const ValueKey('wallet-recharge-open')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('recharge-amount')), '10');
      await tester.tap(find.byKey(const ValueKey('recharge-confirm')));
      await tester.pumpAndSettle();
      expect(repo.calls, [10]);
      expect(find.text('Not enough balance in GET.wallet.'), findsOneWidget);
    });
  });
}
