// The partner selfie check when going online (migration 0290): what the
// server answers before Go online, the admin's settings (Admin › Dispatch ›
// Partner selfie checks), the watch list's rules and the words for each.
// Pure, so the rules' words and the parsing are tested without a database.
// The server decides when a check is due (online_selfie_check_start); the
// app only asks it, on a phone.
library;

import 'package:flutter/foundation.dart';

/// Where the app runs, as the server's check is asked: only 'android' and
/// 'ios' are ever checked.
String onlineSelfiePlatform({bool web = kIsWeb, TargetPlatform? platform}) {
  if (web) return 'web';
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    _ => 'desktop',
  };
}

/// Whether a check can be asked on [platform] at all.
bool onlineSelfieOnPhone(String platform) => platform == 'android' || platform == 'ios';

/// The server's answer before going online.
@immutable
class OnlineSelfieDue {
  const OnlineSelfieDue({
    required this.due,
    this.id,
    this.reason = 'random',
    this.answerSeconds = defaultAnswerSeconds,
    this.blocked = false,
    this.message,
  });

  /// Nothing due: go online.
  static const none = OnlineSelfieDue(due: false);

  static const defaultAnswerSeconds = 180;

  factory OnlineSelfieDue.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    final secs = m['answer_seconds'];
    return OnlineSelfieDue(
      due: m['due'] == true && m['id'] is String,
      id: m['id'] as String?,
      reason: m['reason'] == 'new_device' ? 'new_device' : 'random',
      answerSeconds: secs is num && secs > 0 ? secs.toInt() : defaultAnswerSeconds,
      blocked: m['blocked'] == true,
      message: m['message'] as String?,
    );
  }

  final bool due;
  final String? id;

  /// 'new_device' or 'random' (a watch-list check reads as random).
  final String reason;
  final int answerSeconds;

  /// The web or a desktop while the phone's check is due: stay offline.
  final bool blocked;
  final String? message;

  bool get newPhone => reason == 'new_device';
}

/// What the modal says, by reason.
String onlineSelfiePrompt(String reason) => reason == 'new_device'
    ? 'You are using a new phone. Take a quick selfie so we know it is you.'
    : 'Random safety check. Take a quick selfie before you go online.';

/// "3:00" for the time left to answer.
String answerClock(Duration left) {
  // Rounded up: a full three minutes reads 3:00 for its first second.
  final s = left.isNegative ? 0 : (left.inMilliseconds + 999) ~/ 1000;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// "3 minutes", "90 seconds", "1 minute".
String answerTimeText(int seconds) {
  if (seconds % 60 != 0) return '$seconds seconds';
  final m = seconds ~/ 60;
  return m == 1 ? '1 minute' : '$m minutes';
}

/// The result the partner sees after the selfie.
enum OnlineSelfieOutcome {
  /// A good match.
  match,

  /// Below the admin's threshold: saved for the admin, online anyway.
  low,

  /// No provider, no answer in time, or nothing to compare with.
  notChecked,
}

/// The partner's words for [outcome] (always online).
String onlineSelfieOutcomeText(OnlineSelfieOutcome outcome) => switch (outcome) {
  OnlineSelfieOutcome.match => 'Thanks, it is you. You are online.',
  OnlineSelfieOutcome.low => 'Saved for the admin to check. You are online.',
  OnlineSelfieOutcome.notChecked => 'Saved for the admin to compare. You are online.',
};

/// What the check row says once compared; null while it is still pending.
OnlineSelfieOutcome? onlineSelfieOutcome(Map<String, dynamic> row) {
  final state = row['face_state'];
  if (state == null || state == 'pending') return null;
  if (row['low_match'] == true) return OnlineSelfieOutcome.low;
  final score = row['face_score'];
  if (score is num && (state == 'match' || state == 'no_match')) return OnlineSelfieOutcome.match;
  return OnlineSelfieOutcome.notChecked;
}

// ---- The admin ------------------------------------------------------------------------------------

/// Who gets the low-match push.
enum AlertTo {
  all('all', 'All admins', 'Every admin and sub-admin who can see Documents.'),
  selected('selected', 'Selected admins', 'Only the admins you pick.'),
  support('support', 'Support', 'Everyone with the Support role (Admin › Sub-admins).');

  const AlertTo(this.value, this.label, this.help);
  final String value;
  final String label;
  final String help;

  static AlertTo parse(Object? v) => values.firstWhere((a) => a.value == v, orElse: () => AlertTo.all);
}

/// Admin › Dispatch › Partner selfie checks (app_settings 'online_selfie').
@immutable
class OnlineSelfieConfig {
  const OnlineSelfieConfig({
    this.randomOn = true,
    this.randomPct = 20,
    this.randomCap = 1,
    this.lowBelow = 60,
    this.alertTo = AlertTo.all,
    this.alertAdmins = const [],
    this.answerSeconds = 180,
  });

  factory OnlineSelfieConfig.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    int n(String k, int d) => m[k] is num ? (m[k] as num).round() : d;
    return OnlineSelfieConfig(
      randomOn: m['randomOn'] is bool ? m['randomOn'] as bool : true,
      randomPct: n('randomPct', 20),
      randomCap: n('randomCap', 1),
      lowBelow: n('lowBelow', 60),
      alertTo: AlertTo.parse(m['alertTo']),
      alertAdmins: [
        if (m['alertAdmins'] is List)
          for (final a in m['alertAdmins'] as List)
            if (a is String) a,
      ],
      answerSeconds: n('answerSeconds', 180),
    );
  }

  final bool randomOn;
  final int randomPct;
  final int randomCap;
  final int lowBelow;
  final AlertTo alertTo;
  final List<String> alertAdmins;
  final int answerSeconds;

  Map<String, Object?> toJson() => {
    'randomOn': randomOn,
    'randomPct': randomPct,
    'randomCap': randomCap,
    'lowBelow': lowBelow,
    'alertTo': alertTo.value,
    'alertAdmins': alertAdmins,
    'answerSeconds': answerSeconds,
  };

  OnlineSelfieConfig copyWith({
    bool? randomOn,
    int? randomPct,
    int? randomCap,
    int? lowBelow,
    AlertTo? alertTo,
    List<String>? alertAdmins,
    int? answerSeconds,
  }) => OnlineSelfieConfig(
    randomOn: randomOn ?? this.randomOn,
    randomPct: randomPct ?? this.randomPct,
    randomCap: randomCap ?? this.randomCap,
    lowBelow: lowBelow ?? this.lowBelow,
    alertTo: alertTo ?? this.alertTo,
    alertAdmins: alertAdmins ?? this.alertAdmins,
    answerSeconds: answerSeconds ?? this.answerSeconds,
  );

  /// Why it can't be saved, or null.
  String? get problem {
    if (randomPct < 0 || randomPct > 100) return 'Give a chance from 0 to 100%.';
    if (lowBelow < 1 || lowBelow > 99) return 'Give a match from 1 to 99%.';
    if (alertTo == AlertTo.selected && alertAdmins.isEmpty) return 'Pick at least one admin for the alert.';
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is OnlineSelfieConfig &&
      other.randomOn == randomOn &&
      other.randomPct == randomPct &&
      other.randomCap == randomCap &&
      other.lowBelow == lowBelow &&
      other.alertTo == alertTo &&
      listEquals(other.alertAdmins, alertAdmins) &&
      other.answerSeconds == answerSeconds;

  @override
  int get hashCode =>
      Object.hash(randomOn, randomPct, randomCap, lowBelow, alertTo, Object.hashAll(alertAdmins), answerSeconds);
}

/// "once a day", "up to 3 a day".
String perDayText(int n) => n == 1 ? 'once a day' : 'up to $n a day';

/// The choices for "At most" and "Time to answer".
const randomCapChoices = [1, 2, 3, 5, 10];
const answerSecondsChoices = [60, 120, 180, 300, 600];

/// A watch-list rule.
enum WatchRule {
  every('every', 'Every go-online'),
  percent('percent', 'A % with a daily cap'),
  hours('hours', 'Every N hours online');

  const WatchRule(this.value, this.label);
  final String value;
  final String label;

  static WatchRule parse(Object? v) => values.firstWhere((r) => r.value == v, orElse: () => WatchRule.every);
}

/// One partner on the watch list.
@immutable
class WatchEntry {
  const WatchEntry({
    required this.rule,
    this.pct = 50,
    this.cap = 3,
    this.hours = 8,
    this.until,
    this.reason = '',
    this.active = true,
  });

  factory WatchEntry.fromJson(Map<String, dynamic> m) => WatchEntry(
    rule: WatchRule.parse(m['rule']),
    pct: (m['pct'] as num?)?.toInt() ?? 50,
    cap: (m['cap'] as num?)?.toInt() ?? 3,
    hours: (m['hours'] as num?)?.toInt() ?? 8,
    until: m['until'] is String ? m['until'] as String : null,
    reason: '${m['reason'] ?? ''}',
    active: m['active'] != false,
  );

  static WatchEntry? maybe(Object? json) => json is Map ? WatchEntry.fromJson(Map<String, dynamic>.from(json)) : null;

  final WatchRule rule;
  final int pct;
  final int cap;
  final int hours;

  /// yyyy-mm-dd, or null for no end.
  final String? until;
  final String reason;

  /// False once the end date has passed.
  final bool active;

  /// Why it can't be saved, or null.
  String? get problem {
    if (reason.trim().isEmpty) return 'Say why they are on the watch list.';
    if (rule == WatchRule.percent && (pct < 1 || pct > 100)) return 'Give a chance from 1 to 100%.';
    if (rule == WatchRule.percent && (cap < 1 || cap > 20)) return 'Give 1 to 20 checks a day.';
    if (rule == WatchRule.hours && (hours < 1 || hours > 168)) return 'Give 1 to 168 hours.';
    return null;
  }

  WatchEntry copyWith({
    WatchRule? rule,
    int? pct,
    int? cap,
    int? hours,
    String? until,
    bool clearUntil = false,
    String? reason,
  }) => WatchEntry(
    rule: rule ?? this.rule,
    pct: pct ?? this.pct,
    cap: cap ?? this.cap,
    hours: hours ?? this.hours,
    until: clearUntil ? null : (until ?? this.until),
    reason: reason ?? this.reason,
    active: active,
  );
}

/// The rule in a few words: "Every go-online", "50% · up to 3 a day",
/// "Every 8 hours online"; [untilText] adds " · until 30 Nov".
String watchRuleText(WatchEntry w, {String? untilText}) {
  final rule = switch (w.rule) {
    WatchRule.every => 'Every go-online',
    WatchRule.percent => '${w.pct}% · ${perDayText(w.cap)}',
    WatchRule.hours => w.hours == 1 ? 'Every hour online' : 'Every ${w.hours} hours online',
  };
  return [rule, if (untilText != null) 'until $untilText', if (!w.active) 'ended'].join(' · ');
}

/// Why a check was asked, as the admin reads it.
String onlineCheckReasonText(Object? reason) => switch (reason) {
  'new_device' => 'New phone',
  'random' => 'Random',
  'watch_list' => 'Watch list',
  _ => 'Going online',
};

/// Where a check stands, in a word, for the admin.
String onlineCheckStateText(Map<String, dynamic> c) => switch (c['state']) {
  'due' => switch (c['last_skip']) {
    'not_now' => 'Not answered: Not now',
    'timeout' => 'Not answered: time ran out',
    _ => 'Waiting for the selfie',
  },
  'lapsed' => 'Not answered',
  _ => c['closer'] == true ? 'Needs a closer look' : (c['reviewed_at'] != null ? 'Looked at' : 'Online'),
};
