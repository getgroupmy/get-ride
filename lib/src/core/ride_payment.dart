/// Paying for a ride when it ends (migration 0142): what the ride's payment
/// columns mean, which ways to pay the passenger is offered and whether
/// their balance covers it, and what a refused payment tells them. Pure.
library;

import 'dart:async';

import 'payment_types.dart';

/// `ride_requests.payment_status`. Null: a ride from before 0142, or one
/// that is not completed yet; nothing is asked of either side then.
enum RidePaymentStatus {
  /// Completed, nothing paid yet.
  due,

  /// The passenger says they paid in cash; the driver has to confirm.
  cashPending,

  /// Settled (`paid_method` says how).
  paid;

  static RidePaymentStatus? parse(Object? raw) => switch (raw) {
    'due' => due,
    'cash_pending' => cashPending,
    'paid' => paid,
    _ => null,
  };
}

/// How a ride was or will be paid: the stored `paid_method`.
enum RidePayMethod {
  getWallet('get_wallet', 'GET.wallet'),
  getCoin('get_coin', 'GET.coin'),
  cash('cash', 'cash');

  const RidePayMethod(this.db, this.label);
  final String db;
  final String label;

  static RidePayMethod? parse(Object? raw) {
    for (final m in values) {
      if (m.db == raw) return m;
    }
    return null;
  }
}

/// How long "Transaction not Successful" stays up before the passenger is
/// back at Pay now / Paid in cash.
const paymentFailedHold = Duration(seconds: 3);

/// How long the Done page (and the driver's paid trip) stays up before the
/// passenger goes home and the driver back to waiting for rides.
const paymentDoneClose = Duration(seconds: 5);

/// The ride was waiting on its payment and now is paid: the moment the
/// [paymentDoneClose] countdown starts. A ride already paid when the screen
/// opened doesn't start it.
bool paymentJustSettled(RidePaymentStatus? before, RidePaymentStatus? now) =>
    now == RidePaymentStatus.paid && (before == RidePaymentStatus.due || before == RidePaymentStatus.cashPending);


/// The GET.coin [due] costs at [coinsPerCurrency] GC a ringgit, rounded up
/// to the hundredth as the server charges it (`ride_pay`, 0174). The small
/// allowance keeps float noise from adding a hundredth.
double coinsForAmount(double due, double coinsPerCurrency) => (due * coinsPerCurrency * 100 - 1e-6).ceilToDouble() / 100;

/// One way to pay on the "Pay with" list.
class RidePayOption {
  const RidePayOption({
    required this.id,
    required this.label,
    this.method,
    this.detail,
    this.available = false,
    this.note,
  });

  /// Stable key for the row.
  final String id;
  final String label;

  /// What `ride_pay` is asked to use; null for a method the app can't
  /// charge yet.
  final RidePayMethod? method;

  /// The balance, or what it costs.
  final String? detail;
  final bool available;

  /// Why it can't be used, when it can't.
  final String? note;
}

/// The ways to pay [due]: GET.wallet and GET.coin with their balances (each
/// usable only when it covers the whole amount), then every other method the
/// admin lists, which no payment gateway charges yet. Cash is its own key
/// ("Paid in cash"), so it is not on this list. [coinsPerCurrency] null:
/// the GET.coin rate couldn't be read, so coins can't be priced.
List<RidePayOption> ridePayOptions({
  required double due,
  required double? walletBalance,
  required double? coinBalance,
  required double? coinsPerCurrency,
  required String Function(num) money,
  required String Function(num) coins,
  List<PaymentChoice> others = const [],
}) {
  final out = <RidePayOption>[];
  final wallet = walletBalance ?? 0;
  final walletOk = wallet + 0.005 >= due;
  out.add(
    RidePayOption(
      id: 'get_wallet',
      label: 'GET.wallet',
      method: RidePayMethod.getWallet,
      detail: 'Balance ${money(wallet)}',
      available: walletOk,
      note: walletOk ? null : 'Not enough balance',
    ),
  );
  final rate = coinsPerCurrency;
  if (rate == null || rate <= 0) {
    out.add(
      const RidePayOption(
        id: 'get_coin',
        label: 'GET.coin',
        method: RidePayMethod.getCoin,
        note: 'Not available right now',
      ),
    );
  } else {
    final need = coinsForAmount(due, rate);
    final have = coinBalance ?? 0;
    final coinOk = have + 0.005 >= need;
    out.add(
      RidePayOption(
        id: 'get_coin',
        label: 'GET.coin',
        method: RidePayMethod.getCoin,
        detail: '${coins(need)} needed · balance ${coins(have)}',
        available: coinOk,
        note: coinOk ? null : 'Not enough GET.coin',
      ),
    );
  }
  final seen = <String>{};
  for (final c in others) {
    if (c.kind == PaymentKind.cash || c.kind == PaymentKind.wallet) continue;
    if (!seen.add(c.label.toLowerCase())) continue;
    out.add(RidePayOption(id: 'other:${c.value}', label: c.label, note: 'Not available yet'));
  }
  return out;
}

/// Whether the method the ride was booked with ([paymentMode]) is cash, so
/// "Paid in cash" is the key put first.
bool bookedWithCash(String paymentMode) => paymentKindOf(paymentMode) == PaymentKind.cash;

/// What the passenger is told when a payment is refused, from the error the
/// server raised.
String ridePaymentFailure(Object error) {
  // ride_pay pays a ride once, so after a timeout trying again is safe.
  if (error is TimeoutException) return "The payment wasn't confirmed in time. Trying again won't charge you twice.";
  final s = '$error';
  if (s.contains('insufficient_balance')) return 'Not enough balance to pay this ride.';
  if (s.contains('amount_changed')) return 'The amount to pay has changed. Check it and pay again.';
  if (s.contains('coins_unavailable')) return 'GET.coin can\'t be used right now.';
  if (s.contains('ride_not_completed')) return 'The trip isn\'t complete yet.';
  if (s.contains('not_authorized')) return 'Sign in again to pay for this ride.';
  if (s.contains('no_driver')) return 'This ride has no driver to pay.';
  return 'The payment didn\'t go through. Please try again.';
}

/// What the passenger's Done page says was paid.
String ridePaidSummary(RidePayMethod? method, String amount) => switch (method) {
  RidePayMethod.cash => '$amount paid in cash',
  RidePayMethod.getWallet => '$amount paid with GET.wallet',
  RidePayMethod.getCoin => '$amount paid with GET.coin',
  null => '$amount paid',
};
