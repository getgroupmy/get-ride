// Payments through the gateway accounts in Admin → Payment Gateways (0252):
// what a kind of payment can be paid with, opening a provider's checkout
// through the `payments` edge function, and waiting for its answer. The
// function settles the payment (a GET.wallet top-up is credited once by the
// server); the app only shows it.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers.dart';
import 'live_query.dart';

/// Whether a kind of payment can be paid now (payment_purpose_info).
class PaymentPurposeInfo {
  const PaymentPurposeInfo({
    required this.available,
    this.providerName,
    this.testMode = false,
    this.currency = 'MYR',
    this.min = 5,
    this.max = 2000,
  });

  factory PaymentPurposeInfo.fromJson(Object? j) {
    final m = j is Map ? j : const {};
    double n(Object? v, double d) => v is num ? v.toDouble() : double.tryParse('$v') ?? d;
    return PaymentPurposeInfo(
      available: m['available'] == true,
      providerName: m['provider_name'] as String?,
      testMode: m['test_mode'] == true,
      currency: '${m['currency'] ?? 'MYR'}',
      min: n(m['min'], 5),
      max: n(m['max'], 2000),
    );
  }

  final bool available;
  final String? providerName;
  final bool testMode;
  final String currency;
  final double min;
  final double max;
}

/// A payment's state, as the payer may see it.
class PaymentIntentState {
  const PaymentIntentState({
    required this.id,
    required this.reference,
    required this.status,
    required this.amount,
    this.currency = 'MYR',
    this.applied,
    this.testMode = false,
  });

  factory PaymentIntentState.fromJson(Map<String, dynamic> m) => PaymentIntentState(
        id: '${m['id']}',
        reference: '${m['reference'] ?? ''}',
        status: '${m['status'] ?? 'pending'}',
        amount: m['amount'] is num ? (m['amount'] as num).toDouble() : double.tryParse('${m['amount']}') ?? 0,
        currency: '${m['currency'] ?? 'MYR'}',
        applied: m['applied'] as String?,
        testMode: m['test_mode'] == true,
      );

  final String id;
  final String reference;
  final String status;
  final double amount;
  final String currency;

  /// What the server did with a paid one: 'wallet_credited', 'test_mode', …
  final String? applied;
  final bool testMode;

  bool get pending => status == 'pending';
}

/// A checkout to open: a hosted page, or (iPay88) a form the browser posts.
class PaymentCheckout {
  const PaymentCheckout({required this.intent, this.url, this.form, this.closeOn = const []});

  factory PaymentCheckout.fromJson(Map<String, dynamic> m) {
    final form = m['form'] is Map ? Map<String, dynamic>.from(m['form'] as Map) : null;
    return PaymentCheckout(
      intent: PaymentIntentState.fromJson(m),
      url: m['checkout_url'] as String?,
      form: form == null
          ? null
          : (
              action: '${form['action']}',
              fields: {for (final e in (form['fields'] as Map? ?? const {}).entries) '${e.key}': '${e.value}'},
            ),
      closeOn: [for (final p in m['close_on'] is List ? m['close_on'] as List : const []) '$p'],
    );
  }

  final PaymentIntentState intent;
  final String? url;
  final ({String action, Map<String, String> fields})? form;

  /// Addresses that mean the payer is done (the function's return pages).
  final List<String> closeOn;
}

/// A refusal, by the code the function or the database gave.
class PaymentException implements Exception {
  const PaymentException(this.code);
  final String code;

  @override
  String toString() => code;
}

/// [code] in words for the payer.
String paymentErrorMessage(Object e) {
  final code = e is PaymentException ? e.code : '$e';
  return switch (code) {
    'invalid_amount' => 'That amount can\'t be paid. Check the minimum and maximum.',
    'too_many_payments' => 'Too many payments in the last hour. Try again later.',
    'no_gateway' || 'gateway_not_ready' || 'purpose_not_open' => 'Top-up isn\'t available right now.',
    'not_signed_in' => 'Sign in again to pay.',
    'missing_credentials' || 'provider_error' => 'The payment provider couldn\'t start the payment. Try again later.',
    _ => 'The payment couldn\'t be started. Check your connection and try again.',
  };
}

/// An idempotency key for one payer's attempt (a repeated tap reuses it).
String newPaymentKey([Random? r]) {
  final rand = r ?? Random.secure();
  return List.generate(24, (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[rand.nextInt(36)]).join();
}

class PaymentsRepository {
  PaymentsRepository(this._db);
  final SupabaseClient _db;

  Future<PaymentPurposeInfo> purposeInfo(String purpose) async =>
      PaymentPurposeInfo.fromJson(await _db.rpc('payment_purpose_info', params: {'p_purpose': purpose}));

  Future<Map<String, dynamic>> _invoke(String route, Map<String, dynamic> body) async {
    try {
      final res = await _db.functions.invoke('payments/$route', body: body);
      final data = res.data is String ? jsonDecode(res.data as String) : res.data;
      return Map<String, dynamic>.from(data as Map);
    } on FunctionException catch (e) {
      Object? d = e.details;
      if (d is String) {
        try {
          d = jsonDecode(d);
        } catch (_) {}
      }
      throw PaymentException(d is Map && d['error'] != null ? '${d['error']}' : 'http_${e.status}');
    }
  }

  /// Opens a checkout for [amount] (RM). The same [idempotencyKey] gives the same payment.
  Future<PaymentCheckout> checkout(String purpose, double amount, String idempotencyKey) async =>
      PaymentCheckout.fromJson(
        await _invoke('checkout', {'purpose': purpose, 'amount': amount, 'idempotency_key': idempotencyKey}),
      );

  /// The payment now (the function asks the provider while it is pending).
  Future<PaymentIntentState> status(String id) async => PaymentIntentState.fromJson(await _invoke('status', {'id': id}));

  /// The payment's row as it changes (the owner reads their own, 0252).
  /// Read again on every change and, while realtime is down, every few
  /// seconds.
  Stream<PaymentIntentState> watch(String id) => liveQuery<Map<String, dynamic>?>(
        _db,
        table: 'payment_intents',
        column: 'id',
        value: id,
        read: () => _db.from('payment_intents').select().eq('id', id).maybeSingle(),
      ).where((row) => row != null).map((row) => PaymentIntentState.fromJson(row!));
}

final paymentsRepositoryProvider = Provider((ref) => PaymentsRepository(ref.watch(supabaseProvider)));

final walletTopUpInfoProvider = FutureProvider.autoDispose<PaymentPurposeInfo>(
  (ref) => ref.watch(paymentsRepositoryProvider).purposeInfo('wallet_topup'),
);
