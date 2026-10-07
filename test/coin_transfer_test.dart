import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/commerce/get_coin.dart';
import 'package:get_ride/src/core/coin_trade.dart';
import 'package:get_ride/src/core/coin_transfer.dart';
import 'package:get_ride/src/data/coin_trade_repository.dart';
import 'package:get_ride/src/data/coin_transfer_repository.dart';
import 'package:get_ride/src/features/wallet/coin_trade_screen.dart';
import 'package:get_ride/src/features/wallet/incoming_transfer_listener.dart';
import 'package:get_ride/src/providers.dart';

const _me = '11111111-1111-1111-1111-111111111111';
const _friend = '22222222-2222-2222-2222-222222222222';

class _FakeTrade implements CoinTradeRepository {
  @override
  Future<CoinTradeQuote> quote() async => const CoinTradeQuote(
    walletBalance: 10,
    coinBalance: 40,
    settings: GetCoinSettings(coinsPerCurrency: 10),
    stats: CoinMarketStats(),
  );

  @override
  Future<CoinTradeResult> trade(CoinTradeDirection direction, double coins, double ratePerGC) =>
      throw UnimplementedError();
}

class _FakeTransfers implements CoinTransferRepository {
  _FakeTransfers({this.requestError, this.respondStatus = TransferStatus.accepted});

  final Object? requestError;
  final TransferStatus respondStatus;
  final requests = <(TransferRecipient, double, String?)>[];
  final responses = <(String, bool)>[];
  final cancelled = <String>[];
  final watched = StreamController<CoinTransferRequest>.broadcast();
  final incoming = StreamController<CoinTransferRequest>.broadcast();

  @override
  Future<SentTransfer> request(TransferRecipient to, double coins, {String? note}) async {
    if (requestError != null) throw requestError!;
    requests.add((to, coins, note));
    return SentTransfer(
      requestId: 'r1',
      coins: coins,
      recipientName: 'Aisyah',
      expiresAt: DateTime.now().add(const Duration(minutes: 15)),
    );
  }

  @override
  Future<({TransferStatus status, double coins, String? fromName})> respond(
    String requestId, {
    required bool accept,
  }) async {
    responses.add((requestId, accept));
    return (status: accept ? respondStatus : TransferStatus.declined, coins: 25.0, fromName: 'Ali');
  }

  @override
  Future<void> cancel(String requestId) async => cancelled.add(requestId);

  @override
  Future<CoinTransferRequest?> fetch(String requestId) async => null;

  @override
  Future<List<CoinTransferRequest>> pendingIncoming(String userId) async => const [];

  @override
  Stream<CoinTransferRequest> watchIncoming(String userId) => incoming.stream;

  @override
  Stream<CoinTransferRequest> watchRequest(String requestId) => watched.stream;
}

CoinTransferRequest _req({
  String id = 'r1',
  TransferStatus status = TransferStatus.pending,
  String? toName = 'Aisyah',
  Duration expiresIn = const Duration(minutes: 10),
}) => CoinTransferRequest(
  id: id,
  fromUserId: _friend,
  fromName: 'Ali',
  toUserId: _me,
  toName: toName,
  coins: 25,
  note: 'lunch',
  status: status,
  expiresAt: DateTime.now().add(expiresIn),
);

void main() {
  group('transfer logic', () {
    test('recipient: wallet id, getpay QR or phone', () {
      expect(parseRecipient('  $_friend '), (userId: _friend, phone: null));
      expect(parseRecipient('getpay://pay?to=${_friend.toUpperCase()}'), (userId: _friend, phone: null));
      expect(parseRecipient('+60 12-345 6789'), (userId: null, phone: '+60 12-345 6789'));
      expect(parseRecipient('12345'), isNull);
      expect(parseRecipient(''), isNull);
    });

    test('send problems', () {
      String? p(String to, double coins) =>
          coinSendProblem(coins: coins, coinBalance: 40, recipient: parseRecipient(to), selfId: _me);
      expect(p('abc', 5), 'Enter a phone number or wallet ID.');
      expect(p(_me, 5), "You can't send coins to yourself.");
      expect(p(_friend, 0), 'Enter an amount greater than 0.');
      expect(p(_friend, 41), 'Not enough GET.coin to send.');
      expect(p('0123456789', 40), isNull);
    });

    test('row parsing', () {
      final r = CoinTransferRequest.fromRow({
        'id': 'x',
        'from_user_id': _friend,
        'from_name': '',
        'to_user_id': _me,
        'to_name': 'Me',
        'coins': '12.5',
        'note': null,
        'status': 'declined',
        'expires_at': '2026-01-01T00:15:00Z',
      });
      expect(r.fromName, isNull);
      expect(r.coins, 12.5);
      expect(r.status, TransferStatus.declined);
      expect(r.isOpen(DateTime.utc(2026)), isFalse);
      expect(parseTransferStatus('weird'), TransferStatus.pending);
      final pending = CoinTransferRequest.fromRow({'status': 'pending', 'expires_at': '2026-01-01T00:15:00Z'});
      expect(pending.isOpen(DateTime.utc(2026)), isTrue);
      expect(pending.isOpen(DateTime.utc(2026, 1, 1, 0, 16)), isFalse);
    });

    test('error and outcome wording', () {
      expect(coinSendErrorMessage('recipient_not_found'), 'Recipient not found. Check the number and try again.');
      expect(coinSendErrorMessage('P0001 insufficient_coins'), 'Not enough GET.coin to send.');
      expect(coinSendErrorMessage('self_transfer'), "You can't send coins to yourself.");
      expect(coinRespondErrorMessage('request_not_pending'), 'This transfer request was already handled.');
      expect(senderOutcome(_req(), formattedCoins: '25 GC'), isNull);
      expect(
        senderOutcome(_req(status: TransferStatus.accepted), formattedCoins: '25 GC'),
        'Aisyah accepted. 25 GC sent.',
      );
      expect(
        senderOutcome(_req(status: TransferStatus.declined, toName: null), formattedCoins: '25 GC'),
        'The recipient declined. No coins were sent.',
      );
      expect(recipientOutcome(TransferStatus.accepted, formattedCoins: '25 GC', fromName: 'Ali'), (
        ok: true,
        message: 'You received 25 GC from Ali.',
      ));
      expect(recipientOutcome(TransferStatus.declined, formattedCoins: '25 GC', fromName: 'Ali').message, isNull);
      expect(recipientOutcome(TransferStatus.failed, formattedCoins: '25 GC', fromName: null).ok, isFalse);
    });

    test('sent transfer from the RPC', () {
      final s = SentTransfer.fromRpc({'request_id': 'abc', 'recipient_name': 'Aisyah', 'coins': 5}, coins: 9);
      expect((s.requestId, s.recipientName, s.coins), ('abc', 'Aisyah', 5.0));
      expect(SentTransfer.fromRpc(null, coins: 9).coins, 9);
    });
  });

  group('send tab', () {
    Future<void> pump(WidgetTester tester, _FakeTransfers transfers) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            coinTradeRepositoryProvider.overrideWithValue(_FakeTrade()),
            coinTransferRepositoryProvider.overrideWithValue(transfers),
            currentUserIdProvider.overrideWithValue(_me),
          ],
          child: const MaterialApp(home: CoinTradeScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
    }

    Future<void> fillAndSend(WidgetTester tester, String to, String coins) async {
      await tester.enterText(find.byKey(const ValueKey('coin-recipient')), to);
      await tester.enterText(find.byKey(const ValueKey('coin-amount')), coins);
      await tester.pump();
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Send GET.coin'));
      await tester.tap(find.widgetWithText(FilledButton, 'Send GET.coin'));
      // The button spins behind the confirm dialog until it is answered.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Send request'));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('sends a request and reports the acceptance', (tester) async {
      final transfers = _FakeTransfers();
      await pump(tester, transfers);
      expect(find.textContaining('Fixed rate'), findsNothing);
      expect(find.text(_me), findsOneWidget);

      await fillAndSend(tester, '012-345 6789', '25');
      expect(transfers.requests.single.$1, (userId: null, phone: '012-345 6789'));
      expect(transfers.requests.single.$2, 25);
      expect(find.text('Waiting for Aisyah'), findsOneWidget);

      transfers.watched.add(_req(status: TransferStatus.accepted));
      // The Send key keeps spinning behind the dialog until it is closed.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Aisyah accepted. 25 GC sent.'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Aisyah accepted. 25 GC sent.'), findsOneWidget); // now on the form
      expect(find.text('Waiting for Aisyah'), findsNothing);
    });

    testWidgets('the sender can withdraw a request', (tester) async {
      final transfers = _FakeTransfers();
      await pump(tester, transfers);
      await fillAndSend(tester, _friend, '10');
      await tester.tap(find.text('Cancel request'));
      // The Send key keeps spinning behind the dialog until it is closed.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(transfers.cancelled, ['r1']);
      expect(find.text('Request cancelled. No coins were sent.'), findsOneWidget);
    });

    testWidgets('blocks sending to yourself and shows server refusals', (tester) async {
      final transfers = _FakeTransfers(requestError: Exception('recipient_not_found'));
      await pump(tester, transfers);
      await tester.enterText(find.byKey(const ValueKey('coin-recipient')), _me);
      await tester.enterText(find.byKey(const ValueKey('coin-amount')), '5');
      await tester.pump();
      expect(find.text("You can't send coins to yourself."), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Send GET.coin')).onPressed, isNull);

      await tester.enterText(find.byKey(const ValueKey('coin-recipient')), '0199999999');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Send GET.coin'));
      // The button spins behind the confirm dialog until it is answered.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Send request'));
      await tester.pumpAndSettle();
      expect(find.text('Recipient not found. Check the number and try again.'), findsOneWidget);
    });
  });

  group('incoming popup', () {
    Future<void> pump(WidgetTester tester, _FakeTransfers transfers) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            coinTransferRepositoryProvider.overrideWithValue(transfers),
            currentUserIdProvider.overrideWithValue(_me),
          ],
          child: MaterialApp(
            home: const Scaffold(body: Text('Home')),
            builder: (_, child) => IncomingTransferListener(child: child!),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('accepting shows what arrived', (tester) async {
      final transfers = _FakeTransfers();
      await pump(tester, transfers);
      expect(find.byKey(const ValueKey('incoming-transfer')), findsNothing);

      transfers.incoming.add(_req());
      await tester.pump();
      await tester.pump();
      expect(find.text('Ali wants to send you'), findsOneWidget);
      expect(find.text('25 GC'), findsOneWidget);
      expect(find.text('"lunch"'), findsOneWidget);

      await tester.tap(find.text('Accept'));
      await tester.pump();
      await tester.pump();
      expect(transfers.responses, [('r1', true)]);
      expect(find.text('You received 25 GC from Ali.'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pump();
      expect(find.text('You received 25 GC from Ali.'), findsNothing);
    });

    testWidgets('declining closes quietly; a withdrawn request disappears', (tester) async {
      final transfers = _FakeTransfers();
      await pump(tester, transfers);
      transfers.incoming
        ..add(_req())
        ..add(_req(id: 'r2'));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Decline'));
      await tester.pump();
      await tester.pump();
      expect(transfers.responses, [('r1', false)]);
      expect(find.text('Ali wants to send you'), findsOneWidget); // r2 is next

      transfers.incoming.add(_req(id: 'r2', status: TransferStatus.cancelled));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('incoming-transfer')), findsNothing);
    });

    testWidgets('an accept the sender can no longer fund explains why', (tester) async {
      final transfers = _FakeTransfers(respondStatus: TransferStatus.failed);
      await pump(tester, transfers);
      transfers.incoming.add(_req());
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Accept'));
      await tester.pump();
      await tester.pump();
      expect(find.text('The sender no longer has enough GET.coin for this transfer.'), findsOneWidget);
    });

    testWidgets('an expired request is dropped from the screen', (tester) async {
      final transfers = _FakeTransfers();
      await pump(tester, transfers);
      transfers.incoming.add(_req(expiresIn: const Duration(seconds: 5)));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('incoming-transfer')), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      expect(find.byKey(const ValueKey('incoming-transfer')), findsNothing);
    });
  });
}
