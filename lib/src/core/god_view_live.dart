// Admin → God View (migration 0282): "Update" (fresh phone details through a
// ping), "Live now" (the person's position every 5 s for a while) and a new
// phone number waiting for its SMS confirm. Pure: the page only draws.
library;

import 'god_view.dart' show godViewAge, godViewClock;
import 'god_view_trail.dart';

// ---- Update: fresh phone details -----------------------------------------------------------------

/// Where an "Update" stands beside the phone's last report.
enum GodViewUpdateStage { sending, waiting, updated, noAnswer, recent, noPhone, failed }

/// How long the page waits for the details: a closed iPhone has 30 s to
/// answer a silent push, a phone in Doze a little more.
const godViewUpdateWait = Duration(seconds: 45);

/// The line under "From the phone's last report…" once Update was tapped.
String godViewUpdateLine(GodViewUpdateStage stage, {DateTime? at, DateTime? now}) => switch (stage) {
  GodViewUpdateStage.sending || GodViewUpdateStage.waiting => 'Asking the phone…',
  GodViewUpdateStage.updated => godViewUpdatedLabel(at, now ?? DateTime.now()),
  GodViewUpdateStage.noAnswer => 'No answer. The phone may be off, or the app closed by swiping it away.',
  GodViewUpdateStage.recent =>
    at == null ? 'Asked in the last 2 minutes. Try again shortly.' : 'Asked in the last 2 minutes. Try again after ${godViewClock(at)}.',
  GodViewUpdateStage.noPhone => 'No phone to ask: none has location set to always with background reporting.',
  GodViewUpdateStage.failed => 'Could not ask the phone. Try again later.',
};

/// "Updated just now" for a minute, then "Updated 3 min ago".
String godViewUpdatedLabel(DateTime? at, DateTime now) {
  if (at == null || now.difference(at) < const Duration(minutes: 1)) return 'Updated just now';
  return 'Updated ${godViewAge(at, now)}';
}

// ---- Live now ------------------------------------------------------------------------------------

/// The lengths an admin can pick.
const godViewLiveChoices = <int>[5, 15, 60];

String godViewLiveChoiceLabel(int minutes) => minutes == 60 ? '1 hour' : '$minutes min';

/// How often the phone sends its position while live.
const godViewLiveEvery = Duration(seconds: 5);

/// A phone that has sent nothing this long after the start is not streaming
/// (an iPhone with the app closed).
const godViewLiveStartWait = Duration(seconds: 20);

/// One point of a live share: the server's id (to ask for what came after)
/// and the position.
class GodViewLivePoint {
  const GodViewLivePoint(this.id, this.point);
  final int id;
  final TrailPoint point;

  /// `[id, lat, lng, epoch seconds, speed]`, as god_view_live_status sends.
  static GodViewLivePoint? fromJson(Object? row) {
    if (row is! List || row.length < 4) return null;
    final id = (row[0] as num?)?.toInt();
    final p = TrailPoint.fromJson(row.sublist(1));
    return id == null || p == null ? null : GodViewLivePoint(id, p);
  }

  /// A god_view_live_points row as realtime delivers it.
  static GodViewLivePoint? fromRow(Map<String, dynamic> r) {
    final id = (r['id'] as num?)?.toInt();
    final lat = (r['lat'] as num?)?.toDouble();
    final lng = (r['lng'] as num?)?.toDouble();
    final at = DateTime.tryParse('${r['captured_at'] ?? ''}')?.toUtc();
    if (id == null || lat == null || lng == null || at == null) return null;
    return GodViewLivePoint(id, TrailPoint(lat, lng, at, speed: (r['speed'] as num?)?.toDouble()));
  }
}

/// One live share as the server has it.
class GodViewLiveSession {
  const GodViewLiveSession({
    required this.id,
    required this.profileId,
    required this.startedAt,
    required this.endsAt,
    this.stoppedAt,
    this.firstPointAt,
    this.lastPointAt,
    this.points = 0,
  });

  static GodViewLiveSession? fromJson(Object? j) {
    if (j is! Map) return null;
    DateTime? t(String k) => DateTime.tryParse('${j[k] ?? ''}')?.toUtc();
    final id = j['id'], started = t('started_at'), ends = t('ends_at');
    if (id == null || started == null || ends == null) return null;
    return GodViewLiveSession(
      id: '$id',
      profileId: '${j['profile_id'] ?? ''}',
      startedAt: started,
      endsAt: ends,
      stoppedAt: t('stopped_at'),
      firstPointAt: t('first_point_at'),
      lastPointAt: t('last_point_at'),
      points: (j['points'] as num?)?.toInt() ?? 0,
    );
  }

  final String id;
  final String profileId;
  final DateTime startedAt;
  final DateTime endsAt;
  final DateTime? stoppedAt;
  final DateTime? firstPointAt;
  final DateTime? lastPointAt;
  final int points;
}

/// Where a live share stands on the page.
enum GodViewLiveStage { off, starting, live, noAnswer }

/// The stage of [s] at [now] (the server's clock): off when there is none or
/// it is over; starting until the first point, for [godViewLiveStartWait];
/// then live, or no answer when nothing came.
GodViewLiveStage godViewLiveStageOf(GodViewLiveSession? s, DateTime now) {
  if (s == null || s.stoppedAt != null || !now.isBefore(s.endsAt)) return GodViewLiveStage.off;
  if (s.firstPointAt != null) return GodViewLiveStage.live;
  return now.difference(s.startedAt) < godViewLiveStartWait ? GodViewLiveStage.starting : GodViewLiveStage.noAnswer;
}

/// "14:55", "0:07", "60:00": the minutes and seconds to [endsAt].
String godViewLiveLeft(DateTime endsAt, DateTime now) {
  final s = endsAt.difference(now).inMilliseconds;
  final secs = s <= 0 ? 0 : (s / 1000).ceil();
  return '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}';
}

/// The button while a share is on: "Stop live · 14:55 left".
String godViewLiveStopLabel(DateTime endsAt, DateTime now) => 'Stop live · ${godViewLiveLeft(endsAt, now)} left';

/// The line under the live button.
String godViewLiveNowLine(GodViewLiveStage stage) => switch (stage) {
  GodViewLiveStage.off => 'Their position every 5 s, on the map, for a while.',
  GodViewLiveStage.starting => 'Waiting for their phone to start…',
  GodViewLiveStage.live => 'Live · every 5 s. Stops by itself at the end.',
  GodViewLiveStage.noAnswer => 'Open the app on their phone to go live. Until then, pings still work.',
};

/// What god_view_live_start answered.
class GodViewLiveStart {
  const GodViewLiveStart({this.session, this.phones, this.posted, this.already = false});

  factory GodViewLiveStart.fromJson(Map<String, dynamic> j) => GodViewLiveStart(
    session: GodViewLiveSession.fromJson(j['session']),
    phones: (j['phones'] as num?)?.toInt(),
    posted: j['posted'] is bool ? j['posted'] as bool : null,
    already: j['already'] == true,
  );

  final GodViewLiveSession? session;

  /// The phones the push went to; null for a share already on.
  final int? phones;
  final bool? posted;

  /// A share was already on (another admin started it).
  final bool already;

  /// Why nothing started, or null.
  String? get problem {
    if (session != null) return posted == false ? 'Live could not reach their phone. Try again later.' : null;
    if (phones == 0) return "No phone to go live with: none has location set to always with the app's background reporting.";
    return 'Live could not be started. Try again later.';
  }
}

/// A live share on the page: the session, its points so far, oldest first,
/// and how far the admin's clock is behind the server's.
class GodViewLiveView {
  const GodViewLiveView({required this.personId, this.session, this.points = const [], this.skew = Duration.zero});

  final String personId;
  final GodViewLiveSession? session;
  final List<GodViewLivePoint> points;

  /// The server's clock minus the admin's.
  final Duration skew;

  /// The newest point's id, to ask for what came after.
  int get lastId => points.isEmpty ? 0 : points.last.id;

  GodViewLiveStage stageAt(DateTime now) => godViewLiveStageOf(session, now.add(skew));

  /// The newest point, when there is one.
  TrailPoint? get latest => points.isEmpty ? null : points.last.point;

  List<TrailPoint> get trail => [for (final p in points) p.point];

  /// [more] points added (each once, in id order); a point counts as the
  /// session's first if the server had none yet.
  GodViewLiveView withPoints(Iterable<GodViewLivePoint> more, {GodViewLiveSession? session, Duration? skew}) {
    final byId = {for (final p in points) p.id: p};
    for (final p in more) {
      byId[p.id] = p;
    }
    final list = byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    var s = session ?? this.session;
    if (s != null && s.firstPointAt == null && list.isNotEmpty) {
      s = GodViewLiveSession(
        id: s.id,
        profileId: s.profileId,
        startedAt: s.startedAt,
        endsAt: s.endsAt,
        stoppedAt: s.stoppedAt,
        firstPointAt: list.first.point.at,
        lastPointAt: list.last.point.at,
        points: list.length,
      );
    }
    return GodViewLiveView(personId: personId, session: s, points: list, skew: skew ?? this.skew);
  }
}

/// The person's own notice while a share is on: "Shared live with support
/// · 14:55 left".
String liveShareNoticeText(DateTime endsAt, DateTime now) =>
    'Shared live with support · ${godViewLiveLeft(endsAt, now)} left';

// ---- A new phone number --------------------------------------------------------------------------

/// A number change an admin asked for (admin_phone_change_status).
class PhoneChangeStatus {
  const PhoneChangeStatus({required this.status, this.phoneTail, this.phoneMasked, this.expiresAt, this.confirmedAt});

  static PhoneChangeStatus? fromJson(Object? j) {
    if (j is! Map || j['status'] is! String) return null;
    return PhoneChangeStatus(
      status: j['status'] as String,
      phoneTail: j['phone_tail'] as String?,
      phoneMasked: j['phone_masked'] as String?,
      expiresAt: DateTime.tryParse('${j['expires_at'] ?? ''}')?.toUtc(),
      confirmedAt: DateTime.tryParse('${j['confirmed_at'] ?? ''}')?.toUtc(),
    );
  }

  /// waiting, confirmed, expired, cancelled or unknown.
  final String status;
  final String? phoneTail;
  final String? phoneMasked;
  final DateTime? expiresAt;
  final DateTime? confirmedAt;

  bool get waiting => status == 'waiting';
}

/// The line under the Phone row, or null when there is nothing to say (a
/// change confirmed over a day ago, or cancelled).
String? phoneChangeLine(PhoneChangeStatus? s, DateTime now) {
  if (s == null) return null;
  final tail = s.phoneTail == null ? 'the new number' : 'the number ending ${s.phoneTail}';
  return switch (s.status) {
    'waiting' => 'New number ending ${s.phoneTail ?? '…'}: waiting for SMS confirm',
    'confirmed' when s.confirmedAt != null && now.difference(s.confirmedAt!) < const Duration(days: 1) =>
      'Changed to $tail. The old number no longer signs in.',
    'expired' => 'The SMS link for $tail expired. Send it again.',
    _ => null,
  };
}
