// Web UX round 31 (150-154), at 360x640 and 640x360, light and dark: the
// history filters on one fading line each, the wallet cards side by side
// from 600 wide, the trip filters fading at the edge, notification bodies
// capitalised, and Receive's Share / Download pinned in view.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/commerce/get_coin.dart';
import 'package:get_ride/src/core/inbox.dart';
import 'package:get_ride/src/core/trip_history.dart';
import 'package:get_ride/src/core/wallet_history.dart';
import 'package:get_ride/src/data/coin_trade_repository.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/trip_history_repository.dart';
import 'package:get_ride/src/features/ride/trips_screen.dart';
import 'package:get_ride/src/features/wallet/wallet_history_screen.dart';
import 'package:get_ride/src/features/wallet/wallet_qr_screens.dart';
import 'package:get_ride/src/features/wallet/wallet_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/edge_fade_scroll.dart';

const _me = '11111111-1111-1111-1111-111111111111';

WalletTransaction _tx(String id, String kind, double amount, DateTime at) => WalletTransaction({
  'id': id,
  'wallet_type': 'get_wallet',
  'kind': kind,
  'amount': amount,
  'created_at': at.toUtc().toIso8601String(),
});

class _Trips implements TripHistoryRepository {
  @override
  Future<List<RideRequest>> page(
    TripHistoryRole role, {
    TripHistoryFilter filter = TripHistoryFilter.all,
    DateTime? before,
    int limit = tripHistoryPageSize,
  }) async => const [];

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Trade implements CoinTradeRepository {
  @override
  Future<CoinTradeQuote> quote() async => const CoinTradeQuote(
    walletBalance: 10,
    coinBalance: 300,
    settings: GetCoinSettings(coinsPerCurrency: 100),
    stats: CoinMarketStats(),
  );

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Future<void> _at(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  test('wallet cards sit side by side from a 600 wide screen; a phone keeps one a row', () {
    expect(walletCardWidth(568, 3), 181, reason: '600 wide: all three in a row');
    expect(walletCardWidth(608, 3), 194, reason: '640 wide, on its side');
    expect(walletCardWidth(380, 3), 380, reason: 'a 412 phone: one a row');
    expect(walletCardWidth(328, 2), 328, reason: 'a 360 phone: one a row');
  });

  test('a stored notification body reads with a capital first letter, nothing else changed', () {
    expect(inboxBodyText('your car is waiting at KLCC.'), 'Your car is waiting at KLCC.');
    expect(inboxBodyText('Already fine'), 'Already fine');
    expect(inboxBodyText(''), '');
    expect(inboxBodyText('éclair at the gate'), 'Éclair at the gate');
  });

  for (final b in Brightness.values) {
    for (final size in const [Size(360, 640), Size(640, 360)]) {
      final at = '${size.width.round()}x${size.height.round()}, ${b.name}';

      testWidgets('history: each filter row is one fading line and the list shows above the fold ($at)', (tester) async {
        await _at(tester, size);
        final now = DateTime(2026, 5, 20, 12);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              partnerProvider.overrideWith((ref) async => null),
              walletHistoryProvider.overrideWith(
                (ref, m) async => m == historyMonths(now).first ? [_tx('a1', 'payment', -8.5, now)] : const [],
              ),
            ],
            child: MaterialApp(theme: ThemeData(brightness: b), home: WalletHistoryScreen(now: now)),
          ),
        );
        await tester.pumpAndSettle();
        for (final row in ['Wallet', 'Type']) {
          final r = tester.getRect(find.byKey(ValueKey('history-filter-$row')));
          expect(r.height, lessThan(60), reason: '$row: one line, not a wrap');
        }
        expect(find.text('Payment'), findsOneWidget);
        expect(tester.getRect(find.text('Payment')).top, lessThan(size.height), reason: 'the list starts above the fold');
        // Every option is still reachable: the row scrolls to its last chip.
        final type = find.byKey(const ValueKey('history-filter-Type'));
        final pos = tester.state<ScrollableState>(find.descendant(of: type, matching: find.byType(Scrollable))).position;
        pos.jumpTo(pos.maxScrollExtent);
        await tester.pumpAndSettle();
        final last = find.descendant(of: type, matching: find.byType(FilterChip)).last;
        expect(tester.getRect(last).right, lessThanOrEqualTo(size.width + 1));
        expect(tester.takeException(), isNull);
      });

      testWidgets('trips: the status chips fade at the edge with more, and Cancelled is reachable ($at)', (tester) async {
        await _at(tester, size);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [tripHistoryRepositoryProvider.overrideWithValue(_Trips())],
            child: MaterialApp(theme: ThemeData(brightness: b), home: const TripsScreen()),
          ),
        );
        await tester.pumpAndSettle();
        final filters = find.byKey(const ValueKey('trip-filters'));
        final cancelled = find.byKey(const ValueKey('trip-filter-cancelled'));
        if (tester.getRect(cancelled).right > size.width) {
          expect(find.descendant(of: filters, matching: find.byKey(const ValueKey('edge-fade'))), findsOneWidget,
              reason: 'cut off, so faded as a hint');
          expect(tester.state<State>(filters), isA<State<EdgeFadeScroll>>());
        }
        await tester.ensureVisible(cancelled);
        await tester.pumpAndSettle();
        expect(tester.getRect(cancelled).right, lessThanOrEqualTo(size.width));
        expect(tester.takeException(), isNull);
      });

      testWidgets('wallet: the balance cards ($at)', (tester) async {
        await _at(tester, size);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              walletBalancesProvider.overrideWith(
                (ref) async => [
                  WalletBalance('get_wallet', 40, 'MYR'),
                  WalletBalance('get_coin', 300, 'MYR'),
                  WalletBalance('get_credit', 5, 'MYR'),
                ],
              ),
              walletTxProvider.overrideWith((ref) async => const <WalletTransaction>[]),
              partnerProvider.overrideWith((ref) async => null),
            ],
            child: MaterialApp(theme: ThemeData(brightness: b), home: const WalletScreen()),
          ),
        );
        await tester.pumpAndSettle();
        final cards = find.byKey(const ValueKey('wallet-card-get_wallet'));
        if (cards.evaluate().isNotEmpty) {
          final tops = {
            for (final w in ['get_wallet', 'get_coin', 'get_credit'])
              tester.getRect(find.byKey(ValueKey('wallet-card-$w'))).top.round(),
          };
          expect(tops, hasLength(size.width >= 600 ? 1 : 3), reason: size.width >= 600 ? 'one row' : 'one a row');
        }
        expect(tester.takeException(), isNull);
      });

      testWidgets('Receive (GET.coin QR): Share and Download pinned in view ($at)', (tester) async {
        await _at(tester, size);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              currentUserIdProvider.overrideWithValue(_me),
              profileProvider.overrideWith((ref) async => Profile({'id': _me, 'name': 'Aina Hassan'})),
              coinTradeRepositoryProvider.overrideWithValue(_Trade()),
              walletBalancesProvider.overrideWith((ref) async => const []),
              walletTxProvider.overrideWith((ref) async => const []),
            ],
            child: MaterialApp(theme: ThemeData(brightness: b), home: const ReceiveQrScreen(coin: true)),
          ),
        );
        await tester.pumpAndSettle();
        for (final key in ['wallet-qr-share', 'wallet-qr-save']) {
          final r = tester.getRect(find.byKey(ValueKey(key)));
          expect(r.bottom, lessThanOrEqualTo(size.height), reason: '$key on screen without scrolling');
          expect(r.top, greaterThanOrEqualTo(0));
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
