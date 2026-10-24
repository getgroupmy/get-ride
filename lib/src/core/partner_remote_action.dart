// Edit Partner › Change status (migration 0286): support asks a partner's
// phone to go online, go offline, link or unlink a vehicle; the phone runs it
// through the driver's own code and says how it went. Pure: what each side
// shows, and the link a notification opens.
library;

/// What the phone can be asked to do.
enum RemoteAction {
  goOnline('go_online', 'Go online'),
  goOffline('go_offline', 'Go offline'),
  linkVehicle('link_vehicle', 'Link vehicle'),
  unlinkVehicle('unlink_vehicle', 'Unlink vehicle');

  const RemoteAction(this.wire, this.label);

  /// The value partner_remote_actions.action keeps.
  final String wire;

  /// The sheet's button.
  final String label;

  static RemoteAction? parse(Object? v) {
    for (final a in values) {
      if (a.wire == v) return a;
    }
    return null;
  }

  /// The phone's question until the driver taps it (as the server's
  /// partner_remote_action_prompt).
  String get prompt => switch (this) {
        goOnline => 'Support asked you to go online',
        goOffline => 'Support asked you to go offline',
        linkVehicle => 'Support asked you to use a vehicle',
        unlinkVehicle => 'Support asked you to hand back your vehicle',
      };

  /// What the card says once the phone did it.
  String get doneLine => switch (this) {
        goOnline => 'Done: the driver is online',
        goOffline => 'Done: the driver is offline',
        linkVehicle => 'Done: the vehicle is linked',
        unlinkVehicle => 'Done: the vehicle is unlinked',
      };
}

/// Where a request is.
enum RemoteStatus {
  queued,
  sent,
  done,
  refused,
  expired;

  static RemoteStatus parse(Object? v) => values.firstWhere((s) => s.name == v, orElse: () => queued);

  bool get open => this == queued || this == sent;
}

/// One request, as partner_remote_action_json gives it.
class RemoteActionRequest {
  const RemoteActionRequest({
    required this.id,
    required this.action,
    required this.status,
    this.vehicleId,
    this.vehiclePlate,
    this.reason,
    this.waitingDriver = false,
    this.createdAt,
    this.sentAt,
    this.answeredAt,
    this.expiresAt,
    this.serverNow,
  });

  /// Null for a row this app does not know how to read.
  static RemoteActionRequest? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final id = '${m['id'] ?? ''}';
    final action = RemoteAction.parse(m['action']);
    if (id.isEmpty || action == null) return null;
    DateTime? t(String k) => m[k] == null ? null : DateTime.tryParse('${m[k]}')?.toUtc();
    final vehicle = '${m['vehicle_id'] ?? ''}';
    final plate = '${m['vehicle_plate'] ?? ''}'.trim();
    final reason = '${m['reason'] ?? ''}'.trim();
    return RemoteActionRequest(
      id: id,
      action: action,
      status: RemoteStatus.parse(m['status']),
      vehicleId: vehicle.isEmpty ? null : vehicle,
      vehiclePlate: plate.isEmpty ? null : plate,
      reason: reason.isEmpty ? null : reason,
      waitingDriver: m['waiting_driver'] == true,
      createdAt: t('created_at'),
      sentAt: t('sent_at'),
      answeredAt: t('answered_at'),
      expiresAt: t('expires_at'),
      serverNow: t('now'),
    );
  }

  final String id;
  final RemoteAction action;
  final RemoteStatus status;
  final String? vehicleId;
  final String? vehiclePlate;
  final String? reason;

  /// The phone has it and waits for the driver's tap.
  final bool waitingDriver;
  final DateTime? createdAt;
  final DateTime? sentAt;
  final DateTime? answeredAt;
  final DateTime? expiresAt;

  /// The server's clock when it was read, so the card's waits don't depend
  /// on the admin's.
  final DateTime? serverNow;
}

/// A phone that has not answered this long after the push went out is taken
/// to be closed: its notification waits for the driver.
const remoteClosedAfter = Duration(seconds: 15);

/// How the card shows a request.
enum RemoteLineKind { waiting, done, refused, expired }

/// The card's line for [r] at [now] (the server's, when it gave one).
({RemoteLineKind kind, String text}) remoteRequestLine(RemoteActionRequest r, {DateTime? now}) {
  switch (r.status) {
    case RemoteStatus.done:
      return (kind: RemoteLineKind.done, text: r.action.doneLine);
    case RemoteStatus.refused:
      return (kind: RemoteLineKind.refused, text: 'Refused: ${r.reason ?? 'the phone said no'}');
    case RemoteStatus.expired:
      return (kind: RemoteLineKind.expired, text: 'No answer (expired)');
    case RemoteStatus.queued:
    case RemoteStatus.sent:
      final at = now ?? r.serverNow ?? DateTime.now().toUtc();
      final sent = r.sentAt;
      final quiet = r.status == RemoteStatus.sent && sent != null && at.difference(sent) >= remoteClosedAfter;
      if (r.waitingDriver || quiet) return (kind: RemoteLineKind.waiting, text: 'Waiting for the driver (app closed)');
      return (kind: RemoteLineKind.waiting, text: 'Waiting for their phone…');
  }
}

/// The line the driver's own notifications keep once it was done
/// (partner_remote_action_report writes it with [localTime]).
String remoteDoneNotice(RemoteAction a, String localTime) {
  final what = switch (a) {
    RemoteAction.goOnline => 'Support set you online',
    RemoteAction.goOffline => 'Support set you offline',
    RemoteAction.linkVehicle => 'Support linked your vehicle',
    RemoteAction.unlinkVehicle => 'Support unlinked your vehicle',
  };
  return localTime.trim().isEmpty ? '$what.' : '$what at ${localTime.trim()}.';
}

/// "3:12 PM": the phone's clock for that line.
String remoteLocalTime(DateTime t) {
  final l = t.toLocal();
  final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
  return '$h:${l.minute.toString().padLeft(2, '0')} ${l.hour < 12 ? 'AM' : 'PM'}';
}

/// The Drive page that runs request [id] once the driver is there.
String remoteActionRoute(String id) => '/drive?remote=${Uri.encodeQueryComponent(id)}';

final _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// `getride://remote/<id>`, the link the Android notification opens: the
/// Drive page that runs it. Null for any other link.
String? remoteActionLinkLocation(Uri uri) {
  if (uri.scheme.toLowerCase() != 'getride' || uri.host.toLowerCase() != 'remote') return null;
  final segs = [
    for (final s in uri.pathSegments)
      if (s.isNotEmpty) s,
  ];
  if (segs.length != 1 || !_uuid.hasMatch(segs.single)) return null;
  return remoteActionRoute(segs.single.toLowerCase());
}

/// The request id a push or a notification carries, or null.
String? remoteActionIdFromPush(Map<String, dynamic> data) {
  if (data['type'] != 'partner_remote_action') return null;
  final id = '${data['id'] ?? ''}'.trim();
  return _uuid.hasMatch(id) ? id.toLowerCase() : null;
}

/// The phone's side of the requests (PartnerRemoteRepository; a fake in
/// tests).
abstract interface class RemoteActionInbox {
  /// This account's open request [id] (the newest open one without), or null.
  Future<RemoteActionRequest?> mine([String? id]);

  /// The phone has it; [waitingDriver] while it waits for the driver's tap.
  Future<void> seen(String id, {required bool waitingDriver});

  /// What the driver's own code said: done (null [reason]) or refused.
  Future<void> report(String id, {String? reason, required String localTime});
}

/// What the driver's own buttons run, each answering null when it was done
/// or the words their own flow showed when it was not. The Drive screen's
/// switch and the vehicle card's Select / Hand back are the only ones.
abstract interface class DriverRemoteActions {
  Future<String?> goOnline();
  Future<String?> goOffline();
  Future<String?> linkVehicle(String vehicleId);
  Future<String?> unlinkVehicle();
}
