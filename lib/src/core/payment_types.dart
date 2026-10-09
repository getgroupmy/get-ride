/// The payment methods a rider picks from on the confirm sheet, as Admin →
/// Payment Type lists them (`settings_entries`, category `payment-type`):
/// the enabled ones, in the admin's order. The stored `payment_mode` is the
/// method's name, which is what the driver sees. Pure.
library;

/// What a method is, for its icon and colour.
enum PaymentKind { cash, wallet, card, other }

class PaymentChoice {
  const PaymentChoice(this.value, this.label, this.kind);

  /// Stored on the ride as `payment_mode`.
  final String value;

  /// Shown to the rider.
  final String label;
  final PaymentKind kind;

  @override
  bool operator ==(Object other) =>
      other is PaymentChoice && other.value == value && other.label == label && other.kind == kind;

  @override
  int get hashCode => Object.hash(value, label, kind);

  @override
  String toString() => 'PaymentChoice($value, $label, ${kind.name})';
}

/// What the confirm sheet offers when the admin list is empty or cannot be
/// read, so booking never loses its payment choice.
const builtInPayments = [
  PaymentChoice('Cash', 'Cash', PaymentKind.cash),
  PaymentChoice('Get Pay', 'GET.wallet', PaymentKind.wallet),
];

/// The kind of a method, from its code and then its name.
PaymentKind paymentKindOf(String name, [String? code]) {
  for (final raw in [code, name]) {
    final s = (raw ?? '').trim().toLowerCase();
    if (s.isEmpty) continue;
    if (s.contains('cash')) return PaymentKind.cash;
    if (s.contains('wallet') || s.contains('get pay') || s.contains('getpay') || s.contains('ewallet')) {
      return PaymentKind.wallet;
    }
    if (s.contains('card') || s.contains('credit') || s.contains('debit')) return PaymentKind.card;
  }
  return PaymentKind.other;
}

bool _enabled(Object? v) {
  if (v == null) return true;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return !const {'false', '0', 'off', 'no'}.contains(v.trim().toLowerCase());
  return true;
}

/// The enabled methods of the admin list (rows of `values` maps, already in
/// `position` order), each named once. Empty when none is usable.
List<PaymentChoice> paymentChoicesFrom(Iterable<Map<String, dynamic>> rows) {
  final seen = <String>{};
  return [
    for (final v in rows)
      if (_enabled(v['enabled']))
        if ('${v['name'] ?? ''}'.trim() case final name when name.isNotEmpty && seen.add(name.toLowerCase()))
          PaymentChoice(name, name, paymentKindOf(name, v['code'] is String ? v['code'] as String : null)),
  ];
}

/// [current] when it is still offered, else the first method offered: a
/// method the admin switches off, or one no longer listed, is not booked.
String resolvePayment(String current, List<PaymentChoice> choices) {
  if (choices.isEmpty) return current;
  return choices.any((c) => c.value == current) ? current : choices.first.value;
}

/// The offered method stored as [value], or the first one.
PaymentChoice paymentChoiceFor(String value, List<PaymentChoice> choices) {
  final list = choices.isEmpty ? builtInPayments : choices;
  return list.firstWhere((c) => c.value == value, orElse: () => list.first);
}
