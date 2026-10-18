// The phones find each other at the kerb (reliability Phase D2; the server
// half is migration 0153). The rider's and the driver's phones each advertise
// a short token the server hands them and scan for the other's; each reports
// what it saw, and the server decides it's the right car, and, where the
// operator allows it, starts the trip without the code. Pure.

import 'dart:math' as math;

/// The admin's Bluetooth switches, kept in the reliability-messaging row
/// beside the others (read the same way server-side by reliability_ble()).
class BleSettings {
  const BleSettings({
    this.enabled = false,
    this.android = true,
    this.ios = true,
    this.autostartNoPin = false,
    this.rssiThresholdDbm = defaultRssiThresholdDbm,
    this.matchTimeoutS = defaultMatchTimeoutS,
    this.chat = false,
  });

  static const defaultRssiThresholdDbm = -70;
  static const defaultMatchTimeoutS = 20;
  static const minRssi = -100, maxRssi = -30, minTimeout = 5, maxTimeout = 120;

  /// The phones look for each other at all. Off until the admin turns it on.
  final bool enabled;

  /// It runs on Android phones / on iPhones.
  final bool android;
  final bool ios;

  /// A match at the pickup starts the trip without the code.
  final bool autostartNoPin;

  /// How strong the other phone's signal must be (closer to 0 is nearer).
  final int rssiThresholdDbm;

  /// How recent both sides' sightings must be to count.
  final int matchTimeoutS;

  /// Chat messages that can't reach the server go phone to phone (0155).
  final bool chat;

  factory BleSettings.fromValues(Map<String, dynamic>? v) => BleSettings(
    enabled: _onlyIfOn(v?['ble_enabled']),
    android: !_offOnly(v?['ble_android']),
    ios: !_offOnly(v?['ble_ios']),
    autostartNoPin: _onlyIfOn(v?['ble_autostart_no_pin']),
    rssiThresholdDbm: _clampInt(v?['ble_rssi_threshold_dbm'], defaultRssiThresholdDbm, minRssi, maxRssi),
    matchTimeoutS: _clampInt(v?['ble_match_timeout_s'], defaultMatchTimeoutS, minTimeout, maxTimeout),
    chat: _onlyIfOn(v?['ble_chat']),
  );

  /// As get_trip_ble_token hands them over (`settings`).
  factory BleSettings.fromServer(Map<String, dynamic>? v) => BleSettings.fromValues({
    'ble_enabled': v?['enabled'],
    'ble_android': v?['android'],
    'ble_ios': v?['ios'],
    'ble_autostart_no_pin': v?['autostart_no_pin'],
    'ble_rssi_threshold_dbm': v?['rssi_threshold_dbm'],
    'ble_match_timeout_s': v?['match_timeout_s'],
    'ble_chat': v?['chat'],
  });

  Map<String, dynamic> toValues() => {
    'ble_enabled': enabled,
    'ble_android': android,
    'ble_ios': ios,
    'ble_autostart_no_pin': autostartNoPin,
    'ble_rssi_threshold_dbm': rssiThresholdDbm,
    'ble_match_timeout_s': matchTimeoutS,
    'ble_chat': chat,
  };

  BleSettings copyWith({
    bool? enabled,
    bool? android,
    bool? ios,
    bool? autostartNoPin,
    int? rssiThresholdDbm,
    int? matchTimeoutS,
    bool? chat,
  }) => BleSettings.fromValues({
    ...toValues(),
    'ble_enabled': ?enabled,
    'ble_android': ?android,
    'ble_ios': ?ios,
    'ble_autostart_no_pin': ?autostartNoPin,
    'ble_rssi_threshold_dbm': ?rssiThresholdDbm,
    'ble_match_timeout_s': ?matchTimeoutS,
    'ble_chat': ?chat,
  });

  /// Whether a phone of this kind takes part. Anything that is neither
  /// (the web, a desktop) never does.
  bool runsOn({required bool isAndroid, required bool isIos}) => enabled && ((isAndroid && android) || (isIos && ios));

  @override
  bool operator ==(Object other) =>
      other is BleSettings &&
      other.enabled == enabled &&
      other.android == android &&
      other.ios == ios &&
      other.autostartNoPin == autostartNoPin &&
      other.rssiThresholdDbm == rssiThresholdDbm &&
      other.matchTimeoutS == matchTimeoutS &&
      other.chat == chat;

  @override
  int get hashCode => Object.hash(enabled, android, ios, autostartNoPin, rssiThresholdDbm, matchTimeoutS, chat);
}

bool _onlyIfOn(Object? v) => switch (v) {
  true || 'true' || 't' || 1 || '1' || 'on' => true,
  _ => false,
};

bool _offOnly(Object? v) => switch (v) {
  false || 'false' || 'f' || 0 || '0' || 'off' => true,
  _ => false,
};

int _clampInt(Object? v, int fallback, int lo, int hi) {
  final n = v is num ? v.toInt() : int.tryParse('${v ?? ''}');
  if (n == null) return fallback;
  return n < lo ? lo : (n > hi ? hi : n);
}

// ---- Tokens on the air ------------------------------------------------------------

/// A token travels as the last 8 bytes of a 128-bit service UUID: iPhones
/// can't advertise manufacturer data, but every phone advertises and sees
/// service UUIDs. The first 8 bytes are "get.ride" in ASCII.
const _uuidPrefix = '6765742e-7269-6465';

/// The service UUID that carries [token] (16 hex digits); null when it isn't one.
String? tokenServiceUuid(String? token) {
  final t = (token ?? '').toLowerCase();
  if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(t)) return null;
  return '$_uuidPrefix-${t.substring(0, 4)}-${t.substring(4)}';
}

/// The token a service UUID carries; null when it isn't one of ours.
String? tokenFromServiceUuid(String uuid) {
  final u = uuid.toLowerCase();
  final m = RegExp(r'^6765742e-7269-6465-([0-9a-f]{4})-([0-9a-f]{12})$').firstMatch(u);
  return m == null ? null : '${m[1]}${m[2]}';
}

// ---- What the server hands over -----------------------------------------------------

/// get_trip_ble_token's answer.
class BleTicket {
  const BleTicket({
    required this.enabled,
    this.status,
    this.side,
    this.token,
    this.peerToken,
    this.expiresAt,
    this.chatKey,
    this.settings = const BleSettings(),
    this.ahead = const [],
    this.behind,
  });

  final bool enabled;
  final String? status;

  /// 'rider' or 'driver'.
  final String? side;
  final String? token;
  final String? peerToken;
  final DateTime? expiresAt;

  /// The key Bluetooth chat frames are signed with (0155); null while the
  /// admin has chat off.
  final String? chatKey;
  final BleSettings settings;

  /// The tokens for the windows after this one (0157), so a phone that loses
  /// signal keeps rotating in step with the other phone. Oldest first.
  final List<BleSlot> ahead;

  /// The window before this one, kept when a phone rotates on its own, so
  /// it still knows the other phone if that one's clock is a moment behind.
  final BleSlot? behind;

  /// There is something to advertise and something to look for.
  bool get usable =>
      enabled && tokenServiceUuid(token) != null && tokenServiceUuid(peerToken) != null && expiresAt != null;

  /// This ticket's own window, as a slot.
  BleSlot? get _current => usable ? BleSlot(token: token!, peerToken: peerToken!, expiresAt: expiresAt!) : null;

  /// Every window this ticket knows, oldest first.
  List<BleSlot> get _slots => [?behind, ?_current, ...ahead];

  /// The ticket for the window [now] falls in, from the tokens handed out
  /// ahead; null once [now] is past every window this ticket knows.
  BleTicket? at(DateTime now) {
    final slots = _slots;
    final i = slots.indexWhere((s) => now.isBefore(s.expiresAt));
    if (i < 0) return null;
    final s = slots[i];
    return BleTicket(
      enabled: enabled,
      status: status,
      side: side,
      token: s.token,
      peerToken: s.peerToken,
      expiresAt: s.expiresAt,
      chatKey: chatKey,
      settings: settings,
      ahead: slots.sublist(i + 1),
      behind: i > 0 ? slots[i - 1] : behind,
    );
  }

  /// What the other phone may be advertising around [now]: this window's
  /// token and the ones either side, since two clocks never quite agree on
  /// where a window ends.
  Set<String> peerTokensNear(DateTime now) {
    final slots = _slots;
    var i = slots.indexWhere((s) => now.isBefore(s.expiresAt));
    if (i < 0) i = slots.length - 1;
    return {
      for (var j = i - 1; j <= i + 1; j++)
        if (j >= 0 && j < slots.length) slots[j].peerToken.toLowerCase(),
    };
  }

  factory BleTicket.fromJson(Object? json) {
    if (json is! Map) return const BleTicket(enabled: false);
    final m = Map<String, dynamic>.from(json);
    final settings = m['settings'];
    final ahead = m['ahead'];
    return BleTicket(
      enabled: m['enabled'] == true,
      status: m['status'] as String?,
      side: m['side'] as String?,
      token: m['token'] as String?,
      peerToken: m['peer_token'] as String?,
      expiresAt: DateTime.tryParse('${m['expires_at'] ?? ''}')?.toUtc(),
      chatKey: m['chat_key'] as String?,
      settings: BleSettings.fromServer(settings is Map ? Map<String, dynamic>.from(settings) : null),
      ahead: [
        if (ahead is List)
          for (final a in ahead) ?BleSlot.fromJson(a),
      ],
    );
  }
}

/// One 5-minute window's tokens: what this phone advertises, and what it
/// looks for.
class BleSlot {
  const BleSlot({required this.token, required this.peerToken, required this.expiresAt});

  final String token;
  final String peerToken;
  final DateTime expiresAt;

  static BleSlot? fromJson(Object? json) {
    if (json is! Map) return null;
    final token = json['token'];
    final peer = json['peer_token'];
    final until = DateTime.tryParse('${json['expires_at'] ?? ''}')?.toUtc();
    if (token is! String || peer is! String || until == null) return null;
    if (tokenServiceUuid(token) == null || tokenServiceUuid(peer) == null) return null;
    return BleSlot(token: token, peerToken: peer, expiresAt: until);
  }
}

// ---- Watching the other phone ---------------------------------------------------------

/// How long the other phone must be seen, unbroken, before a sighting is
/// worth reporting (the server asks for the same).
const bleSeenFor = Duration(seconds: 5);

/// A gap longer than this between two sightings starts the run again.
const bleSightingGap = Duration(seconds: 3);

/// The other phone, as this one has been seeing it: an unbroken run of
/// sightings at or above the threshold, and the average signal over it.
class PeerSighting {
  const PeerSighting({this.since, this.last, this.rssiSum = 0, this.count = 0});

  final DateTime? since;
  final DateTime? last;
  final int rssiSum;
  final int count;

  Duration get seenFor => since == null || last == null ? Duration.zero : last!.difference(since!);
  int? get averageRssi => count == 0 ? null : (rssiSum / count).round();

  /// Seen strongly enough for long enough to report.
  bool get qualifies => seenFor >= bleSeenFor;

  /// This with one more sighting. A weak one, or one after a gap, starts over.
  PeerSighting add(int rssi, DateTime at, {required int thresholdDbm}) {
    if (rssi < thresholdDbm) return const PeerSighting();
    if (last == null || at.difference(last!) > bleSightingGap || at.isBefore(last!)) {
      return PeerSighting(since: at, last: at, rssiSum: rssi, count: 1);
    }
    return PeerSighting(since: since, last: at, rssiSum: rssiSum + rssi, count: count + 1);
  }

  /// Nothing seen for [bleSightingGap]: the run is over.
  PeerSighting expire(DateTime now) =>
      last != null && now.difference(last!) > bleSightingGap ? const PeerSighting() : this;
}

// ---- What the server answered ---------------------------------------------------------

enum BleProofResult { noMatch, waiting, matched, started, off, wrongStatus, rateLimited }

/// ble_handshake_proof's answer.
BleProofResult bleProofResult(Object? reply) {
  final s = '${reply ?? ''}'.trim();
  return switch (s) {
    'no_match' => BleProofResult.noMatch,
    'waiting' => BleProofResult.waiting,
    'matched' => BleProofResult.matched,
    'on_trip' => BleProofResult.started,
    'off' => BleProofResult.off,
    _ when s.startsWith('rate_limited:') => BleProofResult.rateLimited,
    _ when s.startsWith('wrong_status:') => BleProofResult.wrongStatus,
    _ => BleProofResult.waiting,
  };
}

// ---- What each side sees --------------------------------------------------------------

enum BleHandshakePhase {
  /// Not running: switched off, not this platform, or the ride moved on.
  idle,

  /// Bluetooth is off or not allowed: the code is the way.
  unavailable,

  /// Advertising and looking for the other phone.
  searching,

  /// The other phone is in sight; checking with the server.
  nearby,

  /// The other phone has been seen close by for long enough, but this phone
  /// has no signal to check it with the server: worth telling the person,
  /// never counted as a match (the server only takes reports from both
  /// phones, and this one can't send its own).
  detectedOffline,

  /// The driver's phone: about to report, with a moment to cancel.
  countdown,

  /// The server agrees: it's the right car.
  matched,

  /// The server started the trip.
  started,

  /// The driver cancelled: the code it is.
  cancelled,
}

/// One line for the badge; null when nothing is shown.
String? bleHandshakeLabel(BleHandshakePhase phase, {required bool driver}) => switch (phase) {
  BleHandshakePhase.idle => null,
  BleHandshakePhase.unavailable => 'Bluetooth is off — use the trip code',
  BleHandshakePhase.searching => driver ? 'Looking for the passenger\'s phone…' : 'Looking for your driver\'s phone…',
  BleHandshakePhase.nearby => driver ? 'Passenger\'s phone nearby…' : 'Your driver\'s phone is nearby…',
  BleHandshakePhase.detectedOffline =>
    driver ? 'The passenger is detected around you' : 'The provider is detected around you',
  BleHandshakePhase.countdown => 'Passenger found — starting the trip',
  BleHandshakePhase.matched => driver ? '✓ Right passenger' : '✓ Correct car',
  BleHandshakePhase.started => 'Trip started by Bluetooth',
  BleHandshakePhase.cancelled => 'Use the trip code',
};

/// Whether the driver's phone counts down before reporting: only where the
/// report may start the trip (at the pickup, with autostart on).
bool bleNeedsCountdown({required String? side, required String? status, required BleSettings settings}) =>
    side == 'driver' && status == 'arrived' && settings.autostartNoPin;

/// How long the driver has to cancel.
const bleCountdown = Duration(seconds: 3);

// ---- When to report ----------------------------------------------------------------

/// The least time between two reports, whatever changed.
const bleReportMinGap = Duration(seconds: 4);

/// A sighting that is still close is reported again this often, so the
/// server keeps knowing this phone sees the other one.
const bleReportKeepAlive = Duration(seconds: 25);

/// After 'matched', the keep-alive slows to this: enough for the start
/// check to know the rider was still close in the last 10 minutes
/// (start_flag 'no_proximity', 0154) if the code is used later.
const bleReportAfterMatch = Duration(minutes: 4);

/// Whether this phone reports to the server now. Each report is a write on
/// the server, so it goes only when it says something new:
///
///   * the first time the other phone is seen close for long enough
///     ([close] with nothing reported yet, [reported] null);
///   * when it crosses the threshold either way ([close] differs from what
///     the last report said);
///   * a keep-alive every [bleReportKeepAlive] while it stays close;
///
/// never closer together than [bleReportMinGap]. Once the server has said
/// 'matched' ([answer]) only a keep-alive every [bleReportAfterMatch] while
/// still close; nothing once it started the trip, or once the ride has left
/// the kerb ([status] other than accepted / arrived). Pure.
bool bleShouldReport({
  required bool close,
  required bool? reported,
  required DateTime? lastReport,
  required DateTime now,
  required String? status,
  BleProofResult? answer,
}) {
  if (status != 'accepted' && status != 'arrived') return false;
  if (answer == BleProofResult.started) return false;
  final since = lastReport == null ? null : now.difference(lastReport);
  if (since != null && since < bleReportMinGap) return false;
  if (answer == BleProofResult.matched) return close && (since == null || since >= bleReportAfterMatch);
  if (reported == null) return close;
  if (close != reported) return true;
  return close && (since == null || since >= bleReportKeepAlive);
}

// ---- Admin: how trips started ------------------------------------------------------

/// ble_start_stats: trips started in the last days, by how.
class BleStartStats {
  const BleStartStats({this.ble = 0, this.pin = 0, this.none = 0, this.unknown = 0});

  final int ble, pin, none, unknown;

  int get total => ble + pin + none + unknown;

  factory BleStartStats.fromRow(Object? row) {
    final m = row is List && row.isNotEmpty ? row.first : row;
    if (m is! Map) return const BleStartStats();
    int n(String k) => (m[k] as num?)?.toInt() ?? 0;
    return BleStartStats(ble: n('by_ble'), pin: n('by_pin'), none: n('by_none'), unknown: n('by_unknown'));
  }

  /// One line for the admin.
  String describe(int days) {
    if (total == 0) return 'No trips started in the last $days days.';
    final pct = (ble * 100 / total).round();
    return [
      'Last $days days: $ble by Bluetooth ($pct%)',
      '$pin by code',
      if (none > 0) '$none without a code',
      if (unknown > 0) '$unknown from older apps',
    ].join(' · ');
  }
}

// ---- How far away the other phone is -------------------------------------------------

/// The signal a phone's advert arrives with at 1 m, and how fast it fades
/// (log-distance path loss; 2.5 is a street with people and cars about).
const bleTxPowerAt1m = -59;
const blePathLossExponent = 2.5;

/// Roughly how far away a phone heard at [rssi] dBm is, in metres. Phones,
/// pockets and bodies make this rough: it's a hint, never a measurement.
double bleDistanceM(int rssi, {int txPower = bleTxPowerAt1m, double n = blePathLossExponent}) =>
    math.pow(10, (txPower - rssi) / (10 * n)).toDouble();

/// The smoothed signal after one more advert: quick to start, slow to swing.
int bleSmoothRssi(int? previous, int rssi) => previous == null ? rssi : (previous * 0.7 + rssi * 0.3).round();

/// The distance as the badge shows it: "right next to you" under 2 m, the
/// nearest metre under 10, the nearest 5 m after, "30+ m" beyond that.
String bleDistanceLabel(double m) {
  if (m < 2) return 'right next to you';
  if (m < 10) return '~${m.round()} m';
  if (m < 30) return '~${(m / 5).round() * 5} m';
  return '30+ m away';
}
