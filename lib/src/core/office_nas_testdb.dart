// The office NAS's test database (migration 0321, deploy/nas-testdb): a copy
// of the live database refreshed nightly on the NAS, with personal data
// scrambled, where a PR's migrations are tried before they run live. What
// Admin › Settings › Office NAS › Test database shows and sends.
import 'package:intl/intl.dart';

/// app_settings 'nas_testdb', read as leniently as the server normalises it.
class TestDbSettings {
  const TestDbSettings({this.refreshAt = '02:30', this.scramble = true});

  factory TestDbSettings.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    final at = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch('${m['refreshAt'] ?? ''}'.trim());
    final h = at == null ? null : int.parse(at.group(1)!);
    final min = at == null ? null : int.parse(at.group(2)!);
    final ok = h != null && min != null && h <= 23 && min <= 59;
    return TestDbSettings(
      refreshAt: ok ? timeText(h, min) : defaults.refreshAt,
      scramble: m['scramble'] is bool ? m['scramble'] as bool : true,
    );
  }

  static const defaults = TestDbSettings();

  /// "HH:MM", office time.
  final String refreshAt;
  final bool scramble;

  int get hour => int.parse(refreshAt.split(':')[0]);
  int get minute => int.parse(refreshAt.split(':')[1]);

  Map<String, dynamic> toJson() => {'refreshAt': refreshAt, 'scramble': scramble};

  TestDbSettings copyWith({String? refreshAt, bool? scramble}) =>
      TestDbSettings(refreshAt: refreshAt ?? this.refreshAt, scramble: scramble ?? this.scramble);

  static String timeText(int hour, int minute) =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

enum TestDbRunStatus {
  queued('Waiting'),
  running('Running'),
  passed('Passed'),
  failed('Failed'),
  cancelled('Cancelled');

  const TestDbRunStatus(this.label);
  final String label;

  static TestDbRunStatus parse(Object? v) =>
      TestDbRunStatus.values.firstWhere((s) => s.name == v, orElse: () => TestDbRunStatus.queued);
}

/// A refresh of the copy, or a PR's migrations tried on it.
class TestDbRun {
  const TestDbRun({
    required this.id,
    required this.isMigration,
    required this.status,
    this.prNumber,
    this.branch,
    this.headSha,
    this.files = const [],
    this.error,
    this.ms,
    this.detail = const {},
    this.createdAt,
    this.finishedAt,
  });

  factory TestDbRun.fromJson(Map<String, dynamic> m) => TestDbRun(
        id: '${m['id'] ?? ''}',
        isMigration: m['kind'] == 'migration',
        status: TestDbRunStatus.parse(m['status']),
        prNumber: (m['pr_number'] as num?)?.toInt(),
        branch: m['branch'] as String?,
        headSha: m['head_sha'] as String?,
        files: [for (final f in (m['files'] as List?) ?? const []) '$f'],
        error: m['error'] as String?,
        ms: (m['ms'] as num?)?.toInt(),
        detail: m['detail'] is Map ? Map<String, dynamic>.from(m['detail'] as Map) : const {},
        createdAt: DateTime.tryParse('${m['created_at']}')?.toLocal(),
        finishedAt: DateTime.tryParse('${m['finished_at']}')?.toLocal(),
      );

  static TestDbRun? maybe(Object? v) => v is Map ? TestDbRun.fromJson(Map<String, dynamic>.from(v)) : null;

  final String id;
  final bool isMigration;
  final TestDbRunStatus status;
  final int? prNumber;
  final String? branch;
  final String? headSha;
  final List<String> files;
  final String? error;
  final int? ms;
  final Map<String, dynamic> detail;
  final DateTime? createdAt;
  final DateTime? finishedAt;

  /// "PR #554", or the branch; "Refresh" for a fresh copy.
  String get target => !isMigration
      ? 'Refresh'
      : prNumber != null
          ? 'PR #$prNumber'
          : (branch ?? '');

  /// The migrations' numbers ("0311, 0312"), else their names, else the target.
  String get what {
    if (!isMigration) return 'Refresh';
    if (files.isEmpty) return target;
    final names = [
      for (final f in files)
        RegExp(r'^(\d{3,5})_').firstMatch(f.split('/').last)?.group(1) ?? f.split('/').last,
    ];
    return names.join(', ');
  }

  /// The second run of the same files (migrations here are re-runnable)
  /// failed: worth a look, but the migration itself went in.
  String? get rerunProblem {
    final r = detail['rerun'];
    return r is String && r.startsWith('failed') ? r : null;
  }

  bool get finished => status == TestDbRunStatus.passed || status == TestDbRunStatus.failed;
}

/// The runner on the NAS and what it last said about its copy.
class TestDbRunner {
  const TestDbRunner({
    required this.id,
    required this.label,
    this.model,
    this.appVersion,
    this.lastSeenAt,
    this.online = false,
    this.state = const {},
  });

  factory TestDbRunner.fromJson(Map<String, dynamic> m) => TestDbRunner(
        id: '${m['id'] ?? ''}',
        label: '${m['label'] ?? 'Office NAS'}',
        model: m['model'] as String?,
        appVersion: m['app_version'] as String?,
        lastSeenAt: DateTime.tryParse('${m['last_seen_at']}')?.toLocal(),
        online: m['online'] == true,
        state: m['state'] is Map ? Map<String, dynamic>.from(m['state'] as Map) : const {},
      );

  final String id;
  final String label;
  final String? model;
  final String? appVersion;
  final DateTime? lastSeenAt;
  final bool online;
  final Map<String, dynamic> state;

  DateTime? get refreshedAt => DateTime.tryParse('${state['refreshed_at']}')?.toLocal();
  int? get sizeBytes => (state['size_bytes'] as num?)?.toInt();
  bool? get scrambled => state['scrambled'] is bool ? state['scrambled'] as bool : null;

  /// What it is doing now ("refreshing", "trying PR #554"), when busy.
  String? get busy {
    final b = '${state['busy'] ?? ''}'.trim();
    return b.isEmpty ? null : b;
  }
}

class TestDbState {
  const TestDbState({
    this.settings = TestDbSettings.defaults,
    this.runners = const [],
    this.lastRefresh,
    this.lastMigration,
    this.waiting = const [],
    this.recent = const [],
  });

  factory TestDbState.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    List<Map<String, dynamic>> maps(Object? v) =>
        [for (final x in (v is List ? v : const [])) if (x is Map) Map<String, dynamic>.from(x)];
    return TestDbState(
      settings: TestDbSettings.fromJson(m['settings']),
      runners: [for (final r in maps(m['runners'])) TestDbRunner.fromJson(r)],
      lastRefresh: TestDbRun.maybe(m['last_refresh']),
      lastMigration: TestDbRun.maybe(m['last_migration']),
      waiting: [for (final r in maps(m['waiting'])) TestDbRun.fromJson(r)],
      recent: [for (final r in maps(m['recent'])) TestDbRun.fromJson(r)],
    );
  }

  final TestDbSettings settings;
  final List<TestDbRunner> runners;
  final TestDbRun? lastRefresh;
  final TestDbRun? lastMigration;
  final List<TestDbRun> waiting;
  final List<TestDbRun> recent;

  TestDbRunner? get runner => runners.isEmpty ? null : runners.first;
}

/// What the "Try migration from PR #" box was given: a PR number ("554",
/// "#554", a PR link) or a branch name. Null when it is neither.
({int? pr, String? branch})? parseTryTarget(String input) {
  final s = input.trim();
  if (s.isEmpty) return null;
  final link = RegExp(r'/pull/(\d+)').firstMatch(s);
  final number = link?.group(1) ?? RegExp(r'^(?:pr\s*)?#?\s*(\d+)$', caseSensitive: false).firstMatch(s)?.group(1);
  if (number != null) {
    final n = int.tryParse(number);
    return n == null || n < 1 || n > 99999999 ? null : (pr: n, branch: null);
  }
  if (s.contains('..') || s.startsWith(RegExp(r'[/.-]')) || !RegExp(r'^[A-Za-z0-9._/-]{1,200}$').hasMatch(s)) {
    return null;
  }
  return (pr: null, branch: s);
}

/// "4.2 s", "6 min", "1 h 5 min".
String formatRunTime(int? ms) {
  if (ms == null) return '';
  if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)} s';
  final min = (ms / 60000).round();
  if (min < 60) return '$min min';
  return '${min ~/ 60} h${min % 60 == 0 ? '' : ' ${min % 60} min'}';
}

/// "1.8 GB", "640 MB".
String formatBytes(int? bytes) {
  if (bytes == null || bytes <= 0) return '';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1000 && u < units.length - 1) {
    v /= 1000;
    u++;
  }
  return '${v >= 10 || u == 0 ? v.round() : v.toStringAsFixed(1)} ${units[u]}';
}

/// "0311 · passed in 4.2 s", "PR #554 · failed in 1.0 s", "PR #554 · waiting".
String runSummary(TestDbRun r) {
  final time = formatRunTime(r.ms);
  final how = switch (r.status) {
    TestDbRunStatus.passed => time.isEmpty ? 'passed' : 'passed in $time',
    TestDbRunStatus.failed => time.isEmpty ? 'failed' : 'failed in $time',
    TestDbRunStatus.queued => 'waiting',
    TestDbRunStatus.running => 'running',
    TestDbRunStatus.cancelled => 'cancelled',
  };
  return '${r.what} · $how';
}

/// "Today 02:41", "Yesterday 02:41", "27 Oct 02:41".
String whenText(DateTime? t, DateTime now) {
  if (t == null) return '';
  final day = DateTime(t.year, t.month, t.day);
  final today = DateTime(now.year, now.month, now.day);
  final hm = DateFormat('HH:mm').format(t);
  if (day == today) return 'Today $hm';
  if (day == today.subtract(const Duration(days: 1))) return 'Yesterday $hm';
  return '${DateFormat('d MMM').format(t)} $hm';
}
