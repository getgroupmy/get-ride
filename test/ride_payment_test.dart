import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/commerce/get_coin.dart' show GetCoinSettings;
import 'package:get_ride/src/core/payment_types.dart';
import 'package:get_ride/src/core/push_logic.dart';
import 'package:get_ride/src/core/ride_payment.dart';
import 'package:get_ride/src/data/app_display_repository.dart' show paymentChoicesProvider;
import 'package:get_ride/src/data/coin_trade_repository.dart' show coinSettingsProvider;
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/partner/partner_trip_screen.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/features/wallet/wallet_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

RideRequest ride(Map<String, dynamic> extra) => RideRequest({
  'id': 'r1',
  'rider_id': 'me',
  'partner_id': 'driver',
  'partner_name': 'Ali',
  'status': 'completed',
  'fare': 20,
  'ride_fare': 20,
  'currency': 'MYR',
  'payment_mode': 'Cash',
  'pickup_name': 'KLCC',
  'drop_name': 'KL Sentral',
  'pickup_lat': 3.1579,
  'pickup_lng': 101.7116,
  'drop_lat': 3.1340,
  'drop_lng': 101.6860,
  ...extra,
});

class _FakeRides implements RideRepository {
  final log = <String>[];
  Object? payError;

  @override
  Future<double> claimRideReward(RideRequest r) async => 0;

  @override
  Future<void> payRide(String id, RidePayMethod method, {double? expected}) async {
    log.add('pay:${method.db}${expected == null ? '' : '@$expected'}');
    if (payError != null) throw payError!;
  }

  @override
  Future<void> payRideCash(String id) async => log.add('cash');

  @override
  Future<void> confirmRideCash(String id) async => log.add('confirm');

  @override
  Future<void> publishPartnerLocation(String id, double lat, double lng, double? heading) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String _money(num v) => 'RM${v.toStringAsFixed(2)}';
String _coins(num v) => '${v.toStringAsFixed(0)} GC';

void main() {
  group('pure', () {
    test('statuses and methods parse from the row', () {
      expect(RidePaymentStatus.parse('due'), RidePaymentStatus.due);
      expect(RidePaymentStatus.parse('cash_pending'), RidePaymentStatus.cashPending);
      expect(RidePaymentStatus.parse('paid'), RidePaymentStatus.paid);
      expect(RidePaymentStatus.parse(null), isNull);
      expect(RidePayMethod.parse('get_coin'), RidePayMethod.getCoin);
      expect(RidePayMethod.parse('card'), isNull);
      expect(ride({'payment_status': 'paid', 'paid_method': 'cash', 'paid_amount': 25}).paidAmount, 25);
      expect(ride({}).paymentStatus, isNull, reason: 'a database without 0142 asks nothing');
    });

    test('coins are priced to the hundredth as the server charges', () {
      expect(coinsForAmount(118.2, 10), 1182);
      expect(coinsForAmount(2.345, 3), 7.04);
      // Rounded up, never down: RM1 at 0.333 GC a ringgit takes 0.34 GC.
      expect(coinsForAmount(1, 0.333), 0.34);
      expect(coinsForAmount(1.1, 3), 3.3);
    });

    test('wallet and coin are usable only when they cover the whole amount', () {
      final options = ridePayOptions(
        due: 25,
        walletBalance: 30,
        coinBalance: 100,
        coinsPerCurrency: 10,
        money: _money,
        coins: _coins,
        others: const [
          PaymentChoice('Cash', 'Cash', PaymentKind.cash),
          PaymentChoice('Get Pay', 'GET.wallet', PaymentKind.wallet),
          PaymentChoice('Visa', 'Visa', PaymentKind.card),
          PaymentChoice('Boost', 'Boost', PaymentKind.other),
        ],
      );
      expect(options.map((o) => o.id), ['get_wallet', 'get_coin', 'other:Visa', 'other:Boost']);
      expect(options[0].available, isTrue);
      expect(options[1].available, isFalse);
      expect(options[1].note, 'Not enough GET.coin');
      expect(options[1].detail, '250 GC needed · balance 100 GC');
      expect(options[2].available, isFalse);
      expect(options[2].method, isNull);
      expect(options[2].note, 'Not available yet');
    });

    test('no coin rate: GET.coin is not offered as payable', () {
      final options = ridePayOptions(
        due: 5,
        walletBalance: null,
        coinBalance: 1000,
        coinsPerCurrency: null,
        money: _money,
        coins: _coins,
      );
      expect(options[0].available, isFalse);
      expect(options[1].available, isFalse);
    });

    test('a refusal is told in words', () {
      expect(
        ridePaymentFailure(const PostgrestException(message: 'insufficient_balance')),
        'Not enough balance to pay this ride.',
      );
      expect(ridePaymentFailure(Exception('boom')), 'The payment didn\'t go through. Please try again.');
      expect(ridePaymentFailure(Exception('amount_changed')), contains('has changed'));
      expect(ridePaymentFailure(TimeoutException('slow')), contains("won't charge you twice"));
      expect(ridePaidSummary(RidePayMethod.cash, 'RM25.00'), 'RM25.00 paid in cash');
      expect(bookedWithCash('Cash'), isTrue);
      expect(bookedWithCash('Get Pay'), isFalse);
    });

    test('the close countdown starts only when a waiting payment lands', () {
      expect(paymentJustSettled(RidePaymentStatus.due, RidePaymentStatus.paid), isTrue);
      expect(paymentJustSettled(RidePaymentStatus.cashPending, RidePaymentStatus.paid), isTrue);
      expect(paymentJustSettled(null, RidePaymentStatus.paid), isFalse, reason: 'already paid when opened');
      expect(paymentJustSettled(RidePaymentStatus.paid, RidePaymentStatus.paid), isFalse);
      expect(paymentDoneClose, const Duration(seconds: 5));
    });

    test('a payment push opens each side\'s trip', () {
      expect(pushRouteFor({'type': 'ride_payment', 'request_id': 'r1', 'role': 'rider'}), '/ride/r1');
      expect(pushRouteFor({'type': 'ride_payment', 'request_id': 'r1', 'role': 'partner'}), '/drive/trip/r1');
    });
  });

  group('passenger', () {
    Future<(_FakeRides, StreamController<RideRequest>)> pump(
      WidgetTester tester, {
      double wallet = 30,
      double coins = 0,
      ThemeMode mode = ThemeMode.light,
    }) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rides = _FakeRides();
      final rows = StreamController<RideRequest>();
      addTearDown(rows.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            rideRepositoryProvider.overrideWithValue(rides),
            rideStreamProvider.overrideWith((ref, id) => rows.stream),
            walletBalancesProvider.overrideWith(
              (ref) async => [WalletBalance('get_wallet', wallet, 'MYR'), WalletBalance('get_coin', coins, 'MYR')],
            ),
            walletTxProvider.overrideWith((ref) async => const []),
            coinSettingsProvider.overrideWith((ref) async => const GetCoinSettings(coinsPerCurrency: 10)),
            paymentChoicesProvider.overrideWith(
              (ref) async => const [
                PaymentChoice('Cash', 'Cash', PaymentKind.cash),
                PaymentChoice('Visa', 'Visa', PaymentKind.card),
              ],
            ),
          ],
          child: MaterialApp(
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            themeMode: mode,
            home: const RideTrackingScreen(requestId: 'r1'),
          ),
        ),
      );
      return (rides, rows);
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('no payment status: nothing is asked', (tester) async {
      final (_, rows) = await pump(tester);
      rows.add(ride({}));
      await settle(tester);
      expect(find.byKey(const ValueKey('ride-payment')), findsNothing);
    });

    testWidgets('the total with the driver\'s charges, then Pay now with GET.wallet ends on Done', (tester) async {
      final (rides, rows) = await pump(tester);
      rows.add(ride({'payment_status': 'due', 'toll_charges': 5}));
      await settle(tester);
      expect(find.byKey(const ValueKey('payment-added-charges')), findsOneWidget);
      expect(find.byKey(const ValueKey('payment-tolls')), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('payment-total')), matching: find.text('RM25.00')),
        findsOneWidget,
      );
      expect(find.text('Enough'), findsOneWidget);
      expect(find.text('Not enough'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('payment-pay-now')));
      await settle(tester);
      expect(find.byKey(const ValueKey('payment-options')), findsOneWidget);
      final coin = tester.widget<ListTile>(find.byKey(const ValueKey('payment-option-get_coin')));
      expect(coin.enabled, isFalse);
      final visa = tester.widget<ListTile>(find.byKey(const ValueKey('payment-option-other:Visa')));
      expect(visa.enabled, isFalse);

      await tester.tap(find.byKey(const ValueKey('payment-option-get_wallet')));
      await settle(tester);
      expect(rides.log, ['pay:get_wallet@25.0'], reason: 'the amount shown goes with the payment');
      expect(find.byKey(const ValueKey('payment-done')), findsOneWidget);

      rows.add(ride({'payment_status': 'paid', 'paid_method': 'get_wallet', 'paid_amount': 25, 'toll_charges': 5}));
      await settle(tester);
      expect(find.text('RM25.00 paid with GET.wallet'), findsOneWidget);
      expect(find.byKey(const ValueKey('payment-close')), findsOneWidget);
    });

    testWidgets('a refused payment says so for 3 seconds, then back to the two keys', (tester) async {
      final (rides, rows) = await pump(tester);
      rides.payError = const PostgrestException(message: 'insufficient_balance');
      rows.add(ride({'payment_status': 'due'}));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('payment-pay-now')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('payment-option-get_wallet')));
      await settle(tester);
      expect(find.text('Transaction not Successful'), findsOneWidget);
      expect(find.text('Not enough balance to pay this ride.'), findsOneWidget);
      expect(find.text('Back in 3 s'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Back in 2 s'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
      expect(find.byKey(const ValueKey('payment-failed')), findsNothing);
      expect(find.byKey(const ValueKey('payment-pay-now')), findsOneWidget);
      expect(find.byKey(const ValueKey('payment-cash')), findsOneWidget);
    });

    testWidgets('paid in cash waits for the driver, then Done (dark mode)', (tester) async {
      final (rides, rows) = await pump(tester, mode: ThemeMode.dark);
      rows.add(ride({'payment_status': 'due'}));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('payment-cash')));
      await settle(tester);
      expect(rides.log, ['cash']);
      expect(find.text('Pending confirmation'), findsOneWidget);

      rows.add(ride({'payment_status': 'cash_pending', 'paid_method': 'cash'}));
      await settle(tester);
      expect(find.text('Pending confirmation'), findsOneWidget);

      rows.add(ride({'payment_status': 'paid', 'paid_method': 'cash', 'paid_amount': 20}));
      await settle(tester);
      expect(find.text('RM20.00 paid in cash'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a ride already paid when opened shows no popup', (tester) async {
      final (_, rows) = await pump(tester);
      rows.add(ride({'payment_status': 'paid', 'paid_method': 'cash', 'paid_amount': 20}));
      await settle(tester);
      expect(find.byKey(const ValueKey('ride-payment')), findsNothing);
    });
  });

  group('driver', () {
    Future<(_FakeRides, StreamController<RideRequest>)> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rides = _FakeRides();
      final rows = StreamController<RideRequest>();
      addTearDown(rows.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            rideRepositoryProvider.overrideWithValue(rides),
            rideStreamProvider.overrideWith((ref, id) => rows.stream),
            tripFixProvider.overrideWithValue(() async => null),
            currentUserIdProvider.overrideWithValue(null),
          ],
          child: const MaterialApp(home: PartnerTripScreen(requestId: 'r1')),
        ),
      );
      return (rides, rows);
    }

    RideRequest driverRide(Map<String, dynamic> extra) =>
        RideRequest({...ride(extra).raw, 'rider_id': 'rider', 'partner_id': 'me'});

    testWidgets('cash the passenger says they paid is confirmed by the driver', (tester) async {
      final (rides, rows) = await pump(tester);
      rows.add(driverRide({'payment_status': 'due'}));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('trip-payment-due')), findsOneWidget);

      rows.add(driverRide({'payment_status': 'cash_pending', 'paid_method': 'cash'}));
      await tester.pump();
      await tester.pump();
      expect(find.text('Passenger paid in cash'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('trip-confirm-cash')));
      await tester.tap(find.byKey(const ValueKey('trip-confirm-cash')));
      await tester.pump();
      expect(rides.log, ['confirm']);

      rows.add(driverRide({'payment_status': 'paid', 'paid_method': 'cash', 'paid_amount': 20}));
      await tester.pump();
      await tester.pump();
      expect(find.text('Cash received'), findsOneWidget);
      expect(find.byKey(const ValueKey('trip-confirm-cash')), findsNothing);
    });

    testWidgets('paid with GET.wallet: nothing left to collect', (tester) async {
      final (_, rows) = await pump(tester);
      rows.add(driverRide({'payment_status': 'paid', 'paid_method': 'get_wallet', 'paid_amount': 20}));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('trip-collect-wallet')), findsOneWidget);
      expect(find.text('Paid with GET.wallet'), findsNWidgets(2));
    });
  });

  group('closes by itself', () {
    Future<(_FakeRides, StreamController<RideRequest>)> pump(WidgetTester tester, String start, Widget screen) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rides = _FakeRides();
      final rows = StreamController<RideRequest>();
      addTearDown(rows.close);
      final router = GoRouter(
        initialLocation: start,
        routes: [
          GoRoute(path: '/', builder: (_, _) => const Text('home')),
          GoRoute(path: '/drive', builder: (_, _) => const Text('waiting for rides')),
          GoRoute(path: '/ride/r1', builder: (_, _) => screen),
          GoRoute(path: '/drive/trip/r1', builder: (_, _) => screen),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            rideRepositoryProvider.overrideWithValue(rides),
            rideStreamProvider.overrideWith((ref, id) => rows.stream),
            walletBalancesProvider.overrideWith((ref) async => [WalletBalance('get_wallet', 50, 'MYR')]),
            walletTxProvider.overrideWith((ref) async => const []),
            coinSettingsProvider.overrideWith((ref) async => const GetCoinSettings(coinsPerCurrency: 10)),
            paymentChoicesProvider.overrideWith((ref) async => const []),
            tripFixProvider.overrideWithValue(() async => null),
            currentUserIdProvider.overrideWithValue(null),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      return (rides, rows);
    }

    testWidgets('the passenger\'s Done page goes home after 5 seconds', (tester) async {
      final (_, rows) = await pump(tester, '/ride/r1', const RideTrackingScreen(requestId: 'r1'));
      rows.add(ride({'payment_status': 'cash_pending', 'paid_method': 'cash'}));
      await tester.pump();
      await tester.pump();
      rows.add(ride({'payment_status': 'paid', 'paid_method': 'cash', 'paid_amount': 20}));
      await tester.pump();
      await tester.pump();
      expect(find.text('Close (5)'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Close (4)'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('the driver goes back to waiting for rides 5 seconds after the payment lands', (tester) async {
      final (_, rows) = await pump(tester, '/drive/trip/r1', const PartnerTripScreen(requestId: 'r1'));
      RideRequest r(Map<String, dynamic> extra) =>
          RideRequest({...ride(extra).raw, 'rider_id': 'rider', 'partner_id': 'me'});
      rows.add(r({'payment_status': 'due'}));
      await tester.pump();
      await tester.pump();
      expect(find.text('Back to requests'), findsOneWidget);
      rows.add(r({'payment_status': 'paid', 'paid_method': 'get_wallet', 'paid_amount': 20}));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Back to requests (4)'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('waiting for rides'), findsOneWidget);
    });
  });
}
