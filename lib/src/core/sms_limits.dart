// Sign-in SMS limits (migration 0149): the admin's settings, how they are
// checked before saving, and how the attempt log is shown. Pure.

class SmsLimits {
  const SmsLimits({
    this.enabled = true,
    this.perPhonePerHour = 3,
    this.perPhonePerDay = 10,
    this.minResendSeconds = 60,
    this.globalPerHour = 500,
    this.codeValidMinutes = 5,
    this.allowedPrefixes = const ['+60'],
    this.blockedNumbers = const [],
    this.messageTemplate = defaultSmsTemplate,
    this.updatedAt,
  });

  final bool enabled;
  final int perPhonePerHour;
  final int perPhonePerDay;
  final int minResendSeconds;
  final int globalPerHour;

  /// How long a sign-in code is good for (migration 0188). A code the gateway
  /// hasn't sent by then is dropped, not sent late. Keep it equal to Supabase
  /// → Authentication → Phone → SMS OTP Expiry, which is what checks it.
  final int codeValidMinutes;

  /// Country prefixes codes may go to (`+60`); empty allows every country.
  final List<String> allowedPrefixes;
  final List<String> blockedNumbers;

  /// The message, with `{code}` where the code goes.
  final String messageTemplate;
  final DateTime? updatedAt;

  static SmsLimits fromRow(Map<String, dynamic> r) {
    int n(String k, int d) => (r[k] as num?)?.toInt() ?? d;
    List<String> l(String k) => [for (final v in (r[k] as List?) ?? const []) '$v'];
    return SmsLimits(
      enabled: r['enabled'] != false,
      perPhonePerHour: n('per_phone_per_hour', 3),
      perPhonePerDay: n('per_phone_per_day', 10),
      minResendSeconds: n('min_resend_seconds', 60),
      globalPerHour: n('global_per_hour', 500),
      codeValidMinutes: n('code_valid_minutes', 5),
      allowedPrefixes: l('allowed_prefixes'),
      blockedNumbers: l('blocked_numbers'),
      messageTemplate: (r['message_template'] as String?) ?? defaultSmsTemplate,
      updatedAt: DateTime.tryParse('${r['updated_at'] ?? ''}'),
    );
  }

  Map<String, dynamic> toPatch() => {
    'enabled': enabled,
    'per_phone_per_hour': perPhonePerHour,
    'per_phone_per_day': perPhonePerDay,
    'min_resend_seconds': minResendSeconds,
    'global_per_hour': globalPerHour,
    'code_valid_minutes': codeValidMinutes,
    'allowed_prefixes': allowedPrefixes,
    'blocked_numbers': blockedNumbers,
    'message_template': messageTemplate,
  };

  SmsLimits copyWith({
    bool? enabled,
    int? perPhonePerHour,
    int? perPhonePerDay,
    int? minResendSeconds,
    int? globalPerHour,
    int? codeValidMinutes,
    List<String>? allowedPrefixes,
    List<String>? blockedNumbers,
    String? messageTemplate,
  }) => SmsLimits(
    enabled: enabled ?? this.enabled,
    perPhonePerHour: perPhonePerHour ?? this.perPhonePerHour,
    perPhonePerDay: perPhonePerDay ?? this.perPhonePerDay,
    minResendSeconds: minResendSeconds ?? this.minResendSeconds,
    globalPerHour: globalPerHour ?? this.globalPerHour,
    codeValidMinutes: codeValidMinutes ?? this.codeValidMinutes,
    allowedPrefixes: allowedPrefixes ?? this.allowedPrefixes,
    blockedNumbers: blockedNumbers ?? this.blockedNumbers,
    messageTemplate: messageTemplate ?? this.messageTemplate,
    updatedAt: updatedAt,
  );
}

const defaultSmsTemplate = 'Your GET.ride code is {code}. Do not share it.';

/// Why [s] can't be saved, or null. The same limits the database holds.
String? smsLimitsProblem(SmsLimits s) {
  if (s.perPhonePerHour < 1 || s.perPhonePerHour > 20) return 'Codes per number per hour must be 1–20.';
  if (s.perPhonePerDay < 1 || s.perPhonePerDay > 50) return 'Codes per number per day must be 1–50.';
  if (s.perPhonePerDay < s.perPhonePerHour) return 'The daily limit can’t be lower than the hourly one.';
  if (s.minResendSeconds < 15 || s.minResendSeconds > 600) return 'Time between codes must be 15–600 seconds.';
  if (s.globalPerHour < 1 || s.globalPerHour > 100000) return 'The hourly total must be 1–100,000.';
  if (s.codeValidMinutes < 1 || s.codeValidMinutes > 60) return 'A code must be valid for 1–60 minutes.';
  for (final p in s.allowedPrefixes) {
    if (!RegExp(r'^\+\d{1,4}$').hasMatch(p)) return 'A country prefix looks like +60 ($p doesn’t).';
  }
  for (final b in s.blockedNumbers) {
    if (!RegExp(r'^\+\d{6,15}$').hasMatch(b)) {
      return 'A blocked number starts with + and the country code ($b doesn’t).';
    }
  }
  final t = s.messageTemplate.trim();
  if (!t.contains('{code}')) return 'The message must contain {code}, where the code goes.';
  if (t.length > 300) return 'The message is longer than 300 characters.';
  return null;
}

/// The entries of a comma, semicolon or line separated list, each tidied to
/// `+<digits>`, without repeats.
List<String> parsePhoneList(String input) {
  final out = <String>[];
  for (final raw in input.split(RegExp(r'[,;\n]+'))) {
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) continue;
    final v = '+$digits';
    if (!out.contains(v)) out.add(v);
  }
  return out;
}

/// A number as the activity panel shows it: the country part and the last
/// four digits, the rest hidden (`+6012•••4567`).
String maskPhone(String phone) {
  final digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.length <= 6) return phone;
  return '+${digits.substring(0, 4)}•••${digits.substring(digits.length - 4)}';
}

/// What a logged refusal means, in words.
String smsReasonLabel(String? reason) => switch (reason) {
  null || '' => '',
  'disabled' => 'SMS sign-in switched off',
  'gateway_offline' => 'No gateway phone online',
  'blocked_number' => 'Blocked number',
  'prefix' => 'Country not allowed',
  'resend_too_soon' => 'Asked again too soon',
  'per_phone_hour' => 'Hourly limit for the number',
  'per_phone_day' => 'Daily limit for the number',
  'global_hour' => 'Hourly total reached',
  'no_number' => 'No number',
  'no_code' => 'No code',
  final r => r,
};

class SmsLogEntry {
  const SmsLogEntry({required this.id, required this.phone, required this.status, this.reason, this.createdAt});

  final int id;
  final String phone;

  /// queued, blocked or failed.
  final String status;
  final String? reason;
  final DateTime? createdAt;

  static SmsLogEntry fromRow(Map<String, dynamic> r) => SmsLogEntry(
    id: (r['id'] as num?)?.toInt() ?? 0,
    phone: '${r['phone'] ?? ''}',
    status: '${r['status'] ?? ''}',
    reason: r['reason'] as String?,
    createdAt: DateTime.tryParse('${r['created_at'] ?? ''}'),
  );
}

typedef SmsActivity = ({int queued, int blocked, int failed});

SmsActivity smsActivityFrom(Object? rpc) {
  final row = rpc is List ? (rpc.isEmpty ? null : rpc.first) : rpc;
  int n(String k) => row is Map ? ((row[k] as num?)?.toInt() ?? 0) : 0;
  return (queued: n('queued'), blocked: n('blocked'), failed: n('failed'));
}
