// SMS fallback for trips (migration 0150): an alert the app never confirmed
// goes out as an SMS through the gateway phone. The admin's settings and what
// the fallback did, as the admin page shows them. Pure.

/// The waits the admin can pick between a push and its SMS.
const smsFallbackWaits = [30, 60, 90, 120, 180, 300];

/// The gateway routes that may send it.
const smsFallbackChannels = {'otp': 'OTP route', 'support_message': 'Support message route'};

class SmsFallbackSettings {
  const SmsFallbackSettings({
    this.enabled = false,
    this.afterSeconds = 60,
    this.criticalOnly = true,
    this.channel = 'otp',
    this.perPhonePerHour = 6,
    this.updatedAt,
  });

  final bool enabled;
  final int afterSeconds;
  final bool criticalOnly;
  final String channel;
  final int perPhonePerHour;
  final DateTime? updatedAt;

  static SmsFallbackSettings fromRow(Map<String, dynamic> r) {
    int n(String k, int d) => (r[k] as num?)?.toInt() ?? d;
    final channel = r['channel'];
    return SmsFallbackSettings(
      enabled: r['enabled'] == true,
      afterSeconds: n('after_seconds', 60),
      criticalOnly: r['critical_only'] != false,
      channel: channel is String && smsFallbackChannels.containsKey(channel) ? channel : 'otp',
      perPhonePerHour: n('per_phone_per_hour', 6),
      updatedAt: DateTime.tryParse('${r['updated_at'] ?? ''}'),
    );
  }

  Map<String, dynamic> toPatch() => {
    'enabled': enabled,
    'after_seconds': afterSeconds,
    'critical_only': criticalOnly,
    'channel': channel,
    'per_phone_per_hour': perPhonePerHour,
  };

  SmsFallbackSettings copyWith({
    bool? enabled,
    int? afterSeconds,
    bool? criticalOnly,
    String? channel,
    int? perPhonePerHour,
  }) => SmsFallbackSettings(
    enabled: enabled ?? this.enabled,
    afterSeconds: afterSeconds ?? this.afterSeconds,
    criticalOnly: criticalOnly ?? this.criticalOnly,
    channel: channel ?? this.channel,
    perPhonePerHour: perPhonePerHour ?? this.perPhonePerHour,
    updatedAt: updatedAt,
  );
}

/// Why [s] can't be saved, or null. Mirrors the table's checks.
String? smsFallbackProblem(SmsFallbackSettings s) {
  if (s.afterSeconds < 20 || s.afterSeconds > 600) return 'The wait must be between 20 seconds and 10 minutes.';
  if (s.perPhonePerHour < 1 || s.perPhonePerHour > 30) return 'Texts per number per hour must be between 1 and 30.';
  if (!smsFallbackChannels.containsKey(s.channel)) return 'Pick the gateway route that sends it.';
  return null;
}

/// "1 min 30 s", "45 s", "2 min".
String smsFallbackWaitLabel(int seconds) {
  final m = seconds ~/ 60, s = seconds % 60;
  if (m == 0) return '$s s';
  return s == 0 ? '$m min' : '$m min $s s';
}

/// What the fallback did over a period (`sms_fallback_summary`).
class SmsFallbackSummary {
  const SmsFallbackSummary({this.alerts = 0, this.confirmed = 0, this.smsQueued = 0, this.smsSkipped = 0});
  final int alerts;
  final int confirmed;
  final int smsQueued;
  final int smsSkipped;

  /// The share of alerts the app confirmed, 0–100; null with no alerts.
  int? get confirmedPercent => alerts == 0 ? null : (confirmed * 100 / alerts).round();
}

SmsFallbackSummary smsFallbackSummaryFrom(Object? rows) {
  final row = rows is List && rows.isNotEmpty ? rows.first : rows;
  if (row is! Map) return const SmsFallbackSummary();
  int n(String k) => (row[k] as num?)?.toInt() ?? 0;
  return SmsFallbackSummary(
    alerts: n('alerts'),
    confirmed: n('confirmed'),
    smsQueued: n('sms_queued'),
    smsSkipped: n('sms_skipped'),
  );
}
