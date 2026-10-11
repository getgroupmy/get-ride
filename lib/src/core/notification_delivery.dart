/// How well trip pushes reach people (migration 0144's
/// `notification_delivery_stats`), for the admin push screen. Pure.
library;

class NotificationDelivery {
  const NotificationDelivery({
    required this.kind,
    required this.priority,
    required this.sent,
    required this.delivered,
    required this.pending,
    required this.gaveUp,
    this.avgAckSeconds,
    this.avgAttempts,
  });

  final String kind;
  final String priority;
  final int sent;
  final int delivered;
  final int pending;
  final int gaveUp;
  final double? avgAckSeconds;
  final double? avgAttempts;

  static int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
  static double? _num(Object? v) => v is num ? v.toDouble() : double.tryParse('$v');

  factory NotificationDelivery.fromRow(Map<String, dynamic> r) => NotificationDelivery(
    kind: '${r['kind'] ?? ''}',
    priority: '${r['priority'] ?? 'normal'}',
    sent: _int(r['sent']),
    delivered: _int(r['delivered']),
    pending: _int(r['pending']),
    gaveUp: _int(r['gave_up']),
    avgAckSeconds: _num(r['avg_ack_seconds']),
    avgAttempts: _num(r['avg_attempts']),
  );

  /// Share of these pushes some app acknowledged, 0–1; null with none sent.
  double? get rate => sent == 0 ? null : delivered / sent;

  /// What the admin reads for [kind].
  String get label => switch (kind) {
    'ride_status' => 'Trip updates',
    'ride_payment' => 'Payments',
    _ => kind,
  };
}

/// "97%", or "—" with nothing sent.
String deliveryRateText(double? rate) => rate == null ? '—' : '${(rate * 100).round()}%';

/// "4 s" / "2 min", how long acknowledging took on average; "—" when unknown.
String ackTimeText(double? seconds) {
  if (seconds == null) return '—';
  if (seconds < 90) return '${seconds.round()} s';
  return '${(seconds / 60).round()} min';
}

/// The whole picture over [rows]: what share of all pushes arrived.
double? overallDeliveryRate(Iterable<NotificationDelivery> rows) {
  var sent = 0, delivered = 0;
  for (final r in rows) {
    sent += r.sent;
    delivered += r.delivered;
  }
  return sent == 0 ? null : delivered / sent;
}
