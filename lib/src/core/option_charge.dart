/// A charge the admin sets on a ride option (Admin → Display Settings →
/// Ride Options): a fixed amount or a percentage of the fare. Every one
/// starts at zero, so nothing changes until the admin sets it. Pure.
library;

import 'dart:math' as math;

enum OptionChargeKind { fixed, percent }

class OptionCharge {
  const OptionCharge({this.kind = OptionChargeKind.fixed, this.value = 0});

  final OptionChargeKind kind;

  /// An amount, or a percentage of the fare.
  final double value;

  static const none = OptionCharge();

  /// The largest amount, and percentage, an admin may set.
  static const maxAmount = 10000.0;
  static const maxPercent = 100.0;

  bool get isPercent => kind == OptionChargeKind.percent;
  bool get isZero => value <= 0;

  /// What it adds to [fare], to the cent.
  double on(double fare) => cents(isPercent ? math.max(0, fare) * value / 100 : value);

  Map<String, Object> toJson() => {'kind': isPercent ? 'percent' : 'fixed', 'value': value};

  static OptionCharge fromJson(Object? raw) {
    if (raw is! Map) return none;
    final v = raw['value'];
    final n = v is num ? v.toDouble() : (v is String ? double.tryParse(v.trim()) : null);
    if (n == null || !n.isFinite || n <= 0) return none;
    final percent = raw['kind'] == 'percent';
    return OptionCharge(
      kind: percent ? OptionChargeKind.percent : OptionChargeKind.fixed,
      value: math.min(n, percent ? maxPercent : maxAmount),
    );
  }

  /// "RM5", "10%" (with [money] for an amount); "No charge" for none.
  String describe(String Function(double amount) money) =>
      isZero ? 'No charge' : (isPercent ? '${trimNumber(value)}% of the fare' : money(value));

  @override
  bool operator ==(Object other) => other is OptionCharge && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);
}

/// To the cent, never below zero.
double cents(double v) => (math.max(0, v) * 100).roundToDouble() / 100;

/// 5 as "5", 2.5 as "2.5".
String trimNumber(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : '$v';
