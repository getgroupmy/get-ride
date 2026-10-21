// Trip safety signals (reliability Phase D4; the server half is migration
// 0154): was the passenger there when the trip started, did the phones drift
// apart mid-trip, and did the passenger leave something behind. Pure.
// 0269 adds the route check (the car leaving the planned route, or stopping)
// and when a trip is shared with the rider's emergency contacts.
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// The admin's switches, kept in the reliability-messaging row (read the
/// same way server-side by reliability_safety()). The start and mid-trip
/// checks and the route check are on unless turned off (0269); lost items
/// stays off until turned on.
class SafetySettings {
  const SafetySettings({
    this.startCheck = true,
    this.separation = true,
    this.lostItems = false,
    this.farApartM = defaultFarApartM,
    this.separationMin = defaultSeparationMin,
    this.routeCheck = true,
    this.routeOffM = defaultRouteOffM,
    this.routeOffMin = defaultRouteOffMin,
    this.stoppedMin = defaultStoppedMin,
    this.noAnswerS = defaultNoAnswerS,
    this.autoShare = true,
  });

  static const defaultFarApartM = 300;
  static const defaultSeparationMin = 3;
  static const minFarApart = 100, maxFarApart = 5000, minSeparation = 1, maxSeparation = 30;
  static const defaultRouteOffM = 500, defaultRouteOffMin = 2, defaultStoppedMin = 5, defaultNoAnswerS = 60;
  static const minRouteOff = 100, maxRouteOff = 5000, minRouteOffMin = 1, maxRouteOffMin = 30;
  static const minStopped = 1, maxStopped = 60, minNoAnswer = 15, maxNoAnswer = 600;

  /// A trip started without the passenger nearby is flagged and they're asked.
  final bool startCheck;

  /// The phones staying apart mid-trip asks the passenger if they're OK.
  final bool separation;

  /// Passengers can report something left in the car.
  final bool lostItems;

  /// How far apart the phones must be to count as apart.
  final int farApartM;

  /// How long they must stay apart mid-trip.
  final int separationMin;

  /// The car leaving the planned route (or stopping) asks the passenger.
  final bool routeCheck;

  /// How far off the route, for how long.
  final int routeOffM, routeOffMin;

  /// Stopped this long mid-trip.
  final int stoppedMin;

  /// No answer in this many seconds alerts the contacts and support.
  final int noAnswerS;

  /// A trip that starts is shared with the rider's emergency contacts, as
  /// each rider chose (every trip, at night, never).
  final bool autoShare;

  factory SafetySettings.fromValues(Map<String, dynamic>? v) => SafetySettings(
    startCheck: _on(v?['safety_start_check'], fallback: true),
    separation: _on(v?['safety_separation'], fallback: true),
    lostItems: _on(v?['safety_lost_items']),
    farApartM: _clamp(v?['safety_far_apart_m'], defaultFarApartM, minFarApart, maxFarApart),
    separationMin: _clamp(v?['safety_separation_min'], defaultSeparationMin, minSeparation, maxSeparation),
    routeCheck: _on(v?['safety_route_check'], fallback: true),
    routeOffM: _clamp(v?['safety_route_off_m'], defaultRouteOffM, minRouteOff, maxRouteOff),
    routeOffMin: _clamp(v?['safety_route_off_min'], defaultRouteOffMin, minRouteOffMin, maxRouteOffMin),
    stoppedMin: _clamp(v?['safety_stopped_min'], defaultStoppedMin, minStopped, maxStopped),
    noAnswerS: _clamp(v?['safety_no_answer_s'], defaultNoAnswerS, minNoAnswer, maxNoAnswer),
    autoShare: _on(v?['safety_auto_share'], fallback: true),
  );

  Map<String, dynamic> toValues() => {
    'safety_start_check': startCheck,
    'safety_separation': separation,
    'safety_lost_items': lostItems,
    'safety_far_apart_m': farApartM,
    'safety_separation_min': separationMin,
    'safety_route_check': routeCheck,
    'safety_route_off_m': routeOffM,
    'safety_route_off_min': routeOffMin,
    'safety_stopped_min': stoppedMin,
    'safety_no_answer_s': noAnswerS,
    'safety_auto_share': autoShare,
  };

  SafetySettings copyWith({
    bool? startCheck,
    bool? separation,
    bool? lostItems,
    int? farApartM,
    int? separationMin,
    bool? routeCheck,
    int? routeOffM,
    int? routeOffMin,
    int? stoppedMin,
    int? noAnswerS,
    bool? autoShare,
  }) => SafetySettings.fromValues({
    ...toValues(),
    'safety_start_check': ?startCheck,
    'safety_separation': ?separation,
    'safety_lost_items': ?lostItems,
    'safety_far_apart_m': ?farApartM,
    'safety_separation_min': ?separationMin,
    'safety_route_check': ?routeCheck,
    'safety_route_off_m': ?routeOffM,
    'safety_route_off_min': ?routeOffMin,
    'safety_stopped_min': ?stoppedMin,
    'safety_no_answer_s': ?noAnswerS,
    'safety_auto_share': ?autoShare,
  });

  @override
  bool operator ==(Object other) =>
      other is SafetySettings && mapEqualsShallow(other.toValues(), toValues());

  @override
  int get hashCode => Object.hashAll(toValues().values);
}

/// Two flat maps with the same keys and values.
bool mapEqualsShallow(Map<String, dynamic> a, Map<String, dynamic> b) =>
    a.length == b.length && a.entries.every((e) => b.containsKey(e.key) && b[e.key] == e.value);

bool _on(Object? v, {bool fallback = false}) => switch (v) {
  null || '' => fallback,
  true || 'true' || 't' || 1 || '1' || 'on' => true,
  _ => false,
};

int _clamp(Object? v, int fallback, int lo, int hi) {
  final n = v is num ? v.toInt() : int.tryParse('${v ?? ''}');
  if (n == null) return fallback;
  return n < lo ? lo : (n > hi ? hi : n);
}

// ---- The passenger's question ------------------------------------------------------

enum SafetyAsk {
  /// The trip started without the passenger's phone nearby.
  startCheck,

  /// Mid-trip, the phones drifted apart.
  separation,
}

/// What to ask the passenger now, if anything: the latest flag they haven't
/// answered, while the trip is on.
SafetyAsk? safetyAsk({required bool onTrip, DateTime? startFlagAt, DateTime? separatedAt, DateTime? ackAt}) {
  if (!onTrip) return null;
  bool open(DateTime? at) => at != null && (ackAt == null || ackAt.isBefore(at));
  if (open(separatedAt)) return SafetyAsk.separation;
  if (open(startFlagAt)) return SafetyAsk.startCheck;
  return null;
}

({String title, String body, String ok}) safetyAskCopy(SafetyAsk a) => switch (a) {
  SafetyAsk.startCheck => (
    title: 'Are you in the car?',
    body: 'Your trip has started, but your phone didn\'t seem to be with your driver.',
    ok: 'Yes, I\'m in the car',
  ),
  SafetyAsk.separation => (
    title: 'Are you still on your trip?',
    body: 'Your phone and your driver\'s seem to be apart.',
    ok: 'I\'m OK',
  ),
};

// ---- Left something behind ---------------------------------------------------------

/// How long after a trip a lost item can be reported (the server allows 7 days).
const lostItemWindow = Duration(days: 7);

/// Whether the passenger may still report a lost item for a trip that
/// completed at [completedAt].
bool canReportLostItem({
  required bool enabled,
  required bool completed,
  DateTime? completedAt,
  required DateTime now,
}) => enabled && completed && completedAt != null && now.difference(completedAt) < lostItemWindow;

enum LostItemStatus {
  open('Waiting for your driver'),
  found('Found'),
  notFound('Not found'),
  returned('Returned');

  const LostItemStatus(this.label);
  final String label;

  String get db => switch (this) {
    LostItemStatus.notFound => 'not_found',
    _ => name,
  };

  static LostItemStatus parse(Object? v) => switch (v) {
    'found' => LostItemStatus.found,
    'not_found' => LostItemStatus.notFound,
    'returned' => LostItemStatus.returned,
    _ => LostItemStatus.open,
  };
}

class LostItem {
  const LostItem({
    required this.id,
    required this.requestId,
    required this.description,
    this.status = LostItemStatus.open,
    this.driverNote,
    this.createdAt,
  });

  final String id;
  final String requestId;
  final String description;
  final LostItemStatus status;
  final String? driverNote;
  final DateTime? createdAt;

  factory LostItem.fromRow(Map<String, dynamic> m) => LostItem(
    id: '${m['id']}',
    requestId: '${m['request_id']}',
    description: '${m['description'] ?? ''}',
    status: LostItemStatus.parse(m['status']),
    driverNote: (m['driver_note'] as String?)?.trim().isEmpty ?? true ? null : m['driver_note'] as String,
    createdAt: DateTime.tryParse('${m['created_at'] ?? ''}'),
  );
}

/// What the passenger may type: trimmed, 2–500 characters; null when it isn't.
String? cleanLostItemText(String? input) {
  final s = (input ?? '').trim();
  if (s.length < 2) return null;
  return s.length > 500 ? s.substring(0, 500) : s;
}

/// The server's refusal, in words.
String lostItemError(Object e) {
  final s = '$e';
  if (s.contains('too_late')) return 'It\'s too late to report this trip — contact support instead.';
  if (s.contains('too_many')) return 'You\'ve reported this trip several times today. Contact support for more help.';
  if (s.contains('lost_items_off')) return 'Lost item reports aren\'t available right now.';
  if (s.contains('describe_it')) return 'Say what you left behind.';
  return 'Couldn\'t send the report. Check your connection and try again.';
}

// ---- Admin: what happened ----------------------------------------------------------

class TripSafetySummary {
  const TripSafetySummary({
    this.startFlags = 0,
    this.separations = 0,
    this.answeredOk = 0,
    this.lostOpen = 0,
    this.lostFound = 0,
  });

  final int startFlags, separations, answeredOk, lostOpen, lostFound;

  factory TripSafetySummary.fromRow(Object? row) {
    final m = row is List && row.isNotEmpty ? row.first : row;
    if (m is! Map) return const TripSafetySummary();
    int n(String k) => (m[k] as num?)?.toInt() ?? 0;
    return TripSafetySummary(
      startFlags: n('start_flags'),
      separations: n('separations'),
      answeredOk: n('answered_ok'),
      lostOpen: n('lost_open'),
      lostFound: n('lost_found'),
    );
  }

  String describe(int days) {
    final flagged = startFlags + separations;
    final parts = [
      if (flagged == 0)
        'No trips flagged'
      else
        '$startFlags started away from the passenger · $separations apart mid-trip',
      if (flagged > 0) '$answeredOk answered OK',
      '$lostOpen lost items waiting · $lostFound found',
    ];
    return 'Last $days days: ${parts.join(' · ')}';
  }
}

// ---- The route check (0269) --------------------------------------------------------

/// What the route check noticed.
enum RouteAlertKind {
  /// Off the planned route by the admin's metres, for their minutes.
  offRoute,

  /// Not moving for the admin's minutes.
  stopped;

  /// As trip_route_report stores it.
  String get db => this == offRoute ? 'off_route' : 'stopped';
}

class RouteAlert {
  const RouteAlert(this.kind, {this.offM, required this.since});
  final RouteAlertKind kind;

  /// How far off the route, in metres (off route only).
  final int? offM;
  final DateTime since;
}

/// The rider's sheet: "Your car has left the planned route".
({String title, String body}) routeAlertCopy(RouteAlert a, {required int minutes}) => switch (a.kind) {
  RouteAlertKind.offRoute => (
    title: 'Your car has left the planned route',
    body: 'It is ${a.offM ?? 0} m off the route for $minutes ${minutes == 1 ? 'minute' : 'minutes'}. Is everything OK?',
  ),
  RouteAlertKind.stopped => (
    title: 'Your car has stopped',
    body: 'It hasn\'t moved for $minutes ${minutes == 1 ? 'minute' : 'minutes'}. Is everything OK?',
  ),
};

/// Metres from [p] to the nearest point of the polyline [route] (flat-earth
/// over the short distances involved). Infinity for an empty route.
double distanceToRouteM(LatLng p, List<LatLng> route) {
  if (route.isEmpty) return double.infinity;
  const r = 6371000.0;
  final lat0 = p.latitude * math.pi / 180;
  final kx = r * math.cos(lat0) * math.pi / 180, ky = r * math.pi / 180;
  ({double x, double y}) xy(LatLng q) => (x: (q.longitude - p.longitude) * kx, y: (q.latitude - p.latitude) * ky);
  if (route.length == 1) {
    final a = xy(route.first);
    return math.sqrt(a.x * a.x + a.y * a.y);
  }
  var best = double.infinity;
  for (var i = 0; i + 1 < route.length; i++) {
    final a = xy(route[i]), b = xy(route[i + 1]);
    final dx = b.x - a.x, dy = b.y - a.y;
    final len2 = dx * dx + dy * dy;
    final t = len2 == 0 ? 0.0 : ((-a.x * dx - a.y * dy) / len2).clamp(0.0, 1.0);
    final cx = a.x + t * dx, cy = a.y + t * dy;
    final d = math.sqrt(cx * cx + cy * cy);
    if (d < best) best = d;
  }
  return best;
}

/// Watches the car's positions on a trip against its planned route: off it
/// by [SafetySettings.routeOffM] or more for [SafetySettings.routeOffMin],
/// or stopped (within [stillM]) for [SafetySettings.stoppedMin]. Each kind
/// is raised once, and again only after the car is back on the route (or
/// moving) and it happens again. Feed it fixes in time order with [add].
class RouteDeviationDetector {
  RouteDeviationDetector({required this.route, required this.settings, this.stillM = 40});

  final List<LatLng> route;
  final SafetySettings settings;

  /// How far the car may drift and still count as not moving (GPS jitter).
  final double stillM;

  DateTime? _offSince;
  bool _offRaised = false;
  LatLng? _stillAt;
  DateTime? _stillSince;
  bool _stillRaised = false;

  /// Metres off the route at the last fix.
  double lastOffM = 0;

  /// The new alert this fix raises, if any.
  RouteAlert? add(LatLng p, DateTime at) {
    if (!settings.routeCheck) return null;
    RouteAlert? out;
    // Off the route.
    if (route.length >= 2) {
      lastOffM = distanceToRouteM(p, route);
      if (lastOffM >= settings.routeOffM) {
        _offSince ??= at;
        if (!_offRaised && at.difference(_offSince!) >= Duration(minutes: settings.routeOffMin)) {
          _offRaised = true;
          out = RouteAlert(RouteAlertKind.offRoute, offM: lastOffM.round(), since: _offSince!);
        }
      } else {
        _offSince = null;
        _offRaised = false;
      }
    }
    // Stopped.
    final anchor = _stillAt;
    if (anchor == null || const Distance().as(LengthUnit.Meter, anchor, p) > stillM) {
      _stillAt = p;
      _stillSince = at;
      _stillRaised = false;
    } else if (!_stillRaised && at.difference(_stillSince!) >= Duration(minutes: settings.stoppedMin)) {
      _stillRaised = true;
      out ??= RouteAlert(RouteAlertKind.stopped, since: _stillSince!);
    }
    return out;
  }
}

/// How long the rider has to answer before the contacts and support are told.
Duration routeAnswerWindow(SafetySettings s) => Duration(seconds: s.noAnswerS);

// ---- Sharing the trip with the emergency contacts (0269) ---------------------------

/// The rider's choice on Profile > Emergency contacts (profiles.trip_share_mode).
enum TripShareMode {
  always('Every trip'),
  night('At night only (10 pm to 6 am)'),
  never('Never');

  const TripShareMode(this.label);
  final String label;

  static TripShareMode parse(Object? v) => switch (v) {
    'always' => TripShareMode.always,
    'never' => TripShareMode.never,
    _ => TripShareMode.night,
  };
}

/// Whether [local] (the clock where the trip is) is at night: 10 pm to 6 am.
/// Kept in step with `trip_share_at_night` (0269).
bool tripShareAtNight(DateTime local) => local.hour >= 22 || local.hour < 6;

/// Whether a trip starting at [local] is shared under [mode].
bool tripSharedAt(TripShareMode mode, DateTime local) => switch (mode) {
  TripShareMode.always => true,
  TripShareMode.night => tripShareAtNight(local),
  TripShareMode.never => false,
};
