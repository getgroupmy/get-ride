// Admin → God View (migration 0270): who is where, in what state. The rows
// come from god_view_snapshot; everything here is pure, so the page only
// draws and the rules are tested on their own (test/god_view_test.dart).
library;

/// A partner (circle on the map) or a user (rounded square).
enum GodViewKind { partner, user }

/// What a person is doing. The server's words: free, pickup, trip,
/// searching, ride, app_open, sos, offline.
enum GodViewStatus {
  free('free', 'Online, free'),
  pickup('pickup', 'Going to pickup'),
  trip('trip', 'On trip'),
  searching('searching', 'Searching'),
  ride('ride', 'In a ride'),
  appOpen('app_open', 'App open'),
  sos('sos', 'SOS'),
  offline('offline', 'Offline');

  const GodViewStatus(this.db, this.label);
  final String db;
  final String label;

  static GodViewStatus parse(Object? s) =>
      GodViewStatus.values.firstWhere((v) => v.db == s, orElse: () => GodViewStatus.offline);

  /// Drawn with a pulse: someone waiting, or someone in danger.
  bool get pulses => this == searching || this == sos;

  /// The order the list and the server's row cap keep (SOS first).
  int get priority => switch (this) {
    sos => 0,
    pickup || trip => 1,
    searching || ride => 2,
    free => 3,
    appOpen => 4,
    offline => 5,
  };
}

/// The legend, in the sample's order. Offline only while offline people are shown.
List<GodViewStatus> godViewLegend({required bool showOffline, bool partners = true, bool users = true}) => [
  if (partners) ...[GodViewStatus.free, GodViewStatus.pickup, GodViewStatus.trip],
  if (users) ...[GodViewStatus.searching, GodViewStatus.ride, GodViewStatus.appOpen],
  GodViewStatus.sos,
  if (showOffline) GodViewStatus.offline,
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
    this.usersSearching = 0,
    this.usersInRide = 0,
    this.usersAppOpen = 0,
    this.sos = 0,
  });

  factory GodViewCounts.fromJson(Map<String, dynamic> j) {
    int n(String k) => (j[k] as num?)?.toInt() ?? 0;
    return GodViewCounts(
      partnersOnline: n('partners_online'),
      partnersFree: n('partners_free'),
      partnersOnJob: n('partners_on_job'),
      usersSearching: n('users_searching'),
      usersInRide: n('users_in_ride'),
      usersAppOpen: n('users_app_open'),
      sos: n('sos'),
    );
  }

  final int partnersOnline, partnersFree, partnersOnJob, usersSearching, usersInRide, usersAppOpen, sos;
}

/// The stats chips over the map, in the sample's order.
List<({String label, int value, bool alarm})> godViewStats(GodViewCounts c, {bool partners = true, bool users = true}) => [
  if (partners) ...[
    (label: 'Online partners', value: c.partnersOnline, alarm: false),
    (label: 'Free', value: c.partnersFree, alarm: false),
    (label: 'On a job', value: c.partnersOnJob, alarm: false),
  ],
  if (users) ...[
    (label: 'Users searching', value: c.usersSearching, alarm: false),
    (label: 'Users with app open', value: c.usersAppOpen, alarm: false),
  ],
  (label: 'SOS', value: c.sos, alarm: c.sos > 0),
];

class GodViewSnapshot {
  const GodViewSnapshot({
    required this.at,
    this.people = const [],
    this.counts = const GodViewCounts(),
    this.total = 0,
    this.omitted = 0,
    this.scoped = false,
    this.scopeMissing = false,
    this.query = '',
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
    scoped: j['scoped'] == true,
    scopeMissing: j['scope_missing'] == true,
    query: query,
  );

  final DateTime at;
  final List<GodViewPerson> people;
  final GodViewCounts counts;
  final int total;
  final int omitted;
  final bool scoped;
  final bool scopeMissing;

  /// The search the server filtered these rows by.
  final String query;
}

/// The Users sub-filter in the top bar.
enum GodViewUserFilter {
  all('All'),
  searching('Searching'),
  ride('In a ride'),
  appOpen('App open');

  const GodViewUserFilter(this.label);
  final String label;
}

class GodViewFilters {
  const GodViewFilters({
    this.partners = true,
    this.users = true,
    this.showOffline = false,
    this.userFilter = GodViewUserFilter.all,
    this.query = '',
  });

  final bool partners;
  final bool users;
  final bool showOffline;
  final GodViewUserFilter userFilter;
  final String query;

  GodViewFilters copyWith({
    bool? partners,
    bool? users,
    bool? showOffline,
    GodViewUserFilter? userFilter,
    String? query,
  }) => GodViewFilters(
    partners: partners ?? this.partners,
    users: users ?? this.users,
    showOffline: showOffline ?? this.showOffline,
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
          (f.showOffline || p.status != GodViewStatus.offline) &&
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

/// The People tab: SOS first, then by what they are doing, then the newest.
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

/// "3 s ago", "4 min ago", "2 h ago".
String godViewAge(DateTime? at, DateTime now) {
  if (at == null) return '';
  final s = now.difference(at).inSeconds;
  if (s < 60) return '${s < 1 ? 1 : s} s ago';
  if (s < 3600) return '${(s / 60).round()} min ago';
  return '${(s / 3600).round()} h ago';
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
