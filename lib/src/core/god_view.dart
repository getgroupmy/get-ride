// Admin → God View (migrations 0270, 0272, 0276): who is where, in what state.
// The rows come from god_view_snapshot; everything here is pure, so the
// page only draws and the rules are tested on their own
// (test/god_view_test.dart).
library;

import 'app_version.dart';
import 'date_order.dart';

/// A partner (circle on the map) or a user (rounded square).
enum GodViewKind { partner, user }

/// What a person is doing. The server's words: free, pickup, trip,
/// not_responding, searching, ride, app_open, always_on, sos, last_known.
enum GodViewStatus {
  free('free', 'Online, free'),
  pickup('pickup', 'Going to pickup'),
  trip('trip', 'On trip'),
  /// A partner the server still has as online, silent for over 3 minutes
  /// (shown up to 24 hours): usually the app closed while "online".
  notResponding('not_responding', 'Online, not responding'),
  searching('searching', 'Searching'),
  ride('ride', 'In a ride'),
  appOpen('app_open', 'App open'),
  /// The freshest report came from the background (the app closed or not
  /// on screen) in the last 30 minutes, location set to "Allow all the time";
  /// or (0276) a phone still set so, with the background key, quiet for up
  /// to the admin's hours (God View settings, 12 by default): it reports
  /// when it moves and answers the "Still there?" pings.
  alwaysOn('always_on', 'Always on'),
  sos('sos', 'SOS'),
  /// No recent position: where they last were, up to 7 days ago (0272;
  /// was "offline").
  lastKnown('last_known', 'Last known');

  const GodViewStatus(this.db, this.label);
  final String db;
  final String label;

  /// An unknown word (or 0270's "offline") reads as last known.
  static GodViewStatus parse(Object? s) =>
      GodViewStatus.values.firstWhere((v) => v.db == s, orElse: () => GodViewStatus.lastKnown);

  /// Drawn with a pulse: someone waiting, or someone in danger.
  bool get pulses => this == searching || this == sos;

  /// Not a live position: drawn smaller and greyed, listed last.
  bool get isLastKnown => this == lastKnown;

  /// The order the list and the server's row cap keep (SOS first, the last
  /// known positions last).
  int get priority => switch (this) {
    sos => 0,
    pickup || trip => 1,
    searching || ride => 2,
    free => 3,
    notResponding || appOpen => 4,
    alwaysOn => 5,
    lastKnown => 6,
  };
}

/// The legend, in the sample's order. Last known only while those are shown.
List<GodViewStatus> godViewLegend({required bool lastKnown, bool partners = true, bool users = true}) => [
  if (partners) ...[GodViewStatus.free, GodViewStatus.pickup, GodViewStatus.trip, GodViewStatus.notResponding],
  if (users) ...[GodViewStatus.searching, GodViewStatus.ride],
  if (partners || users) ...[GodViewStatus.appOpen, GodViewStatus.alwaysOn],
  GodViewStatus.sos,
  if (lastKnown) GodViewStatus.lastKnown,
];

/// Which icon a partner's circle carries.
enum GodViewService { car, motorcycle, freight }

/// A partner's service from the ride's service or their vehicle type, by its words.
GodViewService godViewServiceOf(String? service, [String? vehicle]) {
  final s = '${service ?? ''} ${vehicle ?? ''}'.toLowerCase();
  if (RegExp(r'moto|bike|scooter|two.?wheel|\bkapcai\b').hasMatch(s)) return GodViewService.motorcycle;
  if (RegExp(r'freight|lorry|truck|\bvan\b|cargo|tonne|courier|pickup truck').hasMatch(s)) {
    return GodViewService.freight;
  }
  return GodViewService.car;
}

class GodViewPerson {
  const GodViewPerson({
    required this.kind,
    required this.id,
    required this.status,
    required this.lat,
    required this.lng,
    this.partnerRowId,
    this.name,
    this.service,
    this.vehicle,
    this.plate,
    this.updatedAt,
    this.rideId,
    this.rideCode,
    this.otherId,
    this.otherName,
    this.etaMin,
    this.nextLat,
    this.nextLng,
    this.area,
    this.sos = false,
    this.incidentId,
    this.movedAt,
  });

  factory GodViewPerson.fromJson(Map<String, dynamic> j) => GodViewPerson(
    kind: j['kind'] == 'partner' ? GodViewKind.partner : GodViewKind.user,
    id: '${j['id']}',
    partnerRowId: _str(j['partner_row_id']),
    name: _str(j['name']),
    service: _str(j['service']),
    vehicle: _str(j['vehicle']),
    plate: _str(j['plate']),
    status: GodViewStatus.parse(j['status']),
    lat: (j['lat'] as num?)?.toDouble() ?? 0,
    lng: (j['lng'] as num?)?.toDouble() ?? 0,
    updatedAt: DateTime.tryParse('${j['updated_at'] ?? ''}'),
    rideId: _str(j['ride_id']),
    rideCode: _str(j['ride_code']),
    otherId: _str(j['other_id']),
    otherName: _str(j['other_name']),
    etaMin: (j['eta_min'] as num?)?.toInt(),
    nextLat: (j['next_lat'] as num?)?.toDouble(),
    nextLng: (j['next_lng'] as num?)?.toDouble(),
    area: _str(j['area']),
    sos: j['sos'] == true,
    incidentId: _str(j['incident_id']),
    movedAt: DateTime.tryParse('${j['moved_at'] ?? ''}'),
  );

  final GodViewKind kind;
  final String id;
  final String? partnerRowId;
  final String? name;
  final String? service;
  final String? vehicle;
  final String? plate;
  final GodViewStatus status;
  final double lat;
  final double lng;
  final DateTime? updatedAt;
  final String? rideId;
  final String? rideCode;
  final String? otherId;
  final String? otherName;
  final int? etaMin;
  final double? nextLat;
  final double? nextLng;
  final String? area;
  final bool sos;
  final String? incidentId;

  /// An Always on phone's last move of more than 200 m (0276).
  final DateTime? movedAt;

  bool get isPartner => kind == GodViewKind.partner;

  String get displayName => (name ?? '').trim().isEmpty ? (isPartner ? 'Partner' : 'User') : name!.trim();

  /// "Perodua Bezza · VJK 4821", or "User".
  String get vehicleLine {
    if (!isPartner) return 'User';
    final parts = [vehicle, plate].whereType<String>().where((s) => s.trim().isNotEmpty).toList();
    return parts.isEmpty ? 'Partner' : parts.join(' · ');
  }

  GodViewService get serviceIcon => godViewServiceOf(service, vehicle);

  /// Up to two initials for the list's avatar.
  String get initials {
    final words = displayName.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    return words.take(2).map((w) => w[0].toUpperCase()).join();
  }

  /// Where the dashed line goes: the pickup, or the drop-off on a trip.
  ({double lat, double lng})? get nextPoint =>
      nextLat == null || nextLng == null ? null : (lat: nextLat!, lng: nextLng!);
}

class GodViewCounts {
  const GodViewCounts({
    this.partnersOnline = 0,
    this.partnersFree = 0,
    this.partnersOnJob = 0,
    this.partnersNotResponding = 0,
    this.partnersAlwaysOn = 0,
    this.partnersLastKnown = 0,
    this.usersSearching = 0,
    this.usersInRide = 0,
    this.usersAppOpen = 0,
    this.usersAlwaysOn = 0,
    this.usersLastKnown = 0,
    this.sos = 0,
  });

  factory GodViewCounts.fromJson(Map<String, dynamic> j) {
    int n(String k) => (j[k] as num?)?.toInt() ?? 0;
    return GodViewCounts(
      partnersOnline: n('partners_online'),
      partnersFree: n('partners_free'),
      partnersOnJob: n('partners_on_job'),
      partnersNotResponding: n('partners_not_responding'),
      partnersAlwaysOn: n('partners_always_on'),
      partnersLastKnown: n('partners_offline'),
      usersSearching: n('users_searching'),
      usersInRide: n('users_in_ride'),
      usersAppOpen: n('users_app_open'),
      usersAlwaysOn: n('users_always_on'),
      usersLastKnown: n('users_offline'),
      sos: n('sos'),
    );
  }

  final int partnersOnline, partnersFree, partnersOnJob, partnersNotResponding, partnersAlwaysOn, partnersLastKnown;
  final int usersSearching, usersInRide, usersAppOpen, usersAlwaysOn, usersLastKnown, sos;
}

/// The stats chips over the map, in the sample's order: by kind as the
/// Partners / Users chips show them; Last known only while it is on.
List<({String label, int value, bool alarm})> godViewStats(
  GodViewCounts c, {
  bool partners = true,
  bool users = true,
  bool lastKnown = false,
}) => [
  if (partners) ...[
    (label: 'Online partners', value: c.partnersOnline, alarm: false),
    (label: 'Free', value: c.partnersFree, alarm: false),
    (label: 'On a job', value: c.partnersOnJob, alarm: false),
    (label: 'Not responding', value: c.partnersNotResponding, alarm: false),
  ],
  if (users) ...[
    (label: 'Users searching', value: c.usersSearching, alarm: false),
    (label: 'Users with app open', value: c.usersAppOpen, alarm: false),
  ],
  if (partners || users)
    (
      label: 'Always on',
      value: (partners ? c.partnersAlwaysOn : 0) + (users ? c.usersAlwaysOn : 0),
      alarm: false,
    ),
  (label: 'SOS', value: c.sos, alarm: c.sos > 0),
  if (lastKnown && (partners || users))
    (
      label: 'Last known',
      value: (partners ? c.partnersLastKnown : 0) + (users ? c.usersLastKnown : 0),
      alarm: false,
    ),
];

/// Admin → God View → Settings (migration 0276), kept in
/// admin_display_settings.settings.godView; only a full admin changes them
/// (god_view_save_settings).
class GodViewSettings {
  const GodViewSettings({
    this.pings = true,
    this.pingMinutes = defaultPingMinutes,
    this.alwaysOnHours = defaultAlwaysOnHours,
    this.editable = false,
  });

  factory GodViewSettings.fromJson(Map<String, dynamic> j) {
    int n(Object? v, int fallback, int min, int max) => v is num ? v.round().clamp(min, max) : fallback;
    return GodViewSettings(
      pings: j['pings'] is bool ? j['pings'] as bool : true,
      pingMinutes: n(j['pingMinutes'], defaultPingMinutes, minPingMinutes, maxPingMinutes),
      alwaysOnHours: n(j['alwaysOnHours'], defaultAlwaysOnHours, minAlwaysOnHours, maxAlwaysOnHours),
      editable: j['editable'] == true,
    );
  }

  static const defaultPingMinutes = 30, minPingMinutes = 10, maxPingMinutes = 240;
  static const defaultAlwaysOnHours = 12, minAlwaysOnHours = 1, maxAlwaysOnHours = 48;

  /// Send the scheduled "Still there?" pings.
  final bool pings;

  /// Ping an Always on phone whose last report is this old.
  final int pingMinutes;

  /// An Always on phone stays Always on this long after its last report.
  final int alwaysOnHours;

  /// This admin may change them (a full admin with edit).
  final bool editable;

  GodViewSettings copyWith({bool? pings, int? pingMinutes, int? alwaysOnHours}) => GodViewSettings(
    pings: pings ?? this.pings,
    pingMinutes: pingMinutes ?? this.pingMinutes,
    alwaysOnHours: alwaysOnHours ?? this.alwaysOnHours,
    editable: editable,
  );
}

/// "30 min", "1 h", "1 h 30 min", "4 h".
String godViewMinutesLabel(int minutes) {
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60, m = minutes % 60;
  return m == 0 ? '$h h' : '$h h $m min';
}

class GodViewSnapshot {
  const GodViewSnapshot({
    required this.at,
    this.people = const [],
    this.counts = const GodViewCounts(),
    this.total = 0,
    this.omitted = 0,
    this.omittedLastKnown = 0,
    this.scoped = false,
    this.scopeMissing = false,
    this.query = '',
    this.settings = const GodViewSettings(),
  });

  factory GodViewSnapshot.fromJson(Map<String, dynamic> j, {String query = ''}) => GodViewSnapshot(
    at: DateTime.tryParse('${j['at'] ?? ''}') ?? DateTime.now(),
    people: [
      for (final p in (j['people'] as List?) ?? const [])
        if (p is Map) GodViewPerson.fromJson(Map<String, dynamic>.from(p)),
    ],
    counts: j['counts'] is Map ? GodViewCounts.fromJson(Map<String, dynamic>.from(j['counts'] as Map)) : const GodViewCounts(),
    total: (j['total'] as num?)?.toInt() ?? 0,
    omitted: (j['omitted'] as num?)?.toInt() ?? 0,
    omittedLastKnown: (j['omitted_last_known'] as num?)?.toInt() ?? 0,
    scoped: j['scoped'] == true,
    scopeMissing: j['scope_missing'] == true,
    query: query,
    settings: j['settings'] is Map
        ? GodViewSettings.fromJson(Map<String, dynamic>.from(j['settings'] as Map))
        : const GodViewSettings(),
  );

  final DateTime at;
  final List<GodViewPerson> people;
  final GodViewCounts counts;
  final int total;
  final int omitted;

  /// Of [omitted], the last known positions (the cap leaves those out first).
  final int omittedLastKnown;
  final bool scoped;
  final bool scopeMissing;

  /// The search the server filtered these rows by.
  final String query;

  /// Admin → God View → Settings, as the server applies them (0276).
  final GodViewSettings settings;
}

/// The Users sub-filter in the top bar.
enum GodViewUserFilter {
  all('All'),
  searching('Searching'),
  ride('In a ride'),
  appOpen('App open'),
  alwaysOn('Always on');

  const GodViewUserFilter(this.label);
  final String label;
}

class GodViewFilters {
  const GodViewFilters({
    this.partners = true,
    this.users = true,
    this.lastKnown = true,
    this.userFilter = GodViewUserFilter.all,
    this.query = '',
  });

  final bool partners;
  final bool users;

  /// The top bar's "Last known" (0272: it replaced "Show offline"): also
  /// everyone without a live position, where they last were, up to 7 days
  /// ago. On by default, so the page is never empty.
  final bool lastKnown;
  final GodViewUserFilter userFilter;
  final String query;

  GodViewFilters copyWith({
    bool? partners,
    bool? users,
    bool? lastKnown,
    GodViewUserFilter? userFilter,
    String? query,
  }) => GodViewFilters(
    partners: partners ?? this.partners,
    users: users ?? this.users,
    lastKnown: lastKnown ?? this.lastKnown,
    userFilter: userFilter ?? this.userFilter,
    query: query ?? this.query,
  );
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'\s+'), '');

/// Whether [p] matches the search box: name, plate, vehicle, ride code,
/// area. A phone number is matched by the server (the page never holds one).
bool godViewMatches(GodViewPerson p, String query) {
  final q = _norm(query);
  if (q.isEmpty) return true;
  final hay = _norm([p.name, p.plate, p.vehicle, p.rideCode, p.rideId, p.area, p.otherName].whereType<String>().join(' '));
  return hay.contains(q);
}

/// Whether a user passes the Users sub-filter. An SOS always does.
bool godViewUserFilterPasses(GodViewPerson p, GodViewUserFilter f) {
  if (p.isPartner || p.status == GodViewStatus.sos) return true;
  return switch (f) {
    GodViewUserFilter.all => true,
    GodViewUserFilter.searching => p.status == GodViewStatus.searching,
    GodViewUserFilter.ride => p.status == GodViewStatus.ride,
    GodViewUserFilter.appOpen => p.status == GodViewStatus.appOpen,
    GodViewUserFilter.alwaysOn => p.status == GodViewStatus.alwaysOn,
  };
}

/// The people the filters let through, for the list and the map.
/// [serverQuery] is the search the rows were fetched for: when it is the
/// box's, the server already matched it (phone numbers too) and the rows
/// are not searched again.
List<GodViewPerson> godViewShown(List<GodViewPerson> people, GodViewFilters f, {String serverQuery = ''}) {
  final searchHere = _norm(serverQuery) != _norm(f.query);
  return [
    for (final p in people)
      if ((p.isPartner ? f.partners : f.users) &&
          (f.lastKnown || !p.status.isLastKnown) &&
          godViewUserFilterPasses(p, f.userFilter) &&
          (!searchHere || godViewMatches(p, f.query)))
        p,
  ];
}

/// The markers: a user in a ride with a partner who is on the map is drawn
/// as the partner only.
List<GodViewPerson> godViewMarkers(List<GodViewPerson> shown) {
  final partnerRides = {
    for (final p in shown)
      if (p.isPartner && p.rideId != null) p.rideId!,
  };
  return [
    for (final p in shown)
      if (p.isPartner || p.rideId == null || p.status == GodViewStatus.searching || !partnerRides.contains(p.rideId)) p,
  ];
}

/// The People tab: SOS first, then by what they are doing (the last known
/// positions after every live one), then the newest.
List<GodViewPerson> godViewListOrder(List<GodViewPerson> shown) {
  final out = [...shown];
  out.sort((a, b) {
    final s = a.status.priority.compareTo(b.status.priority);
    if (s != 0) return s;
    final t = (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0));
    if (t != 0) return t;
    return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
  });
  return out;
}

/// "3 s ago", "4 min ago", "2 h ago", "2 h 48 min ago", "1 day ago",
/// "3 days ago".
String godViewAge(DateTime? at, DateTime now) {
  if (at == null) return '';
  final s = now.difference(at).inSeconds;
  if (s < 60) return '${s < 1 ? 1 : s} s ago';
  if (s < 3600) return '${s ~/ 60} min ago';
  if (s < 86400) {
    final h = s ~/ 3600, m = (s % 3600) ~/ 60;
    return m == 0 ? '$h h ago' : '$h h $m min ago';
  }
  final d = s ~/ 86400;
  return d == 1 ? '1 day ago' : '$d days ago';
}

/// "4:31 PM", in the phone's own time.
String godViewClock(DateTime at) {
  final d = at.toLocal();
  final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h12:${d.minute.toString().padLeft(2, '0')} ${d.hour >= 12 ? 'PM' : 'AM'}';
}

/// "4:31 PM" today, else "21/10/2026, 4:31 PM" (the date in the admin's order).
String godViewWhen(DateTime at, DateTime now, {DateOrder? order}) {
  final d = at.toLocal(), n = now.toLocal();
  final today = d.year == n.year && d.month == n.month && d.day == n.day;
  return today ? godViewClock(d) : '${formatDateForUser(d, order: order)}, ${godViewClock(d)}';
}

/// An Always on phone quiet for longer than the live window (30 minutes):
/// it has not moved, as far as the server knows.
const godViewQuietAfter = Duration(minutes: 30);

/// "Not moved since 4:31 PM" for an Always on phone that has not moved for
/// [godViewQuietAfter] (0276: when it last moved more than 200 m, else its
/// last report); null for anyone else.
String? godViewNotMovedSince(GodViewPerson p, DateTime now, {DateOrder? order}) {
  if (p.status != GodViewStatus.alwaysOn) return null;
  final since = p.movedAt ?? p.updatedAt;
  if (since == null || now.difference(since) < godViewQuietAfter) return null;
  return 'Not moved since ${godViewWhen(since, now, order: order)}';
}

// ---- "Still there?" (migration 0276) ------------------------------------------------------------

/// Whether the Details tab offers "Ping now": someone whose phone may be
/// quiet. A live partner or a user in a ride is already reporting.
bool godViewCanPing(GodViewPerson p) =>
    p.status == GodViewStatus.alwaysOn || p.status == GodViewStatus.lastKnown || p.status == GodViewStatus.notResponding;

/// What god_view_ping answered.
class GodViewPingResult {
  const GodViewPingResult({
    this.phones = 0,
    this.sent = 0,
    this.recent = 0,
    this.posted = false,
    this.sentAt,
    this.retryAt,
  });

  factory GodViewPingResult.fromJson(Map<String, dynamic> j) => GodViewPingResult(
    phones: (j['phones'] as num?)?.toInt() ?? 0,
    sent: (j['sent'] as num?)?.toInt() ?? 0,
    recent: (j['recent'] as num?)?.toInt() ?? 0,
    posted: j['posted'] == true,
    sentAt: DateTime.tryParse('${j['sent_at'] ?? ''}'),
    retryAt: DateTime.tryParse('${j['retry_at'] ?? ''}'),
  );

  /// Phones with location always and the background key.
  final int phones;
  final int sent;

  /// Pinged in the last 2 minutes, so not again.
  final int recent;

  /// The server queued the push (false: no function configured).
  final bool posted;
  final DateTime? sentAt;
  final DateTime? retryAt;
}

/// Where a "Ping now" stands on the Details tab.
enum GodViewPingStage { sending, waiting, answered, noAnswer, recent, noPhone, failed }

/// How long the page waits for the phone's answer.
const godViewPingWait = Duration(seconds: 60);

/// The line under "Ping now".
String godViewPingLine(GodViewPingStage stage, {DateTime? at, DateTime? now}) => switch (stage) {
  GodViewPingStage.sending => 'Sending the ping…',
  GodViewPingStage.waiting => 'Ping sent… waiting for the phone to answer.',
  GodViewPingStage.answered =>
    at == null ? 'The phone answered. Position updated.' : 'The phone answered at ${godViewClock(at)}. Position updated.',
  GodViewPingStage.noAnswer => 'No answer yet. The phone may be off, without signal, or the app closed by swiping it away.',
  GodViewPingStage.recent =>
    at == null ? 'Pinged in the last 2 minutes. Try again shortly.' : 'Pinged in the last 2 minutes. Try again after ${godViewClock(at)}.',
  GodViewPingStage.noPhone => 'No phone to ping: none of their phones has location set to always with the app\'s background reporting.',
  GodViewPingStage.failed => 'The ping could not be sent. Try again later.',
};

/// The stage god_view_ping's answer puts the page in.
GodViewPingStage godViewPingStageOf(GodViewPingResult r) {
  if (r.phones == 0) return GodViewPingStage.noPhone;
  if (r.sent == 0) return GodViewPingStage.recent;
  if (!r.posted) return GodViewPingStage.failed;
  return GodViewPingStage.waiting;
}

/// The line under the map's stats when the row cap left people out.
String godViewOmittedNote(GodViewSnapshot s) {
  final shown = s.total - s.omitted;
  final lastKnown = s.omittedLastKnown > 0 ? ' (${s.omittedLastKnown} last known left out)' : '';
  return 'Showing $shown of ${s.total}$lastKnown. Zoom in to see the rest.';
}

/// "Live · updated 2 s ago" above the map.
String godViewLiveLine(DateTime? fetched, DateTime now) {
  if (fetched == null) return 'Live · loading';
  final s = now.difference(fetched).inSeconds;
  return 'Live · updated ${s < 1 ? 0 : s} s ago';
}

/// A phone number before Show: the country code and the rest hidden.
const godViewPhoneHidden = '•••• ••• ••••';

/// The actions on the Details tab, by what the admin may do.
enum GodViewAction { follow, openRide, profile, message, call, sendPush, suspend, openIncident }

Set<GodViewAction> godViewActionsFor(
  GodViewPerson p, {
  required bool canReadRides,
  required bool canOpenProfile,
  required bool canPush,
  required bool canSuspend,
}) => {
  GodViewAction.follow,
  if (p.rideId != null && canReadRides) GodViewAction.openRide,
  if (canOpenProfile && (!p.isPartner || p.partnerRowId != null)) GodViewAction.profile,
  GodViewAction.message,
  GodViewAction.call,
  if (canPush) GodViewAction.sendPush,
  if (canSuspend) GodViewAction.suspend,
  if (p.status == GodViewStatus.sos && p.incidentId != null) GodViewAction.openIncident,
};

/// Why a suspend is asked for, in the order the dialog offers them.
const godViewSuspendReasons = [
  'Safety concern',
  'Fraud or fake account',
  'Abusive behaviour',
  'Documents or permit problem',
  'Other',
];

/// The map's visible box, padded so a marker just off the edge is fetched.
({double minLat, double minLng, double maxLat, double maxLng}) godViewPaddedBox(
  double south,
  double west,
  double north,
  double east, {
  double pad = 0.15,
}) {
  final dLat = (north - south).abs() * pad, dLng = (east - west).abs() * pad;
  return (
    minLat: (south - dLat).clamp(-90.0, 90.0),
    minLng: (west - dLng).clamp(-180.0, 180.0),
    maxLat: (north + dLat).clamp(-90.0, 90.0),
    maxLng: (east + dLng).clamp(-180.0, 180.0),
  );
}

String? _str(Object? v) {
  if (v == null) return null;
  final s = '$v'.trim();
  return s.isEmpty ? null : s;
}

// ---- No location (migration 0275) ---------------------------------------------------------------

/// Why God View cannot put someone on the map (god_view_unlocated): no
/// push token at all, tokens never located, or located before the 7-day
/// window.
enum GodViewNoLocation {
  noApp('no_app'),
  neverLocated('never_located'),
  stale('stale');

  const GodViewNoLocation(this.db);
  final String db;

  static GodViewNoLocation parse(Object? s) =>
      GodViewNoLocation.values.firstWhere((v) => v.db == s, orElse: () => GodViewNoLocation.neverLocated);
}

/// An account in the People list's "No location" section: not on the map.
class GodViewUnlocated {
  const GodViewUnlocated({
    required this.kind,
    required this.id,
    required this.reason,
    this.partnerRowId,
    this.name,
    this.vehicle,
    this.plate,
    this.lastSeenAt,
    this.appVersion,
    this.appPlatform,
    this.tokenPlatform,
  });

  factory GodViewUnlocated.fromJson(Map<String, dynamic> j) => GodViewUnlocated(
    kind: j['kind'] == 'partner' ? GodViewKind.partner : GodViewKind.user,
    id: '${j['id']}',
    reason: GodViewNoLocation.parse(j['reason']),
    partnerRowId: _str(j['partner_row_id']),
    name: _str(j['name']),
    vehicle: _str(j['vehicle']),
    plate: _str(j['plate']),
    lastSeenAt: DateTime.tryParse('${j['last_seen_at'] ?? ''}'),
    appVersion: _str(j['app_version']),
    appPlatform: _str(j['app_platform']),
    tokenPlatform: _str(j['token_platform']),
  );

  final GodViewKind kind;
  final String id;
  final GodViewNoLocation reason;
  final String? partnerRowId;
  final String? name;
  final String? vehicle;
  final String? plate;
  final DateTime? lastSeenAt;

  /// The account's app version and platform (profiles, migration 0176).
  final String? appVersion;
  final String? appPlatform;

  /// The platform of its newest push token.
  final String? tokenPlatform;

  bool get isPartner => kind == GodViewKind.partner;

  String get displayName => (name ?? '').trim().isEmpty ? (isPartner ? 'Partner' : 'User') : name!.trim();

  String get vehicleLine {
    if (!isPartner) return 'User';
    final parts = [vehicle, plate].whereType<String>().where((s) => s.trim().isNotEmpty).toList();
    return parts.isEmpty ? 'Partner' : parts.join(' · ');
  }

  String get initials {
    final words = displayName.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    return words.take(2).map((w) => w[0].toUpperCase()).join();
  }
}

/// The reason line under a "No location" row. For tokens never located,
/// the admin's App Version rows ([rules]) tell an old build ("Old app
/// version (1.2.0)") from a current one, which reports where it is unless
/// location is not allowed; without a version or a rule it cannot be told.
String godViewNoLocationReason(GodViewUnlocated u, List<AppVersionRule> rules, {DateOrder? order}) {
  switch (u.reason) {
    case GodViewNoLocation.noApp:
      return "Hasn't opened the new app";
    case GodViewNoLocation.stale:
      return 'Last seen ${formatDateForUser(u.lastSeenAt?.toLocal(), order: order)}';
    case GodViewNoLocation.neverLocated:
      final v = u.appVersion;
      final platform = rulePlatform(u.appPlatform ?? u.tokenPlatform ?? '');
      if (v == null || parseVersion(v) == null) return 'No location yet';
      final hasRule = rules.any((r) => rulePlatform(r.platform) == platform || rulePlatform(r.platform) == 'all');
      if (!hasRule || platform == 'web') return 'No location yet';
      final verdict = resolveUpdate(rules, platform: platform, current: v);
      return verdict.kind == UpdateKind.none ? 'Location not allowed' : 'Old app version ($v)';
  }
}

/// The "No location" rows the filters let through: partners and users as
/// the toggles say (users only under "All": none of them is searching, in
/// a ride or reporting); the search is the server's.
List<GodViewUnlocated> godViewUnlocatedShown(List<GodViewUnlocated> rows, GodViewFilters f) => [
  for (final u in rows)
    if (u.isPartner ? f.partners : f.users && f.userFilter == GodViewUserFilter.all) u,
];
