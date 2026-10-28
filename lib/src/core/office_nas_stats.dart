// Visitor stats (migration 0321, deploy/nas-stats): Umami on the office NAS
// counts visits to getride.my's public pages and qr.getride.my, without
// cookies. What Admin › Settings › Office NAS › Visitor stats shows.
import 'package:intl/intl.dart';

/// app_settings 'nas_stats'.
class NasStatsSettings {
  const NasStatsSettings({this.on = true, this.websiteId});

  factory NasStatsSettings.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    final id = '${m['websiteId'] ?? ''}'.trim().toLowerCase();
    return NasStatsSettings(on: m['on'] is bool ? m['on'] as bool : true, websiteId: validWebsiteId(id) ? id : null);
  }

  final bool on;

  /// The website's ID in Umami (Settings › Websites › Edit).
  final String? websiteId;

  Map<String, dynamic> toJson() => {'on': on, 'websiteId': websiteId};

  NasStatsSettings copyWith({bool? on, String? websiteId, bool clearWebsite = false}) =>
      NasStatsSettings(on: on ?? this.on, websiteId: clearWebsite ? null : (websiteId ?? this.websiteId));

  static bool validWebsiteId(String v) =>
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$').hasMatch(v.trim().toLowerCase());
}

enum StatsState { on, paused, notSet, nasOff, refused }

class VisitorToday {
  const VisitorToday({
    this.visitors = 0,
    this.pageviews = 0,
    this.visits = 0,
    this.installViews = 0,
    this.topPage,
    this.topSource,
  });

  factory VisitorToday.fromJson(Map<String, dynamic> m) {
    int n(String k) => (m[k] as num?)?.toInt() ?? 0;
    String? s(String k) => (m[k] is String && (m[k] as String).trim().isNotEmpty) ? (m[k] as String).trim() : null;
    return VisitorToday(
      visitors: n('visitors'),
      pageviews: n('pageviews'),
      visits: n('visits'),
      installViews: n('installViews'),
      topPage: s('topPage'),
      topSource: s('topSource'),
    );
  }

  final int visitors;
  final int pageviews;
  final int visits;
  final int installViews;
  final String? topPage;
  final String? topSource;
}

/// What the nas-stats function answered.
class VisitorStats {
  const VisitorStats({required this.state, this.today, this.reason, this.at});

  factory VisitorStats.fromJson(Object? json) {
    final m = json is Map ? Map<String, dynamic>.from(json) : <String, dynamic>{};
    final state = switch (m['state']) {
      'on' => StatsState.on,
      'paused' => StatsState.paused,
      'not_set' => StatsState.notSet,
      'refused' => StatsState.refused,
      _ => StatsState.nasOff,
    };
    return VisitorStats(
      state: state,
      today: m['today'] is Map ? VisitorToday.fromJson(Map<String, dynamic>.from(m['today'] as Map)) : null,
      reason: m['reason'] as String?,
      at: DateTime.tryParse('${m['at']}')?.toLocal(),
    );
  }

  /// When the function itself couldn't be reached.
  const VisitorStats.unreachable() : this(state: StatsState.nasOff, reason: 'unreachable');

  final StatsState state;
  final VisitorToday? today;
  final String? reason;
  final DateTime? at;
}

/// "1,284".
String groupedNumber(int n) => NumberFormat.decimalPattern('en').format(n);

/// The line under the numbers, or instead of them.
String statsStateText(VisitorStats s) => switch (s.state) {
      StatsState.on => 'Counting.',
      StatsState.paused => 'Turned off here. The site still sends visits to the NAS while its build has the stats script.',
      StatsState.notSet => s.reason == 'key'
          ? 'No Umami key yet: add it in API Keys, Umami (view-only user).'
          : 'No website ID yet: copy it from Umami (Settings, Websites, Edit) into the box below.',
      StatsState.refused => 'Umami refused the name and password (or token) in API Keys.',
      StatsState.nasOff => "NAS off: the stats can't be read now. Visits aren't counted while it is off; nothing else is affected.",
    };
