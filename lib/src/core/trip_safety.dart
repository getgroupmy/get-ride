// Trip safety signals (reliability Phase D4; the server half is migration
// 0154): was the passenger there when the trip started, did the phones drift
// apart mid-trip, and did the passenger leave something behind. Pure.

/// The admin's switches, kept in the reliability-messaging row (read the
/// same way server-side by reliability_safety()). All off until turned on.
class SafetySettings {
  const SafetySettings({
    this.startCheck = false,
    this.separation = false,
    this.lostItems = false,
    this.farApartM = defaultFarApartM,
    this.separationMin = defaultSeparationMin,
  });

  static const defaultFarApartM = 300;
  static const defaultSeparationMin = 3;
  static const minFarApart = 100, maxFarApart = 5000, minSeparation = 1, maxSeparation = 30;

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

  factory SafetySettings.fromValues(Map<String, dynamic>? v) => SafetySettings(
    startCheck: _on(v?['safety_start_check']),
    separation: _on(v?['safety_separation']),
    lostItems: _on(v?['safety_lost_items']),
    farApartM: _clamp(v?['safety_far_apart_m'], defaultFarApartM, minFarApart, maxFarApart),
    separationMin: _clamp(v?['safety_separation_min'], defaultSeparationMin, minSeparation, maxSeparation),
  );

  Map<String, dynamic> toValues() => {
    'safety_start_check': startCheck,
    'safety_separation': separation,
    'safety_lost_items': lostItems,
    'safety_far_apart_m': farApartM,
    'safety_separation_min': separationMin,
  };

  SafetySettings copyWith({bool? startCheck, bool? separation, bool? lostItems, int? farApartM, int? separationMin}) =>
      SafetySettings.fromValues({
        ...toValues(),
        'safety_start_check': ?startCheck,
        'safety_separation': ?separation,
        'safety_lost_items': ?lostItems,
        'safety_far_apart_m': ?farApartM,
        'safety_separation_min': ?separationMin,
      });

  @override
  bool operator ==(Object other) =>
      other is SafetySettings &&
      other.startCheck == startCheck &&
      other.separation == separation &&
      other.lostItems == lostItems &&
      other.farApartM == farApartM &&
      other.separationMin == separationMin;

  @override
  int get hashCode => Object.hash(startCheck, separation, lostItems, farApartM, separationMin);
}

bool _on(Object? v) => switch (v) {
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
