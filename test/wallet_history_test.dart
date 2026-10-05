import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/wallet_history.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/wallet/wallet_history_screen.dart';
import 'package:get_ride/src/providers.dart';

WalletTransaction tx(String id, String wallet, String kind, double amount, String at, {String? note, String? method}) =>
    WalletTransaction({
      'id': id,
      'wallet_type': wallet,
      'kind': kind,
      'amount': amount,
      'note': note,
      'method': method,
      'created_at': at,
    });

Future<void> tapChip(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
}

void main() {
  group('labels and amounts', () {
    test('kinds read like Expo, unknown kinds show their note', () {
      expect(walletTxLabel('topup', null), 'Wallet Reload');
      expect(walletTxLabel('redeem', 'x'), 'Paid with GET.coin');
      expect(walletTxLabel('transfer_in', null), 'Transfer Received');
      expect(walletTxLabel('mystery', ' Manual fix '), 'Manual fix');
      expect(walletTxLabel('mystery', null), 'Adjustment');
    });

    test('categories', () {
      expect(walletTxCategory('commission'), WalletTxCategory.ride);
      expect(walletTxCategory('recharge_out'), WalletTxCategory.transfer);
      expect(walletTxCategory('topup'), WalletTxCategory.reload);
      expect(walletTxCategory('referral'), WalletTxCategory.referral);
      expect(walletTxCategory('mystery'), WalletTxCategory.other);
    });

    test('amounts in the wallet unit', () {
      expect(walletAmountText('get_wallet', -12.5), '-RM12.50');
      expect(walletAmountText('get_credit', 3), '+RM3.00');
      expect(walletAmountText('get_coin', 1250), '+1,250 GC');
      expect(walletAmountText('get_coin', -12.5), '-12.50 GC');
      expect(walletAmountText('get_coin', 40, signed: false), '40 GC');
    });

    test('payment methods', () {
      expect(walletTxMethodLabel(null), 'Wallet Balance');
      expect(walletTxMethodLabel('qr_scan'), 'QR payment');
      expect(walletTxMethodLabel('trade_sell'), 'GET.coin trade');
      expect(walletTxMethodLabel('fpx'), 'fpx');
    });
  });

  group('months', () {
    test('six months back across a year boundary', () {
      final m = historyMonths(DateTime(2026, 2, 14));
      expect(m.map((e) => e.label).take(3), ['This Month', 'Last Month', 'December 2025']);
      expect(m.length, 6);
      expect(m.last, HistoryMonth(2025, 9, ''));
      expect(m.first.start, DateTime(2026, 2));
      expect(m.first.end, DateTime(2026, 3));
    });
  });

  test('filters and day groups keep the ledger order', () {
    final d = DateTime(2026, 10, 5, 9).toUtc().toIso8601String();
    final d2 = DateTime(2026, 10, 4, 22).toUtc().toIso8601String();
    final old = DateTime(2026, 9, 30, 12).toUtc().toIso8601String();
    final txs = [
      tx('1', 'get_wallet', 'payment', -5, d),
      tx('2', 'get_coin', 'reward', 10, d),
      tx('3', 'get_wallet', 'topup', 50, d2),
      tx('4', 'get_wallet', 'payment', -1, old),
    ];
    final oct = HistoryMonth(2026, 10, 'Oct');
    expect(filterWalletHistory(txs, month: oct).map((t) => t.id), ['1', '2', '3']);
    expect(filterWalletHistory(txs, walletType: 'get_wallet', category: WalletTxCategory.ride).map((t) => t.id), [
      '1',
      '4',
    ]);
    final groups = groupWalletHistoryByDay(filterWalletHistory(txs, month: oct));
    expect(groups.map((g) => g.day), [DateTime(2026, 10, 5), DateTime(2026, 10, 4)]);
    expect(groups.first.txs.map((t) => t.id), ['1', '2']);
  });

  testWidgets('history screen filters by wallet and category and shows details', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final now = DateTime(2026, 10, 5, 12);
    final at = DateTime(2026, 10, 5, 9).toUtc().toIso8601String();
    final rows = [
      tx('a1', 'get_wallet', 'payment', -8.5, at, note: 'QR payment — KEDAI', method: 'qr_scan'),
      tx('a2', 'get_coin', 'referral', 100, at),
      tx('a3', 'get_wallet', 'topup', 20, at),
    ];
    HistoryMonth? asked;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          partnerProvider.overrideWith((ref) async => null),
          walletHistoryProvider.overrideWith((ref, m) async {
            asked = m;
            return m == historyMonths(now).first ? rows : const [];
          }),
        ],
        child: MaterialApp(home: WalletHistoryScreen(now: now)),
      ),
    );
    await tester.pumpAndSettle();

    expect(asked, historyMonths(now).first);
    expect(find.text('Payment'), findsOneWidget);
    expect(find.text('Referral Bonus'), findsOneWidget);
    expect(find.text('BONUS'), findsOneWidget);
    expect(find.text('GET.credit'), findsNothing);

    await tapChip(tester, find.widgetWithText(ChoiceChip, 'GET.coin'));
    await tester.pumpAndSettle();
    expect(find.text('Payment'), findsNothing);
    expect(find.text('+100 GC'), findsOneWidget);

    await tapChip(tester, find.widgetWithText(ChoiceChip, 'All'));
    await tapChip(tester, find.widgetWithText(FilterChip, 'Reload'));
    await tester.pumpAndSettle();
    expect(find.text('Wallet Reload'), findsOneWidget);
    expect(find.text('Payment'), findsNothing);

    await tapChip(tester, find.widgetWithText(FilterChip, 'Refund'));
    await tester.pumpAndSettle();
    expect(find.text('No refund transactions for this month.'), findsOneWidget);

    await tapChip(tester, find.widgetWithText(FilterChip, 'Ride'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Payment'));
    await tester.pumpAndSettle();
    expect(find.text('Transaction details'), findsOneWidget);
    expect(find.text('QR payment'), findsOneWidget);
    expect(find.text('QR payment — KEDAI'), findsOneWidget);
    expect(find.text('-RM8.50'), findsWidgets);
    Navigator.of(tester.element(find.text('Transaction details'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('history-month')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Last Month').last);
    await tester.pumpAndSettle();
    expect(asked, historyMonths(now)[1]);
    expect(find.text('No ride transactions for last month.'), findsOneWidget);
  });
}
