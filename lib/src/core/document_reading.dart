/// Document reading (migration 0293): who reads a document's photo, in what
/// order, each switched on or off in Admin › Settings › Document reading.
///
/// - phone: the driver's phone, at upload (free, instant)
/// - nas:   the office NAS, plates and document numbers in the background
/// - gpu:   a GPU reading PC, whole documents (listed once one is connected)
/// - cloud: Google Cloud Vision or the vision AI set in API Keys
///
/// The server keeps the same shape (`document_reading_normalize`). Pure.
library;

enum DocReaderId {
  phone('Driver\'s phone', 'Photo check and the fields, at upload. Free and instant.'),
  nas('Office NAS', 'Plates and document numbers, read in the background.'),
  gpu('GPU reading PC', 'Whole documents, read in-house.'),
  cloud('Cloud reader', 'Google Cloud Vision or the vision AI set in API Keys. Whole documents.');

  const DocReaderId(this.label, this.help);
  final String label;
  final String help;

  static DocReaderId? of(Object? key) {
    for (final r in values) {
      if (r.name == key) return r;
    }
    return null;
  }
}

/// One reader's place in the order.
class DocReaderSlot {
  const DocReaderSlot(this.id, this.on);
  final DocReaderId id;
  final bool on;

  Map<String, dynamic> toJson() => {'id': id.name, 'on': on};

  @override
  bool operator ==(Object other) => other is DocReaderSlot && other.id == id && other.on == on;

  @override
  int get hashCode => Object.hash(id, on);
}

/// What the NAS reads.
enum NasJob {
  plates('Plates', 'Vehicle photos, grants and cover notes'),
  numbers('Document numbers', 'IC, licence, permit, cover note, chassis and engine numbers'),
  qr('QR codes', 'Licence, permit and e-invoice QR codes'),
  checks('Total, tax and duplicate checks', 'On invoices');

  const NasJob(this.label, this.help);
  final String label;
  final String help;
}

const defaultPassOnBelow = 90;

class DocumentReadingConfig {
  const DocumentReadingConfig({required this.readers, required this.nasJobs, this.passOnBelow = defaultPassOnBelow});

  /// Every reader once, in reading order.
  final List<DocReaderSlot> readers;
  final Map<NasJob, bool> nasJobs;

  /// A NAS reading less sure than this (percent) is passed on.
  final int passOnBelow;

  static const defaults = DocumentReadingConfig(
    readers: [
      DocReaderSlot(DocReaderId.phone, true),
      DocReaderSlot(DocReaderId.nas, true),
      DocReaderSlot(DocReaderId.gpu, true),
      DocReaderSlot(DocReaderId.cloud, true),
    ],
    nasJobs: {NasJob.plates: true, NasJob.numbers: true, NasJob.qr: true, NasJob.checks: true},
  );

  /// Read leniently, like the server: unknown and repeated readers dropped,
  /// missing ones added at the end, on.
  factory DocumentReadingConfig.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    final seen = <DocReaderId>{};
    final readers = <DocReaderSlot>[];
    final list = m['readers'];
    if (list is List) {
      for (final r in list) {
        if (r is! Map) continue;
        final id = DocReaderId.of(r['id']);
        if (id == null || !seen.add(id)) continue;
        readers.add(DocReaderSlot(id, r['on'] is bool ? r['on'] as bool : true));
      }
    }
    for (final id in DocReaderId.values) {
      if (seen.add(id)) readers.add(DocReaderSlot(id, true));
    }
    final jobs = m['nasJobs'] is Map ? m['nasJobs'] as Map : const {};
    final pass = m['passOnBelow'];
    return DocumentReadingConfig(
      readers: readers,
      nasJobs: {for (final j in NasJob.values) j: jobs[j.name] is bool ? jobs[j.name] as bool : true},
      passOnBelow: (pass is num ? pass.round() : defaultPassOnBelow).clamp(50, 100),
    );
  }

  Map<String, dynamic> toJson() => {
        'readers': [for (final r in readers) r.toJson()],
        'nasJobs': {for (final e in nasJobs.entries) e.key.name: e.value},
        'passOnBelow': passOnBelow,
      };

  bool isOn(DocReaderId id) => readers.any((r) => r.id == id && r.on);

  /// The switched-on readers, in order.
  List<DocReaderId> get order => [for (final r in readers) if (r.on) r.id];

  /// Whether [a] reads before [b] (both switched on or not).
  bool before(DocReaderId a, DocReaderId b) =>
      readers.indexWhere((r) => r.id == a) < readers.indexWhere((r) => r.id == b);

  DocumentReadingConfig copyWith({List<DocReaderSlot>? readers, Map<NasJob, bool>? nasJobs, int? passOnBelow}) =>
      DocumentReadingConfig(
        readers: readers ?? this.readers,
        nasJobs: nasJobs ?? this.nasJobs,
        passOnBelow: passOnBelow ?? this.passOnBelow,
      );

  /// [id] moved up ([by] -1) or down (+1) past the next reader that is
  /// [shown] (a hidden GPU PC keeps its place).
  DocumentReadingConfig move(DocReaderId id, int by, {Set<DocReaderId>? shown}) {
    final list = [...readers];
    final from = list.indexWhere((r) => r.id == id);
    if (from < 0) return this;
    var to = from + by.sign;
    while (to >= 0 && to < list.length && shown != null && !shown.contains(list[to].id)) {
      to += by.sign;
    }
    if (to < 0 || to >= list.length) return this;
    final r = list.removeAt(from);
    list.insert(to, r);
    return copyWith(readers: list);
  }

  DocumentReadingConfig toggled(DocReaderId id, bool on) =>
      copyWith(readers: [for (final r in readers) r.id == id ? DocReaderSlot(id, on) : r]);

  DocumentReadingConfig withJob(NasJob job, bool on) => copyWith(nasJobs: {...nasJobs, job: on});
}

/// The readers the admin sees: a GPU PC only once one is connected.
List<DocReaderSlot> shownReaders(DocumentReadingConfig c, {required bool gpuConnected}) =>
    [for (final r in c.readers) if (r.id != DocReaderId.gpu || gpuConnected) r];

/// "Documents go to: Driver's phone, then Office NAS, then Cloud reader."
String readingSummary(List<DocReaderSlot> shown) {
  final on = [for (final r in shown) if (r.on) r.id.label];
  if (on.isEmpty) return 'Every reader is off: documents wait for a person.';
  return 'Documents go to: ${on.join(', then ')}.';
}

// ---- Connected readers (admin_doc_readers) -------------------------------------------------

/// Today's work of one kind (plates, numbers, qr).
class ReaderDay {
  const ReaderDay({this.done = 0, this.passedOn = 0, this.failed = 0, this.avgMs});
  final int done;
  final int passedOn;
  final int failed;
  final int? avgMs;

  factory ReaderDay.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    int n(Object? v) => v is num ? v.toInt() : 0;
    return ReaderDay(
      done: n(m['done']),
      passedOn: n(m['passed_on']),
      failed: n(m['failed']),
      avgMs: m['avg_ms'] is num ? (m['avg_ms'] as num).toInt() : null,
    );
  }
}

class ConnectedReader {
  const ConnectedReader({
    required this.id,
    required this.kind,
    required this.label,
    this.model,
    this.appVersion,
    this.lastSeenAt,
    this.online = false,
    this.today = const {},
  });

  final String id;
  final DocReaderId kind;
  final String label;
  final String? model;
  final String? appVersion;
  final DateTime? lastSeenAt;
  final bool online;
  final Map<String, ReaderDay> today;

  static ConnectedReader? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = DocReaderId.of(json['kind']);
    if (kind != DocReaderId.nas && kind != DocReaderId.gpu) return null;
    final today = json['today'] is Map ? json['today'] as Map : const {};
    String? s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    return ConnectedReader(
      id: '${json['id']}',
      kind: kind!,
      label: s(json['label']) ?? kind.label,
      model: s(json['model']),
      appVersion: s(json['app_version']),
      lastSeenAt: DateTime.tryParse('${json['last_seen_at']}'),
      online: json['online'] == true,
      today: {for (final e in today.entries) '${e.key}': ReaderDay.fromJson(e.value)},
    );
  }
}

class ReadersState {
  const ReadersState({this.readers = const [], this.waiting = 0});
  final List<ConnectedReader> readers;
  final int waiting;

  factory ReadersState.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    final list = m['readers'] is List ? m['readers'] as List : const [];
    return ReadersState(
      readers: [for (final r in list) ?ConnectedReader.fromJson(r)],
      waiting: m['waiting'] is num ? (m['waiting'] as num).toInt() : 0,
    );
  }

  List<ConnectedReader> of(DocReaderId kind) => [for (final r in readers) if (r.kind == kind) r];
}

/// "1.2 s" from milliseconds; "–" when nothing was read.
String readerSeconds(int? ms) => ms == null ? '–' : '${(ms / 1000).toStringAsFixed(1)} s';

/// "Online, last seen 20 s ago" / "Offline, last seen 3 h ago" / "Never checked in".
String readerSeen(ConnectedReader r, DateTime now) {
  final at = r.lastSeenAt;
  if (at == null) return 'Never checked in';
  final d = now.difference(at);
  final ago = d.inSeconds < 60
      ? '${d.inSeconds.clamp(0, 59)} s'
      : d.inMinutes < 60
          ? '${d.inMinutes} min'
          : d.inHours < 48
              ? '${d.inHours} h'
              : '${d.inDays} days';
  return '${r.online ? 'Online' : 'Offline'}, last seen $ago ago';
}
