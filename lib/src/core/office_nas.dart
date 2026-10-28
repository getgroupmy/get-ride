// Office NAS, part N1 (migration 0318): the backups and the uptime monitor
// as Admin > Settings > Office NAS shows them. The settings keep the shape
// the server keeps (nas_backup_normalize, nas_uptime_normalize): read
// leniently, clamped the same way. The words and numbers on the Overview,
// Backups and Uptime tabs are worked out here. Pure.

/// The page key that grants Admin > Settings > Office NAS.
const officeNasPage = 'admin-settings-office-nas';

/// Its address.
const officeNasPath = '/admin/m/office-nas';

int _int(Object? v, int fallback, int min, int max) {
  final n = switch (v) {
    final num n => n.round(),
    final String s => num.tryParse(s.trim())?.round(),
    _ => null,
  };
  return (n ?? fallback).clamp(min, max);
}

bool _bool(Object? v, bool fallback) => v is bool ? v : (v == 'true' ? true : (v == 'false' ? false : fallback));

List<String> _strings(Object? v, {int max = 20, int len = 120}) {
  if (v is! List) return const [];
  final out = <String>[];
  for (final e in v) {
    if (e is! String) continue;
    final s = e.trim();
    if (s.isEmpty) continue;
    final cut = s.length > len ? s.substring(0, len) : s;
    if (!out.contains(cut)) out.add(cut);
    if (out.length == max) break;
  }
  return out;
}

Map<String, dynamic> _map(Object? v) => v is Map ? v.cast<String, dynamic>() : const {};

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;

final _hhmm = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
final _ymd = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final _zone = RegExp(r'^[A-Za-z_]+(/[A-Za-z0-9_+-]+){0,2}$');

/// Where the off-site copy goes (Hyper Backup).
enum OffsiteTarget {
  none('Not set up'),
  b2('Backblaze B2'),
  c2('Synology C2'),
  other('Somewhere else');

  const OffsiteTarget(this.label);
  final String label;

  static OffsiteTarget of(Object? v) => values.firstWhere((e) => e.name == v, orElse: () => none);
}

/// Time zones the nightly time can be set in.
const backupTimeZones = [
  'Asia/Kuala_Lumpur',
  'Asia/Singapore',
  'Asia/Brunei',
  'Asia/Jakarta',
  'Asia/Bangkok',
  'Asia/Manila',
  'Asia/Hong_Kong',
  'Asia/Tokyo',
  'Asia/Dubai',
  'Europe/London',
  'UTC',
];

class NasBackupSettings {
  const NasBackupSettings({
    this.on = true,
    this.at = '02:00',
    this.timezone = 'Asia/Kuala_Lumpur',
    this.keepNightly = 30,
    this.keepMonthly = 12,
    this.skipBuckets = const [],
    this.restoreTestOn = true,
    this.restoreTestDay = 1,
    this.offsite = OffsiteTarget.none,
    this.lastCopyOn,
  });

  final bool on;

  /// 'HH:MM', in [timezone].
  final String at;
  final String timezone;
  final int keepNightly;
  final int keepMonthly;
  final List<String> skipBuckets;
  final bool restoreTestOn;

  /// Day of the month, 1 to 28.
  final int restoreTestDay;
  final OffsiteTarget offsite;

  /// The last off-site copy, set by hand (yyyy-mm-dd) when the NAS can't tell.
  final String? lastCopyOn;

  static const defaults = NasBackupSettings();

  factory NasBackupSettings.fromJson(Object? raw) {
    final j = _map(raw);
    final rt = _map(j['restoreTest']);
    final off = _map(j['offsite']);
    final at = '${j['at'] ?? ''}';
    final tz = '${j['timezone'] ?? ''}'.trim();
    final last = '${off['lastCopyOn'] ?? ''}';
    return NasBackupSettings(
      on: _bool(j['on'], true),
      at: _hhmm.hasMatch(at) ? at : '02:00',
      timezone: _zone.hasMatch(tz) ? tz : 'Asia/Kuala_Lumpur',
      keepNightly: _int(j['keepNightly'], 30, 1, 365),
      keepMonthly: _int(j['keepMonthly'], 12, 0, 120),
      skipBuckets: _strings(j['skipBuckets'], max: 50, len: 100),
      restoreTestOn: _bool(rt['on'], true),
      restoreTestDay: _int(rt['day'], 1, 1, 28),
      offsite: OffsiteTarget.of(off['where']),
      lastCopyOn: _ymd.hasMatch(last) ? last : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'on': on,
        'at': at,
        'timezone': timezone,
        'keepNightly': keepNightly,
        'keepMonthly': keepMonthly,
        'skipBuckets': skipBuckets,
        'restoreTest': {'on': restoreTestOn, 'day': restoreTestDay},
        'offsite': {'where': offsite.name, 'lastCopyOn': lastCopyOn},
      };

  NasBackupSettings copyWith({
    bool? on,
    String? at,
    String? timezone,
    int? keepNightly,
    int? keepMonthly,
    List<String>? skipBuckets,
    bool? restoreTestOn,
    int? restoreTestDay,
    OffsiteTarget? offsite,
    String? Function()? lastCopyOn,
  }) =>
      NasBackupSettings(
        on: on ?? this.on,
        at: at ?? this.at,
        timezone: timezone ?? this.timezone,
        keepNightly: (keepNightly ?? this.keepNightly).clamp(1, 365),
        keepMonthly: (keepMonthly ?? this.keepMonthly).clamp(0, 120),
        skipBuckets: skipBuckets ?? this.skipBuckets,
        restoreTestOn: restoreTestOn ?? this.restoreTestOn,
        restoreTestDay: (restoreTestDay ?? this.restoreTestDay).clamp(1, 28),
        offsite: offsite ?? this.offsite,
        lastCopyOn: lastCopyOn == null ? this.lastCopyOn : lastCopyOn(),
      );

  /// [bucket] copied or left out.
  NasBackupSettings withBucket(String bucket, bool copy) => copyWith(
        skipBuckets: copy
            ? [for (final b in skipBuckets) if (b != bucket) b]
            : [...skipBuckets.where((b) => b != bucket), bucket],
      );
}

/// Where alerts go. Each is switched on or off in Admin > Uptime.
enum AlertChannel {
  push('Admin app push'),
  telegram('Telegram'),
  sms('WhatsApp / SMS'),
  email('Email (Resend)');

  const AlertChannel(this.label);
  final String label;
}

class NasUptimeSettings {
  const NasUptimeSettings({
    this.failAfter = 2,
    this.nasEveryMinutes = 1,
    this.cloudEveryMinutes = 5,
    this.slowMs = 3000,
    this.gatewayLateMinutes = 3,
    this.gatewayDownMinutes = 10,
    this.channels = const {
      AlertChannel.push: true,
      AlertChannel.telegram: false,
      AlertChannel.sms: false,
      AlertChannel.email: false,
    },
    this.telegramChats = const [],
    this.smsNumbers = const [],
    this.emails = const [],
    this.emailFrom,
  });

  final int failAfter;
  final int nasEveryMinutes;
  final int cloudEveryMinutes;
  final int slowMs;
  final int gatewayLateMinutes;
  final int gatewayDownMinutes;
  final Map<AlertChannel, bool> channels;
  final List<String> telegramChats;
  final List<String> smsNumbers;
  final List<String> emails;
  final String? emailFrom;

  static const defaults = NasUptimeSettings();

  bool isOn(AlertChannel c) => channels[c] ?? false;

  factory NasUptimeSettings.fromJson(Object? raw) {
    final j = _map(raw);
    final ch = _map(j['channels']);
    final late = _int(j['gatewayLateMinutes'], 3, 1, 120);
    final from = '${j['emailFrom'] ?? ''}'.trim();
    return NasUptimeSettings(
      failAfter: _int(j['failAfter'], 2, 1, 10),
      nasEveryMinutes: _int(j['nasEveryMinutes'], 1, 1, 60),
      cloudEveryMinutes: _int(j['cloudEveryMinutes'], 5, 1, 60),
      slowMs: _int(j['slowMs'], 3000, 200, 30000),
      gatewayLateMinutes: late,
      gatewayDownMinutes: _int(j['gatewayDownMinutes'], 10, 2, 240) < late + 1
          ? late + 1
          : _int(j['gatewayDownMinutes'], 10, 2, 240),
      channels: {
        AlertChannel.push: _bool(ch['push'], true),
        AlertChannel.telegram: _bool(ch['telegram'], false),
        AlertChannel.sms: _bool(ch['sms'], false),
        AlertChannel.email: _bool(ch['email'], false),
      },
      telegramChats: _strings(j['telegramChats'], max: 10, len: 40),
      smsNumbers: _strings(j['smsNumbers'], max: 10, len: 32),
      emails: _strings(j['emails'], max: 20, len: 200),
      emailFrom: from.isEmpty ? null : (from.length > 200 ? from.substring(0, 200) : from),
    );
  }

  Map<String, dynamic> toJson() => {
        'failAfter': failAfter,
        'nasEveryMinutes': nasEveryMinutes,
        'cloudEveryMinutes': cloudEveryMinutes,
        'slowMs': slowMs,
        'gatewayLateMinutes': gatewayLateMinutes,
        'gatewayDownMinutes': gatewayDownMinutes,
        'channels': {for (final c in AlertChannel.values) c.name: isOn(c)},
        'telegramChats': telegramChats,
        'smsNumbers': smsNumbers,
        'emails': emails,
        'emailFrom': emailFrom,
      };

  NasUptimeSettings copyWith({
    int? failAfter,
    int? nasEveryMinutes,
    int? cloudEveryMinutes,
    int? slowMs,
    int? gatewayLateMinutes,
    int? gatewayDownMinutes,
    Map<AlertChannel, bool>? channels,
    List<String>? telegramChats,
    List<String>? smsNumbers,
    List<String>? emails,
    String? Function()? emailFrom,
  }) {
    final late = (gatewayLateMinutes ?? this.gatewayLateMinutes).clamp(1, 120);
    return NasUptimeSettings(
      failAfter: (failAfter ?? this.failAfter).clamp(1, 10),
      nasEveryMinutes: (nasEveryMinutes ?? this.nasEveryMinutes).clamp(1, 60),
      cloudEveryMinutes: (cloudEveryMinutes ?? this.cloudEveryMinutes).clamp(1, 60),
      slowMs: (slowMs ?? this.slowMs).clamp(200, 30000),
      gatewayLateMinutes: late,
      gatewayDownMinutes: (gatewayDownMinutes ?? this.gatewayDownMinutes).clamp(late + 1, 240),
      channels: channels ?? this.channels,
      telegramChats: telegramChats ?? this.telegramChats,
      smsNumbers: smsNumbers ?? this.smsNumbers,
      emails: emails ?? this.emails,
      emailFrom: emailFrom == null ? this.emailFrom : emailFrom(),
    );
  }

  NasUptimeSettings withChannel(AlertChannel c, bool on) => copyWith(channels: {...channels, c: on});

  /// Where [c] would send, or null when it sends to every full admin.
  List<String>? addresses(AlertChannel c) => switch (c) {
        AlertChannel.push => null,
        AlertChannel.telegram => telegramChats,
        AlertChannel.sms => smsNumbers,
        AlertChannel.email => emails,
      };
}

/// One NAS service's last check-in (nas_services).
class NasService {
  const NasService({required this.service, this.lastSeen, this.status, this.detail = const {}, this.version});
  final String service;
  final DateTime? lastSeen;
  final String? status;
  final Map<String, dynamic> detail;
  final String? version;

  factory NasService.fromJson(Map<String, dynamic> j) => NasService(
        service: '${j['service'] ?? ''}',
        lastSeen: _time(j['last_seen']),
        status: j['status'] as String?,
        detail: _map(j['detail']),
        version: j['version'] as String?,
      );

  /// Heard from in the last 3 minutes (it checks in every minute).
  bool onlineAt(DateTime now) => lastSeen != null && now.difference(lastSeen!) < const Duration(minutes: 3);
}

/// The paired NAS app.
class NasAgent {
  const NasAgent({required this.id, required this.label, this.model, this.appVersion, this.lastSeenAt, this.online = false});
  final String id;
  final String label;
  final String? model;
  final String? appVersion;
  final DateTime? lastSeenAt;
  final bool online;

  factory NasAgent.fromJson(Map<String, dynamic> j) => NasAgent(
        id: '${j['id']}',
        label: '${j['label'] ?? 'Office NAS'}',
        model: j['model'] as String?,
        appVersion: j['app_version'] as String?,
        lastSeenAt: _time(j['last_seen_at']),
        online: j['online'] == true,
      );
}

enum RunKind { backup, restoreTest }

class BackupRun {
  const BackupRun({
    required this.id,
    required this.kind,
    required this.startedAt,
    this.manual = false,
    this.finishedAt,
    this.status = 'running',
    this.dbBytes,
    this.files,
    this.filesBytes,
    this.totalBytes,
    this.error,
    this.detail = const {},
  });

  final String id;
  final RunKind kind;
  final bool manual;
  final DateTime startedAt;
  final DateTime? finishedAt;

  /// running | ok | failed
  final String status;
  final int? dbBytes;
  final int? files;
  final int? filesBytes;
  final int? totalBytes;
  final String? error;
  final Map<String, dynamic> detail;

  bool get ok => status == 'ok';
  bool get running => status == 'running';

  static BackupRun? fromJson(Object? raw) {
    final j = _map(raw);
    final started = _time(j['started_at']);
    if (j['id'] == null || started == null) return null;
    int? n(Object? v) => v is num ? v.round() : null;
    return BackupRun(
      id: '${j['id']}',
      kind: j['kind'] == 'restore_test' ? RunKind.restoreTest : RunKind.backup,
      manual: j['trigger'] == 'manual',
      startedAt: started,
      finishedAt: _time(j['finished_at']),
      status: '${j['status'] ?? 'running'}',
      dbBytes: n(j['db_bytes']),
      files: n(j['files']),
      filesBytes: n(j['files_bytes']),
      totalBytes: n(j['total_bytes']),
      error: j['error'] as String?,
      detail: _map(j['detail']),
    );
  }

  Duration? get took => finishedAt?.difference(startedAt);
}

/// A "Back up now" / "Run a restore test" not yet finished.
class BackupRequest {
  const BackupRequest({required this.kind, required this.requestedAt, this.takenAt});
  final RunKind kind;
  final DateTime requestedAt;
  final DateTime? takenAt;
}

/// kind: http | database | gateways | nas | backup
class UptimeTarget {
  const UptimeTarget({
    required this.id,
    required this.name,
    required this.kind,
    this.url,
    this.on = true,
    this.fromNas = true,
    this.fromCloud = true,
    this.slowMs,
    this.position = 0,
    this.builtin = false,
  });

  final String id;
  final String name;
  final String kind;
  final String? url;
  final bool on;
  final bool fromNas;
  final bool fromCloud;
  final int? slowMs;
  final int position;
  final bool builtin;

  factory UptimeTarget.fromJson(Map<String, dynamic> j) => UptimeTarget(
        id: '${j['id']}',
        name: '${j['name'] ?? j['id']}',
        kind: '${j['kind'] ?? 'http'}',
        url: j['url'] as String?,
        on: j['on'] != false,
        fromNas: j['from_nas'] != false,
        fromCloud: j['from_cloud'] != false,
        slowMs: (j['slow_ms'] as num?)?.round(),
        position: (j['position'] as num?)?.round() ?? 0,
        builtin: j['builtin'] == true,
      );

  /// Whether the NAS can check it (the rest only the cloud can tell).
  bool get networkCheck => kind == 'http' || kind == 'database';

  /// The address as the admin reads it.
  String get where => switch (kind) {
        'database' => 'The database',
        'gateways' => 'Each SMS gateway phone, from when it last checked in',
        'nas' => 'The office NAS, from when it last checked in',
        'backup' => 'A backup that finished in the last 26 hours',
        _ => url == '{payment}'
            ? 'The payment gateway in use'
            : (url ?? '').replaceAll('{project}', 'Your backend'),
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind,
        'url': url,
        'on': on,
        'from_nas': fromNas,
        'from_cloud': fromCloud,
        'slow_ms': slowMs,
      };

  UptimeTarget copyWith({String? name, String? Function()? url, bool? on, bool? fromNas, bool? fromCloud, int? Function()? slowMs}) =>
      UptimeTarget(
        id: id,
        name: name ?? this.name,
        kind: kind,
        url: url == null ? this.url : url(),
        on: on ?? this.on,
        fromNas: fromNas ?? this.fromNas,
        fromCloud: fromCloud ?? this.fromCloud,
        slowMs: slowMs == null ? this.slowMs : slowMs(),
        position: position,
        builtin: builtin,
      );
}

enum UptimeStatus {
  up('Up'),
  slow('Slow'),
  down('Down'),
  unknown('Not checked yet');

  const UptimeStatus(this.label);
  final String label;

  static UptimeStatus of(Object? v) => values.firstWhere((e) => e.name == v, orElse: () => unknown);
}

/// One source's last check of a target.
class SourceCheck {
  const SourceCheck({required this.status, this.ms, this.detail, this.at, this.streak = 0});
  final UptimeStatus status;
  final int? ms;
  final String? detail;
  final DateTime? at;
  final int streak;
}

/// A target (or one gateway phone) as checked: its last result per source,
/// its 30 days, and whether it is down now.
class TargetStatus {
  const TargetStatus({
    required this.id,
    required this.name,
    this.sources = const {},
    this.checks30 = 0,
    this.up30 = 0,
    this.downSince,
  });

  final String id;
  final String name;

  /// 'nas' and 'cloud'.
  final Map<String, SourceCheck> sources;
  final int checks30;
  final int up30;
  final DateTime? downSince;

  factory TargetStatus.fromJson(Map<String, dynamic> j) {
    final s = _map(j['sources']);
    return TargetStatus(
      id: '${j['id']}',
      name: '${j['name'] ?? j['id']}',
      sources: {
        for (final e in s.entries)
          e.key: SourceCheck(
            status: UptimeStatus.of(_map(e.value)['status']),
            ms: (_map(e.value)['ms'] as num?)?.round(),
            detail: _map(e.value)['detail'] as String?,
            at: _time(_map(e.value)['at']),
            streak: (_map(e.value)['streak'] as num?)?.round() ?? 0,
          ),
      },
      checks30: (j['checks30'] as num?)?.round() ?? 0,
      up30: (j['up30'] as num?)?.round() ?? 0,
      downSince: _time(j['down_since']),
    );
  }

  bool get isGateway => id.startsWith('gateway:');

  /// The newest check from either source.
  SourceCheck? get latest {
    SourceCheck? best;
    for (final c in sources.values) {
      if (best == null || (c.at != null && (best.at == null || c.at!.isAfter(best.at!)))) best = c;
    }
    return best;
  }

  /// Down while an incident is open; else the newest check says.
  UptimeStatus get status => downSince != null ? UptimeStatus.down : (latest?.status ?? UptimeStatus.unknown);

  /// "99.98%" over 30 days, "–" before the first check.
  String get uptime30 => uptimePercent(up30, checks30);
}

String uptimePercent(int up, int checks) {
  if (checks <= 0) return '–';
  if (up >= checks) return '100%';
  final p = 100 * up / checks;
  // Never round 99.996% up to "100%".
  final floored = (p * 100).floor() / 100;
  return '${floored.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '')}%';
}

class UptimeAlertRow {
  const UptimeAlertRow({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.createdAt,
    this.push = 0,
    this.sms = 0,
    this.telegram = 'off',
    this.email = 'off',
  });

  final String id;
  final String kind;
  final String title;
  final String body;
  final DateTime createdAt;
  final int push;
  final int sms;
  final String telegram;
  final String email;

  static UptimeAlertRow? fromJson(Object? raw) {
    final j = _map(raw);
    final at = _time(j['created_at']);
    if (at == null) return null;
    return UptimeAlertRow(
      id: '${j['id']}',
      kind: '${j['kind']}',
      title: '${j['title'] ?? ''}',
      body: '${j['body'] ?? ''}',
      createdAt: at,
      push: (j['push'] as num?)?.round() ?? 0,
      sms: (j['sms'] as num?)?.round() ?? 0,
      telegram: '${j['telegram'] ?? 'off'}',
      email: '${j['email'] ?? 'off'}',
    );
  }

  /// "Push to 2 · SMS 1 · Telegram sent · Email failed: …"
  String get delivery => [
        if (push > 0) 'Push to $push',
        if (sms > 0) 'SMS / WhatsApp $sms',
        if (telegram != 'off') 'Telegram $telegram',
        if (email != 'off') 'Email $email',
      ].join(' · ');
}

/// Everything the Office NAS tabs of this batch show (admin_office_nas).
class OfficeNasState {
  const OfficeNasState({
    required this.now,
    this.services = const [],
    this.agents = const [],
    this.backup = NasBackupSettings.defaults,
    this.uptime = NasUptimeSettings.defaults,
    this.runs = const [],
    this.lastBackup,
    this.lastRestoreTest,
    this.requests = const [],
    this.targets = const [],
    this.status = const [],
    this.alerts = const [],
  });

  final DateTime now;
  final List<NasService> services;
  final List<NasAgent> agents;
  final NasBackupSettings backup;
  final NasUptimeSettings uptime;
  final List<BackupRun> runs;
  final BackupRun? lastBackup;
  final BackupRun? lastRestoreTest;
  final List<BackupRequest> requests;
  final List<UptimeTarget> targets;
  final List<TargetStatus> status;
  final List<UptimeAlertRow> alerts;

  factory OfficeNasState.fromJson(Object? raw, {DateTime? now}) {
    final j = _map(raw);
    List<Map<String, dynamic>> list(String k) =>
        [for (final e in (j[k] is List ? j[k] as List : const [])) if (e is Map) e.cast<String, dynamic>()];
    return OfficeNasState(
      now: now ?? _time(j['now']) ?? DateTime.now(),
      services: [for (final s in list('services')) NasService.fromJson(s)],
      agents: [for (final a in list('agents')) NasAgent.fromJson(a)],
      backup: NasBackupSettings.fromJson(j['backup']),
      uptime: NasUptimeSettings.fromJson(j['uptime']),
      runs: [for (final r in list('runs')) ?BackupRun.fromJson(r)],
      lastBackup: BackupRun.fromJson(j['last_backup']),
      lastRestoreTest: BackupRun.fromJson(j['last_restore_test']),
      requests: [
        for (final r in list('requests'))
          if (_time(r['requested_at']) != null)
            BackupRequest(
              kind: r['kind'] == 'restore_test' ? RunKind.restoreTest : RunKind.backup,
              requestedAt: _time(r['requested_at'])!,
              takenAt: _time(r['taken_at']),
            ),
      ],
      targets: [for (final t in list('targets')) UptimeTarget.fromJson(t)]..sort((a, b) => a.position.compareTo(b.position)),
      status: [for (final s in list('status')) TargetStatus.fromJson(s)],
      alerts: [for (final a in list('alerts')) ?UptimeAlertRow.fromJson(a)],
    );
  }

  NasService? service(String name) {
    for (final s in services) {
      if (s.service == name) return s;
    }
    return null;
  }

  bool get connected => agents.isNotEmpty;

  /// The newest check-in of the NAS (any of its apps).
  DateTime? get lastSeen {
    DateTime? best;
    for (final t in [for (final s in services) s.lastSeen, for (final a in agents) a.lastSeenAt]) {
      if (t != null && (best == null || t.isAfter(best))) best = t;
    }
    return best;
  }

  bool get online => lastSeen != null && now.difference(lastSeen!) < const Duration(minutes: 3);

  /// The buckets the NAS found (the backup app reports them).
  List<String> get bucketsSeen {
    final b = service('backup')?.detail['buckets'];
    return b is List ? ([for (final x in b) if (x is String && x.isNotEmpty) x]..sort()) : const [];
  }

  bool waiting(RunKind kind) => requests.any((r) => r.kind == kind);

  /// The Uptime tab's rows: each target in order; the gateway phones where
  /// the gateways target is; switched-off targets last.
  List<({UptimeTarget target, TargetStatus? status})> uptimeRows() {
    final byId = {for (final s in status) s.id: s};
    final out = <({UptimeTarget target, TargetStatus? status})>[];
    final ordered = [...targets.where((t) => t.on), ...targets.where((t) => !t.on)];
    for (final t in ordered) {
      if (t.kind == 'gateways' && t.on) {
        final phones = [for (final s in status) if (s.isGateway) s]..sort((a, b) => a.name.compareTo(b.name));
        if (phones.isNotEmpty) {
          for (final p in phones) {
            out.add((target: t, status: p));
          }
          continue;
        }
      }
      out.add((target: t, status: byId[t.id]));
    }
    return out;
  }
}

// ---- Words -------------------------------------------------------------------------------------

/// 1.8 GB, 340 MB, 12 KB.
String formatBytes(int? bytes) {
  if (bytes == null) return '–';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1000 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final s = i == 0 || v >= 100 ? v.round().toString() : v.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
  return '$s ${units[i]}';
}

/// "20 s ago", "6 min ago", "3 h ago", "2 days ago".
String agoText(DateTime? at, DateTime now) {
  if (at == null) return 'never';
  final d = now.difference(at);
  if (d.inSeconds < 60) return '${d.inSeconds < 0 ? 0 : d.inSeconds} s ago';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return d.inDays == 1 ? '1 day ago' : '${d.inDays} days ago';
}

/// "6 min", "1 h 5 min", "2 days".
String durationText(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds} s';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  if (d.inHours < 24) return d.inMinutes % 60 == 0 ? '${d.inHours} h' : '${d.inHours} h ${d.inMinutes % 60} min';
  return d.inDays == 1 ? '1 day' : '${d.inDays} days';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// "Tonight 02:14", "Yesterday 02:10", "1 Oct 02:00".
String whenText(DateTime at, DateTime now) {
  final day = DateTime(at.year, at.month, at.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return '${at.hour < 6 ? 'Tonight' : 'Today'} ${_hm(at)}';
  if (diff == 1) return 'Yesterday ${_hm(at)}';
  return '${at.day} ${_months[at.month - 1]} ${_hm(at)}';
}

/// "1 Oct".
String dayText(DateTime d) => '${d.day} ${_months[d.month - 1]}';

/// The next monthly restore test on or after [today].
DateTime nextRestoreTest(DateTime today, int day, DateTime? last) {
  final d = day.clamp(1, 28);
  final thisMonth = DateTime(today.year, today.month, d);
  final doneThisMonth = last != null && last.year == today.year && last.month == today.month;
  if (!doneThisMonth && !today.isBefore(thisMonth)) return DateTime(today.year, today.month, today.day);
  if (!doneThisMonth) return thisMonth;
  return DateTime(today.year, today.month + 1, d);
}

/// A status's tone on a card.
enum Tone { ok, warn, bad, idle }

typedef Card3 = ({String status, Tone tone, String note});

/// The Overview's Backups card.
Card3 backupCard(OfficeNasState s) {
  final b = s.lastBackup;
  final offsite = offsiteText(s);
  if (!s.connected) return (status: 'Not connected', tone: Tone.idle, note: 'Connect the NAS to start');
  if (!s.backup.on) return (status: 'Switched off', tone: Tone.warn, note: offsite);
  if (s.service('backup')?.detail['keyReady'] == false) {
    return (status: 'Waiting for the key', tone: Tone.warn, note: 'Run setup-key on the NAS');
  }
  if (b == null) return (status: 'No backup yet', tone: Tone.warn, note: offsite);
  final when = whenText(b.finishedAt ?? b.startedAt, s.now);
  if (!b.ok) return (status: '$when · failed', tone: Tone.bad, note: b.error ?? offsite);
  final stale = s.now.difference(b.finishedAt ?? b.startedAt) > const Duration(hours: 26);
  return (status: '$when · OK', tone: stale ? Tone.warn : Tone.ok, note: offsite);
}

/// "Off-site copy 03:40 · OK", "Off-site copy set 27 Oct", "No off-site copy".
String offsiteText(OfficeNasState s) {
  final seen = _map(s.service('backup')?.detail['offsite']);
  final at = _time(seen['at']);
  if (at != null) return 'Off-site copy ${whenText(at, s.now)} · ${seen['ok'] == true ? 'OK' : 'failed'}';
  final manual = s.backup.lastCopyOn;
  if (manual != null) {
    final d = DateTime.tryParse(manual);
    if (d != null) return 'Off-site copy ${dayText(d)} (set by hand)';
  }
  return s.backup.offsite == OffsiteTarget.none ? 'No off-site copy yet' : 'Off-site copy: no date yet';
}

/// The Overview's Uptime card.
Card3 uptimeCard(OfficeNasState s) {
  final rows = [for (final r in s.uptimeRows()) if (r.target.on && r.status != null) r.status!];
  if (rows.isEmpty) return (status: 'Not checked yet', tone: Tone.idle, note: 'Checks start once the NAS or the cloud runs');
  final up = rows.where((r) => r.status == UptimeStatus.up || r.status == UptimeStatus.slow).length;
  final last = s.alerts.where((a) => a.kind == 'down').firstOrNull;
  return (
    status: '$up of ${rows.length} up',
    tone: up == rows.length ? (rows.any((r) => r.status == UptimeStatus.slow) ? Tone.warn : Tone.ok) : Tone.bad,
    note: last == null ? 'No alerts yet' : 'Last alert ${agoText(last.createdAt, s.now)}',
  );
}

/// The Overview's Restore test card.
Card3 restoreCard(OfficeNasState s) {
  final last = s.lastRestoreTest;
  final lastText = last == null
      ? 'Not run yet'
      : 'Last: ${dayText(last.startedAt)} · ${last.ok ? 'passed' : 'failed'}';
  if (!s.backup.restoreTestOn) return (status: 'Switched off', tone: Tone.warn, note: lastText);
  if (last != null && !last.ok && !last.running) return (status: 'Failed', tone: Tone.bad, note: last.error ?? lastText);
  final today = DateTime(s.now.year, s.now.month, s.now.day);
  final next = nextRestoreTest(today, s.backup.restoreTestDay, last?.startedAt);
  final days = next.difference(today).inDays;
  return (
    status: days <= 0 ? 'Due tonight' : 'Due in $days ${days == 1 ? 'day' : 'days'}',
    tone: last == null ? Tone.warn : Tone.ok,
    note: lastText,
  );
}

/// "memory 9.1 of 18 GB used · CPU 31% · disk 4.4 TB free of 7.0 TB · temperature 47 °C"
String? boxLine(OfficeNasState s) {
  final d = s.service('box')?.detail;
  if (d == null || d.isEmpty) return null;
  String gb(num mb) => (mb / 1024).toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
  final parts = [
    if (d['memUsedMb'] is num && d['memTotalMb'] is num)
      'memory ${gb(d['memUsedMb'] as num)} of ${gb(d['memTotalMb'] as num)} GB used',
    if (d['cpuPct'] is num) 'CPU ${(d['cpuPct'] as num).round()}%',
    if (d['diskFreeBytes'] is num && d['diskTotalBytes'] is num)
      'disk ${formatBytes((d['diskFreeBytes'] as num).round())} free of ${formatBytes((d['diskTotalBytes'] as num).round())}',
    if (d['tempC'] is num) 'temperature ${(d['tempC'] as num).round()} °C',
  ];
  return parts.isEmpty ? null : 'Box: ${parts.join(' · ')}';
}

/// A run in one line: "1.8 GB · 3,104 files · 6 min".
String runSummary(BackupRun r) {
  if (r.running) return 'Running since ${_hm(r.startedAt)}';
  if (!r.ok) return r.error ?? 'Failed';
  if (r.kind == RunKind.restoreTest) return '${r.detail['summary'] ?? 'Passed'}';
  final took = r.took;
  return [
    formatBytes(r.totalBytes ?? r.dbBytes),
    if (r.files != null) '${_thousands(r.files!)} ${r.files == 1 ? 'file' : 'files'}',
    if (took != null) durationText(took),
  ].join(' · ');
}

String _thousands(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

/// Whether [v] is a web address a target can check.
bool uptimeUrlOk(String v) {
  final s = v.trim();
  if (s == '{payment}' || s.startsWith('{project}/')) return true;
  final u = Uri.tryParse(s);
  return u != null && (u.scheme == 'https' || u.scheme == 'http') && u.host.isNotEmpty;
}
