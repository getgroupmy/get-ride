// Payment gateways (migration 0252): the admin's write-only secret keys
// (masked status, set, replace, clear — the value is never shown back), the
// account's webhook address to copy, Test connection, which account takes
// which payment; and the rider's GET.wallet top-up (amount, the provider's
// page, waiting for its answer, test mode, nothing set up) — in light and
// dark.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/screens/commerce/commerce_data.dart';
import 'package:get_ride/src/admin/screens/commerce/commerce_logic.dart';
import 'package:get_ride/src/admin/screens/commerce/payment_screens.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/payments_repository.dart';
import 'package:get_ride/src/features/wallet/wallet_topup.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'notice.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

const _supabase = 'https://proj.supabase.co';
const _secretTyped = 'whsec_typed_value_1234567';

/// The admin's repository, in memory: secrets are kept as the server
/// would show them (last 4 only), never their values.
class _FakeCommerce extends CommerceRepository {
  _FakeCommerce() : super(_db);

  final status = <String, GatewaySecretState>{
    'secretKey': GatewaySecretState(gatewayId: 'g1', field: 'secretKey', last4: 'wxyz', length: 32, updatedAt: DateTime(2026, 10, 20, 9)),
  };
  final sets = <(String, String, String)>[];
  final routes = <String, String?>{'wallet_topup': null, 'ride_card': null, 'dispatch': null};
  final tests = <(String, bool)>[];

  @override
  Future<List<GatewaySecretState>> gatewaySecretStatus() async => status.values.toList();

  @override
  Future<void> setGatewaySecret(String gatewayId, String field, String value) async {
    sets.add((gatewayId, field, value));
    if (value.isEmpty) {
      status.remove(field);
    } else {
      status[field] = GatewaySecretState(
        gatewayId: gatewayId,
        field: field,
        last4: value.length >= 12 ? value.substring(value.length - 4) : null,
        length: value.length,
        updatedAt: DateTime(2026, 10, 21, 9),
      );
    }
  }

  @override
  Future<Map<String, String?>> gatewayRouting() async => Map.of(routes);

  @override
  Future<void> setGatewayRouting(String purpose, String? gatewayId) async => routes[purpose] = gatewayId;

  @override
  Future<GatewayTestResult> testGateway(String gatewayId, {bool checkout = false}) async {
    tests.add((gatewayId, checkout));
    return const GatewayTestResult(result: 'ok', title: 'Connected', detail: 'Stripe accepted the secret key.');
  }
}

final _entries = <Entry>[
  (
    id: 'g1',
    values: {
      'providerId': 'stripe',
      'providerName': 'Stripe',
      'accountName': 'MY Live',
      'mode': 'Live',
      'active': true,
      'isDefault': true,
      'stripe_publishableKey': 'pk_live_abc',
    },
  ),
  (
    id: 'g2',
    values: {
      'providerId': 'billplz',
      'providerName': 'Billplz',
      'accountName': 'Sandbox',
      'mode': 'Sandbox',
      'active': true,
      'billplz_collectionId': 'col',
    },
  ),
];

/// The rider's payments, in memory.
class _FakePayments extends PaymentsRepository {
  _FakePayments(this.info) : super(_db);

  PaymentPurposeInfo info;
  final checkouts = <(String, double, String)>[];
  String nextStatus = 'paid';
  String applied = 'wallet_credited';
  int statusCalls = 0;

  @override
  Future<PaymentPurposeInfo> purposeInfo(String purpose) async => info;

  @override
  Future<PaymentCheckout> checkout(String purpose, double amount, String idempotencyKey) async {
    checkouts.add((purpose, amount, idempotencyKey));
    return PaymentCheckout(
      intent: PaymentIntentState(id: 'i1', reference: 'GR261021ABCDEF0123', status: 'pending', amount: amount, testMode: info.testMode),
      url: 'https://www.billplz.com/bills/b1',
      closeOn: const ['$_supabase/functions/v1/payments/return/'],
    );
  }

  @override
  Future<PaymentIntentState> status(String id) async {
    statusCalls++;
    final last = checkouts.last;
    return PaymentIntentState(
      id: id,
      reference: 'GR261021ABCDEF0123',
      status: nextStatus,
      amount: last.$2,
      applied: nextStatus == 'paid' ? applied : null,
      testMode: info.testMode,
    );
  }

  @override
  Stream<PaymentIntentState> watch(String id) => const Stream.empty();
}

/// The form dialog's own list (the last vertical one; text fields scroll sideways).
final _formScroll = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).last;

void main() {
  test('secret status reads as a mask, never a value', () {
    expect(secretStatusLine(null), 'Not set');
    final s = GatewaySecretState(gatewayId: 'g', field: 'f', last4: '1234', length: 30, updatedAt: DateTime(2026, 10, 20));
    expect(secretStatusLine(s), '•••• 1234 · updated 20 Oct 2026');
    expect(secretStatusLine(const GatewaySecretState(gatewayId: 'g', field: 'f', length: 6)), '•••• set (6 characters)');
  });

  test('the account that takes a payment: chosen, else default, else the only one', () {
    expect(effectiveGatewayFor('wallet_topup', {}, _entries), 'g1');
    expect(effectiveGatewayFor('wallet_topup', {'wallet_topup': 'g2'}, _entries), 'g2');
    final noDefault = [for (final e in _entries) (id: e.id, values: {...e.values, 'isDefault': false})];
    expect(effectiveGatewayFor('wallet_topup', {}, noDefault), isNull);
    expect(effectiveGatewayFor('wallet_topup', {}, noDefault.take(1).toList()), 'g1');
    // A chosen account that was switched off falls back.
    final off = [_entries[0], (id: 'g2', values: {..._entries[1].values, 'active': false})];
    expect(effectiveGatewayFor('wallet_topup', {'wallet_topup': 'g2'}, off), 'g1');
  });

  test('webhook and return addresses', () {
    expect(gatewayWebhookUrl('$_supabase/', 'stripe', 'g1'), '$_supabase/functions/v1/payments/webhook/stripe/g1');
    expect(gatewayReturnUrl(_supabase, 'senangpay', 'g9'), '$_supabase/functions/v1/payments/back/senangpay/g9');
  });

  test('a test answer without a result reads in words', () {
    expect(GatewayTestResult.fromJson({'error': 'admin_only'}).title, 'Edit access needed');
    expect(GatewayTestResult.fromJson(null).result, 'fail');
  });

  test('every provider lists its secret fields apart from its public ones', () {
    for (final p in gatewayProviders) {
      expect(p.fields.map((f) => f.key).toSet().length, p.fields.length, reason: p.id);
    }
    expect(gatewayProviders.map((p) => p.id), containsAll(['curlec', 'toyyibpay', '2c2p', 'adyen', 'xendit', 'ipay88', 'eghl']));
    expect(providerById('paydibs')!.charging, ChargeSupport.none);
    expect(providerById('senangpay')!.dashboardUrls, isTrue);
  });

  for (final b in Brightness.values) {
    final mode = b == Brightness.dark ? ' (dark)' : '';

    group('Admin → Payment Gateways$mode', () {
      Future<_FakeCommerce> pump(WidgetTester tester) async {
        tester.view.physicalSize = const Size(1000, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final repo = _FakeCommerce();
        await tester.pumpWidget(ProviderScope(
          retry: (_, _) => null,
          overrides: [
            supabaseProvider.overrideWithValue(_db),
            pageAccessProvider.overrideWith((ref, page) => AccessLevel.edit),
            commerceRepositoryProvider.overrideWithValue(repo),
            commerceEntriesProvider(paymentGatewayCategory).overrideWith((ref) async => _entries),
          ],
          child: MaterialApp(theme: appTheme(b), home: const PaymentGatewayScreen(supabaseUrl: _supabase)),
        ));
        await tester.pumpAndSettle();
        return repo;
      }

      // Through the row's menu: a tap on the row keeps its busy spinner while the form is open.
      Future<void> openG1(WidgetTester tester) async {
        await tester.tap(find.descendant(of: find.byKey(const ValueKey('gateway-g1')), matching: find.byType(PopupMenuButton<String>)));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Edit'));
        await tester.pumpAndSettle();
      }

      testWidgets('the list says which secrets are set; the routing card shows who takes what', (tester) async {
        await pump(tester);
        expect(find.text('Secret keys are write-only'), findsOneWidget);
        expect(find.textContaining('1 of 2 secret keys set'), findsOneWidget);
        expect(find.textContaining('1 required secret key not set'), findsOneWidget);
        expect(find.byKey(const ValueKey('gateway-routing')), findsOneWidget);
        expect(find.textContaining('Now: Stripe · MY Live'), findsNWidgets(3));
        expect(tester.takeException(), isNull);
      });

      testWidgets('a secret is set, replaced and cleared, and only its mask is ever shown', (tester) async {
        final repo = await pump(tester);
        await openG1(tester);
        expect(find.text('•••• wxyz · updated 20 Oct 2026'), findsOneWidget);
        expect(find.byKey(const ValueKey('secret-status-webhookSecret')), findsOneWidget);
        expect(find.descendant(of: find.byKey(const ValueKey('secret-webhookSecret')), matching: find.text('Not set')),
            findsOneWidget);
        // The webhook address to paste at Stripe.
        await tester.scrollUntilVisible(find.byKey(const ValueKey('webhook-url')), 200, scrollable: _formScroll);
        expect(tester.widget<SelectableText>(find.byKey(const ValueKey('webhook-url'))).data,
            '$_supabase/functions/v1/payments/webhook/stripe/g1');

        // Set the webhook secret: typed once, obscured, never shown back.
        await tester.tap(find.byKey(const ValueKey('secret-set-webhookSecret')));
        await tester.pumpAndSettle();
        final field = tester.widget<TextField>(find.byKey(const ValueKey('secret-value')));
        expect(field.obscureText, isTrue);
        await tester.enterText(find.byKey(const ValueKey('secret-value')), _secretTyped);
        await tester.tap(find.byKey(const ValueKey('secret-save')));
        await tester.pumpAndSettle();
        expect(repo.sets.single, ('g1', 'webhookSecret', _secretTyped));
        expect(find.textContaining('•••• 4567'), findsOneWidget);
        expect(find.textContaining(_secretTyped), findsNothing);
        expect(find.text('Replace'), findsNWidgets(2));

        await closeNotice(tester);
        // Clear the secret key.
        await tester.tap(find.byKey(const ValueKey('secret-clear-secretKey')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Clear'));
        await tester.pumpAndSettle();
        expect(repo.sets.last, ('g1', 'secretKey', ''));
        expect(find.descendant(of: find.byKey(const ValueKey('secret-secretKey')), matching: find.text('Not set')),
            findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('Test connection shows what the payments function said', (tester) async {
        final repo = await pump(tester);
        await openG1(tester);
        await tester.scrollUntilVisible(find.byKey(const ValueKey('gateway-test')), 200, scrollable: _formScroll);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('gateway-test')));
        await tester.pumpAndSettle();
        expect(repo.tests.single, ('g1', false));
        expect(find.byKey(const ValueKey('gateway-test-result')), findsOneWidget);
        expect(find.text('Connected'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('a new account sets its secrets after it is saved', (tester) async {
        await pump(tester);
        await tester.tap(find.text('Add gateway'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, 'Curlec');
        await tester.pumpAndSettle();
        await tester.tap(find.text('Curlec by Razorpay').last);
        await tester.pumpAndSettle();
        expect(find.textContaining('Save the account first'), findsOneWidget);
        expect(find.byKey(const ValueKey('secret-set-keySecret')), findsNothing);
        expect(find.byKey(const ValueKey('gateway-test')), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('choosing the account for top-ups', (tester) async {
        final repo = await pump(tester);
        await tester.tap(find.byKey(const ValueKey('gateway-route-wallet_topup-null')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Billplz · Sandbox (Sandbox)').last);
        await tester.pumpAndSettle();
        expect(repo.routes['wallet_topup'], 'g2');
        expect(find.textContaining('Now: Billplz · Sandbox (Sandbox)'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });

    group('GET.wallet top-up$mode', () {
      Future<(_FakePayments, List<PaymentCheckout>)> pump(WidgetTester tester, PaymentPurposeInfo info) async {
        tester.view.physicalSize = const Size(400, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final repo = _FakePayments(info);
        final opened = <PaymentCheckout>[];
        await tester.pumpWidget(ProviderScope(
          retry: (_, _) => null,
          overrides: [
            supabaseProvider.overrideWithValue(_db),
            paymentsRepositoryProvider.overrideWithValue(repo),
          ],
          child: MaterialApp(
            theme: appTheme(b),
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () => showWalletTopUp(context, open: (_, c) async => opened.add(c)),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        return (repo, opened);
      }

      Future<void> unmount(WidgetTester tester) async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 10));
      }

      testWidgets('pay with the top-up account; the wallet is credited when the provider says so', (tester) async {
        final (repo, opened) = await pump(tester, const PaymentPurposeInfo(available: true, providerName: 'Billplz'));
        expect(find.text('Pay with Billplz'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('topup-preset-100')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('topup-pay')));
        await tester.pumpAndSettle();
        expect(repo.checkouts.single.$1, 'wallet_topup');
        expect(repo.checkouts.single.$2, 100);
        expect(opened.single.url, 'https://www.billplz.com/bills/b1');
        expect(opened.single.closeOn, ['$_supabase/functions/v1/payments/return/']);
        expect(find.byKey(const ValueKey('topup-paid')), findsOneWidget);
        expect(find.textContaining('added to GET.wallet'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('topup-done')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('topup-paid')), findsNothing);
      });

      testWidgets('waiting, then the provider confirms', (tester) async {
        final (repo, _) = await pump(tester, const PaymentPurposeInfo(available: true, providerName: 'Stripe'));
        repo.nextStatus = 'pending';
        await tester.tap(find.byKey(const ValueKey('topup-pay')));
        // A spinner while it waits: pumped by hand.
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.byKey(const ValueKey('topup-waiting')), findsOneWidget);
        expect(find.byKey(const ValueKey('topup-reopen')), findsOneWidget);
        repo.nextStatus = 'paid';
        await tester.pump(const Duration(seconds: 3));
        await tester.pump();
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('topup-paid')), findsOneWidget);
        final calls = repo.statusCalls;
        await tester.pump(const Duration(seconds: 10));
        expect(repo.statusCalls, calls, reason: 'polling stops once settled');
        await unmount(tester);
      });

      testWidgets('an amount outside the limits is refused before anything is opened', (tester) async {
        final (repo, opened) = await pump(tester, const PaymentPurposeInfo(available: true, min: 5, max: 2000));
        await tester.enterText(find.byKey(const ValueKey('topup-amount')), '1');
        await tester.tap(find.byKey(const ValueKey('topup-pay')));
        await tester.pumpAndSettle();
        expect(find.textContaining('Enter an amount from'), findsOneWidget);
        expect(repo.checkouts, isEmpty);
        expect(opened, isEmpty);
        expect(tester.takeException(), isNull);
      });

      testWidgets('test mode says nothing is added', (tester) async {
        final (repo, _) = await pump(tester, const PaymentPurposeInfo(available: true, testMode: true, providerName: 'Billplz'));
        expect(find.byKey(const ValueKey('topup-test-mode')), findsOneWidget);
        repo.applied = 'test_mode';
        await tester.tap(find.byKey(const ValueKey('topup-pay')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('topup-paid-test')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('nothing set up: top-up says so', (tester) async {
        await pump(tester, const PaymentPurposeInfo(available: false));
        expect(find.byKey(const ValueKey('topup-unavailable')), findsOneWidget);
        expect(find.byKey(const ValueKey('topup-pay')), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('a declined payment can be tried again', (tester) async {
        final (repo, _) = await pump(tester, const PaymentPurposeInfo(available: true));
        repo.nextStatus = 'failed';
        await tester.tap(find.byKey(const ValueKey('topup-pay')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('topup-failed')), findsOneWidget);
        final key = repo.checkouts.single.$3;
        await tester.tap(find.byKey(const ValueKey('topup-again')));
        await tester.pumpAndSettle();
        repo.nextStatus = 'paid';
        await tester.tap(find.byKey(const ValueKey('topup-pay')));
        await tester.pumpAndSettle();
        expect(repo.checkouts.last.$3, isNot(key), reason: 'a new attempt is a new payment');
        expect(find.byKey(const ValueKey('topup-paid')), findsOneWidget);
      });
    });
  }
}
