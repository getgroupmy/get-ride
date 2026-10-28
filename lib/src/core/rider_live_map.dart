// Rider live map (migration 0322): what a rider may see on the home map
// besides their own trip. Every part is decided on the server
// (rider_live_map_*); this file reads its answers, holds the pure maths the
// map draws with (the hexagon grid, the colour scale) and the words shown.
//
// Privacy (owner's rules): people only through Family's disclosed options,
// company trips only while they run and only to the roles the admin allows,
// strangers never identified ([LiveCar] is a dot and a kind, nothing more),
// busy areas without counts.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

/// Admin › Settings › Rider live map; grantable to sub-admins.
const riderLiveMapPage = 'admin-settings-rider-live-map';

/// The overlays a rider turns on from the overlays button (Cars near me is
/// a setting, not an overlay).
enum LiveOverlay {
  busy('busy', 'Busy areas', 'Where bookings are high now'),
  people('people', 'My people', 'Family members on a trip'),
  team('team', 'Team', 'Staff on company trips');

  const LiveOverlay(this.key, this.title, this.hint);
  final String key;
  final String title;
  final String hint;

  static LiveOverlay? of(String? key) => values.where((o) => o.key == key).firstOrNull;
}

/// The overlays kept as "busy,people" in the rider's preferences.
String encodeOverlays(Set<LiveOverlay> on) => [for (final o in LiveOverlay.values) if (on.contains(o)) o.key].join(',');

Set<LiveOverlay> decodeOverlays(String? raw) =>
    {for (final k in (raw ?? '').split(',')) ?LiveOverlay.of(k.trim())};

int? _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
double? _num(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
String? _str(Object? v) {
  final s = v is String ? v.trim() : null;
  return s == null || s.isEmpty ? null : s;
}

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
List<String> _list(Object? v) => v is List ? [for (final e in v) '$e'] : const [];
Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : const {};

/// What rider_live_map_config answers for this rider here.
class LiveMapConfig {
  const LiveMapConfig({
    this.carsOn = false,
    this.carsMayHide = true,
    this.carsEvery = 10,
    this.busyOn = false,
    this.busyEvery = 60,
    this.peopleOn = false,
    this.peopleEvery = 10,
    this.host = false,
    this.teamOn = false,
    this.teamEvery = 10,
  });

  factory LiveMapConfig.fromJson(Object? raw) {
    final j = _map(raw);
    final cars = _map(j['cars']), busy = _map(j['busy']), people = _map(j['people']), team = _map(j['team']);
    return LiveMapConfig(
      carsOn: cars['on'] == true,
      carsMayHide: cars['mayHide'] != false,
      carsEvery: _int(cars['every']) ?? 10,
      busyOn: busy['on'] == true,
      busyEvery: _int(busy['every']) ?? 60,
      peopleOn: people['on'] == true,
      peopleEvery: _int(people['every']) ?? 10,
      host: people['host'] == true,
      teamOn: team['on'] == true,
      teamEvery: _int(team['every']) ?? 10,
    );
  }

  static const off = LiveMapConfig();

  final bool carsOn, carsMayHide, busyOn, peopleOn, host, teamOn;
  final int carsEvery, busyEvery, peopleEvery, teamEvery;

  /// The overlays this rider may turn on here.
  Set<LiveOverlay> get overlays => {
    if (busyOn) LiveOverlay.busy,
    if (peopleOn) LiveOverlay.people,
    if (teamOn) LiveOverlay.team,
  };

  /// The overlays button shows only when there is one to use.
  bool get hasOverlays => overlays.isNotEmpty;

  /// Whether the cars show: on in the region, and not hidden by the rider
  /// (where the admin lets riders hide them).
  bool showCars({required bool riderHides}) => carsOn && !(carsMayHide && riderHides);

  /// Seconds between updates of [o].
  int everyFor(LiveOverlay o) => switch (o) {
    LiveOverlay.busy => busyEvery,
    LiveOverlay.people => peopleEvery,
    LiveOverlay.team => teamEvery,
  };
}

/// The overlays a rider has on that they may still use: [picked] less what
/// the rules no longer allow.
Set<LiveOverlay> activeOverlays(Set<LiveOverlay> picked, LiveMapConfig config) =>
    picked.intersection(config.overlays);

// ---- Cars near me ----------------------------------------------------------------------------------

/// A free car near the rider: where it is shown (already moved off its real
/// spot by the server) and its kind. Nothing that tells who it is.
class LiveCar {
  const LiveCar({required this.lat, required this.lng, this.kind = 'car', this.heading = 0});

  /// Reads only the position, kind and heading: anything else the answer
  /// might carry is dropped, so no name, plate, photo or rating can reach
  /// the map.
  static LiveCar? fromJson(Object? raw) {
    final j = _map(raw);
    final lat = _num(j['lat']), lng = _num(j['lng']);
    if (lat == null || lng == null) return null;
    final kind = _str(j['kind']);
    return LiveCar(
      lat: lat,
      lng: lng,
      kind: const {'car', 'bike', 'van'}.contains(kind) ? kind! : 'car',
      heading: _num(j['heading']) ?? 0,
    );
  }

  final double lat, lng, heading;
  final String kind;

  /// The demo car marker's colour slot: car, bike, van.
  int get colourIndex => switch (kind) { 'bike' => 1, 'van' => 3, _ => 0 };
}

class LiveCars {
  const LiveCars({this.on = false, this.cars = const [], this.count, this.pickupMin});

  factory LiveCars.fromJson(Object? raw) {
    final j = _map(raw);
    return LiveCars(
      on: j['on'] == true,
      cars: [for (final c in (j['cars'] is List ? j['cars'] as List : const [])) ?LiveCar.fromJson(c)],
      count: _int(j['count']),
      pickupMin: _int(j['pickupMin']),
    );
  }

  static const none = LiveCars();
  final bool on;
  final List<LiveCar> cars;
  final int? count, pickupMin;
}

// ---- Busy areas: the hexagon grid ------------------------------------------------------------------

const _earth = 6378137.0;

/// Web Mercator metres of a point (x east, y north).
({double x, double y}) mercator(double lat, double lng) {
  final la = lat.clamp(-85.0, 85.0) * math.pi / 180;
  return (x: lng * math.pi / 180 * _earth, y: _earth * math.log(math.tan(math.pi / 4 + la / 2)));
}

LatLng fromMercator(double x, double y) =>
    LatLng((2 * math.atan(math.exp(y / _earth)) - math.pi / 2) * 180 / math.pi, x / _earth * 180 / math.pi);

/// Centre-to-corner of a pointy-top hexagon [hexM] across (flat side to
/// flat side), on the Mercator plane at latitude [latRef] (the server's grid).
double hexSize(double hexM, double latRef) => hexM / math.cos(latRef * math.pi / 180) / math.sqrt(3);

/// The cell (q, r) holding a point: the server's rider_live_map_hex_of.
({int q, int r}) hexOf(double lat, double lng, double hexM, double latRef) {
  final s = hexSize(hexM, latRef);
  final p = mercator(lat, lng);
  final fq = (math.sqrt(3) / 3 * p.x - p.y / 3) / s;
  final fr = (2 / 3 * p.y) / s;
  final fs = -fq - fr;
  var rq = fq.roundToDouble(), rr = fr.roundToDouble();
  final rs = fs.roundToDouble();
  final dq = (rq - fq).abs(), dr = (rr - fr).abs(), ds = (rs - fs).abs();
  if (dq > dr && dq > ds) {
    rq = -rr - rs;
  } else if (dr > ds) {
    rr = -rq - rs;
  }
  return (q: rq.toInt(), r: rr.toInt());
}

/// The centre of cell (q, r): the server's rider_live_map_hex_centre.
LatLng hexCentre(int q, int r, double hexM, double latRef) {
  final s = hexSize(hexM, latRef);
  return fromMercator(s * math.sqrt(3) * (q + r / 2), s * 1.5 * r);
}

/// The six corners of cell (q, r), pointy top, so neighbours share edges.
List<LatLng> hexCorners(int q, int r, double hexM, double latRef) {
  final s = hexSize(hexM, latRef);
  final cx = s * math.sqrt(3) * (q + r / 2), cy = s * 1.5 * r;
  return [
    for (var i = 0; i < 6; i++)
      fromMercator(cx + s * math.cos((60 * i - 30) * math.pi / 180), cy + s * math.sin((60 * i - 30) * math.pi / 180)),
  ];
}

/// Whether [p] is inside the polygon [ring] (even-odd).
bool insideRing(LatLng p, List<LatLng> ring) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final a = ring[i], b = ring[j];
    if ((a.latitude > p.latitude) != (b.latitude > p.latitude) &&
        p.longitude < (b.longitude - a.longitude) * (p.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude) {
      inside = !inside;
    }
  }
  return inside;
}

/// A cell's level 0-4 from its bookings and the admin's minimum (the
/// server's rider_live_map_level); null below the minimum.
int? busyLevel(int count, int minimum) {
  final m = math.max(minimum, 1);
  if (count < m) return null;
  if (count < 1.5 * m) return 0;
  if (count < 2 * m) return 1;
  if (count < 3 * m) return 2;
  if (count < 5 * m) return 3;
  return 4;
}

/// The words for a level.
String busyLabel(int level) => switch (level) {
  <= 0 => 'A little busy',
  1 => 'Busy',
  2 => 'Quite busy',
  3 => 'Very busy',
  _ => 'Extremely busy',
};

/// The approved scale: pale yellow, orange, red, deep red.
const defaultBusyColours = [Color(0xFFFFEDA0), Color(0xFFFEB24C), Color(0xFFF03B20), Color(0xFF99000D)];

/// A "#RRGGBB" colour, or null.
Color? hexColour(String? s) {
  final h = (s ?? '').trim().replaceFirst('#', '');
  if (!RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(h)) return null;
  return Color(0xFF000000 | int.parse(h, radix: 16));
}

String colourHex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// The scale at [v] (0 low, 1 very high), between the colours.
Color rampAt(List<Color> ramp, double v) {
  final colours = ramp.length < 2 ? defaultBusyColours : ramp;
  final x = v.clamp(0.0, 1.0) * (colours.length - 1);
  final i = x.floor().clamp(0, colours.length - 2);
  return Color.lerp(colours[i], colours[i + 1], x - i)!;
}

/// A level's fill colour on the scale.
Color levelColour(List<Color> ramp, int level) => rampAt(ramp, level.clamp(0, 4) / 4);

/// A quieter place near a busy cell.
class BusyTip {
  const BusyTip({required this.metres, required this.direction, this.fare});
  final int metres;
  final String direction;
  final double? fare;

  /// "Quieter 600 m north: about 1.1x".
  String get line =>
      'Quieter ${distanceWords(metres)} $direction${fare == null ? '' : ': about ${fareFactor(fare!)}'}';
}

String distanceWords(int metres) =>
    metres >= 1000 ? '${(metres / 1000).toStringAsFixed(metres % 1000 == 0 ? 0 : 1)} km' : '$metres m';

/// "1.4x".
String fareFactor(double f) => '${f.toStringAsFixed(1)}x';

class BusyCell {
  const BusyCell({
    required this.q,
    required this.r,
    required this.centre,
    required this.level,
    this.area,
    this.fare,
    this.wait,
    this.next,
    this.tip,
  });

  static BusyCell? fromJson(Object? raw) {
    final j = _map(raw);
    final q = _int(j['q']), r = _int(j['r']), lat = _num(j['lat']), lng = _num(j['lng']), level = _int(j['level']);
    if (q == null || r == null || lat == null || lng == null || level == null) return null;
    final tip = _map(j['tip']);
    return BusyCell(
      q: q,
      r: r,
      centre: LatLng(lat, lng),
      level: level.clamp(0, 4),
      area: _str(j['area']),
      fare: _num(j['fare']),
      wait: _int(j['wait']),
      next: _str(j['next']),
      tip: _int(tip['m']) == null || _str(tip['dir']) == null
          ? null
          : BusyTip(metres: _int(tip['m'])!, direction: _str(tip['dir'])!, fare: _num(tip['fare'])),
    );
  }

  final int q, r, level;
  final LatLng centre;
  final String? area, next;
  final double? fare;
  final int? wait;
  final BusyTip? tip;

  /// The sheet's title: "Mid Valley area", else "This area".
  String get title => area == null ? 'This area' : '$area area';

  /// "about 1.4x usual", "usual fares".
  String? get fareLine => fare == null ? null : (fare! <= 1.05 ? 'Usual fares' : 'about ${fareFactor(fare!)} usual');

  String? get waitLine => wait == null ? null : 'about $wait min';

  String? get nextLine => switch (next) {
    'up' => 'Getting busier',
    'down' => 'Getting quieter',
    'flat' => 'About the same',
    _ => null,
  };
}

class BusyAreas {
  const BusyAreas({
    this.on = false,
    this.cells = const [],
    this.hexM = 350,
    this.latRef = 3,
    this.colours = defaultBusyColours,
    this.opacity = 55,
    this.at,
  });

  factory BusyAreas.fromJson(Object? raw) {
    final j = _map(raw);
    final colours = [for (final c in _list(j['colours'])) ?hexColour(c)];
    return BusyAreas(
      on: j['on'] == true,
      cells: [for (final c in (j['cells'] is List ? j['cells'] as List : const [])) ?BusyCell.fromJson(c)],
      hexM: _num(j['hexM']) ?? 350,
      latRef: _num(j['latRef']) ?? 3,
      colours: colours.length == 4 ? colours : defaultBusyColours,
      opacity: _int(j['opacity']) ?? 55,
      at: _date(j['at']),
    );
  }

  static const none = BusyAreas();
  final bool on;
  final List<BusyCell> cells;
  final double hexM, latRef;
  final List<Color> colours;
  final int opacity;
  final DateTime? at;

  List<LatLng> cornersOf(BusyCell c) => hexCorners(c.q, c.r, hexM, latRef);

  /// The shown cell under [p], or null.
  BusyCell? cellAt(LatLng p) {
    final h = hexOf(p.latitude, p.longitude, hexM, latRef);
    return cells.where((c) => c.q == h.q && c.r == h.r).firstOrNull;
  }

  /// A cell's fill: its level's colour, see-through by the admin's opacity.
  Color fillOf(BusyCell c, {required bool dark}) =>
      levelColour(colours, c.level).withValues(alpha: (opacity / 100 + (dark ? 0.07 : 0)).clamp(0.1, 0.95));
}

/// "updated 1 min ago", "updated just now".
String updatedAgo(DateTime? at, DateTime now) {
  if (at == null) return 'updated just now';
  final s = now.difference(at).inSeconds;
  if (s < 15) return 'updated just now';
  if (s < 60) return 'updated $s s ago';
  final m = s ~/ 60;
  return 'updated $m min ago';
}

// ---- My people and Team --------------------------------------------------------------------------

/// A family member on the map (rider_live_map_people), or a company trip
/// (rider_live_map_team): only what the server allowed for this viewer.
class LivePerson {
  const LivePerson({
    required this.id,
    required this.name,
    this.kind = 'member',
    this.status,
    this.from,
    this.to,
    this.vehicle = 'car',
    this.area,
    this.point,
    this.at,
    this.eta,
    this.etaToPickup = false,
    this.progress,
    this.dropoffAt,
    this.driver,
    this.car,
    this.trail = const [],
    this.company,
    this.purpose,
    this.cost,
    this.currency = 'MYR',
  });

  static LivePerson? fromJson(Object? raw) {
    final j = _map(raw);
    final id = _str(j['id']), name = _str(j['name']);
    if (id == null || name == null) return null;
    final lat = _num(j['lat']), lng = _num(j['lng']);
    return LivePerson(
      id: id,
      name: name,
      kind: _str(j['kind']) ?? 'member',
      status: _str(j['status']),
      from: _str(j['from']),
      to: _str(j['to']),
      vehicle: _str(j['kind']) == 'bike' ? 'bike' : (_str(j['kind']) == 'van' ? 'van' : 'car'),
      area: _str(j['area']),
      point: lat == null || lng == null ? null : LatLng(lat, lng),
      at: _date(j['at']),
      eta: _int(j['eta']),
      etaToPickup: j['etaTo'] == 'pickup',
      progress: _num(j['progress']),
      dropoffAt: _date(j['dropoffAt']),
      driver: _str(j['driver']),
      car: _str(j['car']),
      trail: [
        for (final p in (j['trail'] is List ? j['trail'] as List : const []))
          if (p is List && p.length == 2 && _num(p[0]) != null && _num(p[1]) != null) LatLng(_num(p[0])!, _num(p[1])!),
      ],
      company: _str(j['company']),
      purpose: _str(j['purpose']),
      cost: _num(j['cost']),
      currency: _str(j['currency']) ?? 'MYR',
    );
  }

  final String id, name, kind, vehicle, currency;
  final String? status, from, to, area, driver, car, company, purpose;
  final LatLng? point;
  final DateTime? at, dropoffAt;
  final int? eta;
  final bool etaToPickup;
  final double? progress, cost;
  final List<LatLng> trail;

  bool get child => kind == 'child';

  String get initial => name.isEmpty ? '?' : name.characters.first.toUpperCase();

  /// The label over the dot: "Aisha · on a ride".
  String get mapLabel => switch (status) {
    'on_trip' => '$name · ${company == null ? 'on a ride' : (to == null ? 'on a trip' : 'to $to')}',
    'pickup' => '$name · driver coming',
    'waiting' => '$name · waiting',
    'dropped' => '$name · arrived',
    'here' => area == null ? name : '$name · $area',
    _ => name,
  };

  /// "Ride to KLCC", "Driver on the way", "Arrived at KLCC".
  String get tripLine => switch (status) {
    'on_trip' => to == null ? 'On a ride' : 'Ride to $to',
    'pickup' => 'Driver on the way',
    'waiting' => 'Looking for a driver',
    'dropped' => to == null ? 'Arrived' : 'Arrived at $to',
    'here' => 'Last seen here',
    _ => 'On the map',
  };

  String? get etaLine => eta == null ? null : (etaToPickup ? 'Pickup in $eta min' : 'ETA $eta min');
}

class LivePeople {
  const LivePeople({this.on = false, this.items = const [], this.at});

  factory LivePeople.fromJson(Object? raw, {String key = 'people'}) {
    final j = _map(raw);
    return LivePeople(
      on: j['on'] == true,
      items: [for (final p in (j[key] is List ? j[key] as List : const [])) ?LivePerson.fromJson(p)],
      at: _date(j['at']),
    );
  }

  static const none = LivePeople();
  final bool on;
  final List<LivePerson> items;
  final DateTime? at;

  List<LivePerson> get onMap => items.where((p) => p.point != null).toList();
  List<LivePerson> get offMap => items.where((p) => p.point == null).toList();
}

/// The member's own company trip: whether it shows on the company's map,
/// who can see it and who looked (rider_live_map_trip_note).
class CompanyTripNote {
  const CompanyTripNote({this.company = false, this.name, this.shown = false, this.who, this.seenBy = const []});

  factory CompanyTripNote.fromJson(Object? raw) {
    final j = _map(raw);
    return CompanyTripNote(
      company: j['company'] == true,
      name: _str(j['name']),
      shown: j['shown'] == true,
      who: _str(j['who']),
      seenBy: [
        for (final s in (j['seenBy'] is List ? j['seenBy'] as List : const []))
          ?_str(_map(s)['name']),
      ],
    );
  }

  final bool company, shown;
  final String? name, who;
  final List<String> seenBy;

  /// "Travel admins at Acme can see this trip on their map until drop-off."
  String get whoLine {
    final at = name ?? 'your company';
    if (!shown) return 'Paid by $at. Nobody at $at sees it on a map.';
    final whom = who == 'staff' ? 'Everyone at $at' : 'Travel admins at $at';
    return '$whom can see this trip on their map until drop-off.';
  }
}

// ---- The rules (admin) ---------------------------------------------------------------------------

/// The fields each mode can show, and the ones it never does.
const carsFieldNames = {'car': 'Car', 'bike': 'Bike', 'van': 'Van', 'count': 'Count', 'pickup_time': 'Pickup time'};
const busyFieldNames = {
  'level': 'Busy level',
  'fare': 'Fare level',
  'wait': 'Pickup wait',
  'next_hour': 'Next hour',
  'tip': 'Quieter nearby tip',
};
const peopleFieldNames = {
  'spot': 'Live spot',
  'status': 'Trip status',
  'eta': 'ETA',
  'dropoff': 'Drop-off time',
  'driver': 'Driver and car',
};
const teamFieldNames = {'spot': 'Live spot', 'purpose': 'Trip purpose', 'eta': 'ETA', 'cost': 'Cost so far'};
const carsNeverShown = 'Name, plate, photo, rating (never)';
const busyNeverShown = 'Counts, single trips (never)';
const peopleNeverShown = 'Plate (never)';
const teamNeverShown = 'Personal trips (never)';

const busyWho = {'all': 'All riders', 'plus': 'GET.Plus', 'nobody': 'Nobody'};
const peopleWho = {'hosts': 'Family hosts', 'members': 'All members', 'nobody': 'Nobody'};
const teamWho = {'admins': 'Travel admins', 'staff': 'All staff', 'nobody': 'Nobody'};

/// A number the admin steps: its column, label, unit, limits and step.
class RuleNumber {
  const RuleNumber(this.key, this.label, this.min, this.max, this.step, this.unit, {this.hint});
  final String key, label, unit;
  final String? hint;
  final int min, max, step;

  String show(int v) => switch (unit) {
    'm' => '$v m',
    's' => '$v s',
    'min' => key == 'people_history_min' && v == 0 ? 'None' : '$v min',
    'days' => v == 1 ? '1 day' : '$v days',
    '%' => '$v%',
    'bookings' => v == 1 ? '1 booking' : '$v bookings',
    _ => '$v',
  };

  int up(int v) => math.min(max, v + step);
  int down(int v) => math.max(min, v - step);
}

const carsNumbers = [
  RuleNumber('cars_offset_m', 'Move each car by', 0, 1000, 25, 'm', hint: 'Off its real spot, at random'),
  RuleNumber('cars_every_s', 'Update every', 5, 120, 5, 's'),
  RuleNumber('cars_radius_m', 'Show cars within', 500, 10000, 500, 'm'),
];
const busyNumbers = [
  RuleNumber('busy_hex_m', 'Hexagon size', 100, 2000, 50, 'm', hint: 'Across, flat side to flat side'),
  RuleNumber('busy_min', 'Show a hexagon from', 1, 100, 1, 'bookings'),
  RuleNumber('busy_every_s', 'Update every', 15, 600, 15, 's'),
  RuleNumber('busy_window_min', 'Count bookings of the last', 5, 240, 5, 'min'),
  RuleNumber('busy_opacity', 'See-through', 10, 90, 5, '%', hint: 'How solid the colours are'),
];
const peopleNumbers = [
  RuleNumber('people_history_min', 'Route history kept', 0, 120, 5, 'min'),
  RuleNumber('people_after_min', 'Stop showing after the trip', 0, 60, 1, 'min'),
  RuleNumber('people_every_s', 'Update every', 5, 120, 5, 's'),
];
const teamNumbers = [
  RuleNumber('team_after_min', 'Stop showing after the trip', 0, 60, 1, 'min'),
  RuleNumber('team_log_days', 'Keep trip log', 1, 365, 1, 'days'),
  RuleNumber('team_every_s', 'Update every', 5, 120, 5, 's'),
];

/// Every value a rule can set, by column.
const ruleKeys = <String>[
  'cars_on', 'cars_may_hide', 'cars_fields', 'cars_offset_m', 'cars_every_s', 'cars_radius_m',
  'busy_on', 'busy_who', 'busy_fields', 'busy_hex_m', 'busy_min', 'busy_every_s', 'busy_window_min',
  'busy_colours', 'busy_opacity',
  'people_on', 'people_who', 'people_fields', 'people_history_min', 'people_after_min', 'people_every_s',
  'team_on', 'team_who', 'team_fields', 'team_after_min', 'team_log_days', 'team_every_s',
];

/// A rule as the admin page edits it: its region and the values it sets
/// (a value not set follows the rule above).
class LiveMapRule {
  const LiveMapRule({this.id, this.country = '', this.state = '', this.city = '', this.suburb = '', this.values = const {}});

  factory LiveMapRule.fromJson(Map<String, dynamic> j) => LiveMapRule(
    id: _str(j['id']),
    country: _str(j['country']) ?? '',
    state: _str(j['state']) ?? '',
    city: _str(j['city']) ?? '',
    suburb: _str(j['suburb']) ?? '',
    values: {for (final k in ruleKeys) if (j[k] != null) k: j[k]},
  );

  final String? id;
  final String country, state, city, suburb;
  final Map<String, dynamic> values;

  bool get isDefault => country.isEmpty;

  /// How specific: 0 Default, 4 a suburb.
  int get rank => [country, state, city, suburb].where((s) => s.isNotEmpty).length;

  /// The narrowest name, or "Default".
  String get label => isDefault ? 'Default' : [suburb, city, state, country].firstWhere((s) => s.isNotEmpty);

  String get key => [country, state, city, suburb].map((s) => s.trim().toLowerCase()).join('|');

  /// Whether this rule applies at [place] (a broader one does too).
  bool appliesAt({String country = '', String state = '', String city = '', String suburb = ''}) {
    bool m(String rule, String at) => rule.isEmpty || rule.trim().toLowerCase() == at.trim().toLowerCase();
    return m(this.country, country) && m(this.state, state) && m(this.city, city) && m(this.suburb, suburb);
  }

  LiveMapRule copyWith(Map<String, dynamic> values) =>
      LiveMapRule(id: id, country: country, state: state, city: city, suburb: suburb, values: values);

  Map<String, dynamic> toRow() => {
    'country': country,
    'state': state,
    'city': city,
    'suburb': suburb,
    for (final k in ruleKeys) k: values[k],
  };
}

/// The values in force at a place: the server's rider_live_map_settings_at
/// (Default, then each matching rule from the broadest, each only what it
/// sets).
Map<String, dynamic> mergedRules(List<LiveMapRule> rules, {String country = '', String state = '', String city = '', String suburb = ''}) {
  final at = rules.where((r) => r.appliesAt(country: country, state: state, city: city, suburb: suburb)).toList()
    ..sort((a, b) => a.rank.compareTo(b.rank));
  return {
    for (final r in at)
      for (final e in r.values.entries)
        if (e.value != null) e.key: e.value,
  };
}

/// The values [rule] inherits from the rules above it (its region's parents).
Map<String, dynamic> inheritedFor(List<LiveMapRule> rules, LiveMapRule rule) => mergedRules(
  [for (final r in rules) if (r.rank < rule.rank) r],
  country: rule.country,
  state: rule.state,
  city: rule.city,
  suburb: rule.suburb,
);
