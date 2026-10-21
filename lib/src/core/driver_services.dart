/// Driver services (migration 0263): the services a driver takes with the
/// car they drive, the switches they keep per car, and the locks get.ride
/// keeps on them. The same rule as the database's
/// `driver_service_effective`: the most specific active lock (driver, fleet,
/// region, partner type, everyone), else the driver's switch for that car,
/// else on. Also why a service is greyed out on the driver's Services page,
/// the page's rows, and the admin page's targets and words. Pure.
library;

import 'dart:convert';

import 'partner_type_services.dart' show partnerServiceKey;
import 'ride_extras.dart' show RideExtraSwitch;
import 'ride_option_settings.dart' show RideOptionKind;
import 'service_tree.dart' show serviceParentIds;

/// The keys a switch or a lock is kept under.
abstract final class DriverServiceKey {
  /// The meter, for a passenger who stops the car on the road.
  static const hailMeter = 'hail:meter';

  /// A street hail with the destination set (and the fare quoted) first.
  static const hailDestination = 'hail:destination';

  /// A Vehicle Service, by its name (`ptr_key`, as `ride_requests.service`
  /// is compared).
  static String service(String name) => partnerServiceKey(name);

  /// A ride add-on, by its `driver_ride_extras` key (0253).
  static String extra(String extraKey) => 'extra:${extraKey.trim().toLowerCase()}';

  /// A key as the database keeps it.
  static String normalise(String key) {
    final t = key.trim().toLowerCase();
    return RegExp(r'^(extra|hail):').hasMatch(t) ? t : partnerServiceKey(key);
  }

  /// The add-on of an `extra:` key, else null.
  static String? extraOf(String key) => key.startsWith('extra:') ? key.substring(6) : null;
}

// ---- Locks ------------------------------------------------------------------------

/// Who a lock is for, most specific first.
enum LockScope {
  driver('driver', 'One driver'),
  fleet('fleet', 'Fleet'),
  region('region', 'Region'),
  partnerType('partner_type', 'Partner type'),
  everyone('everyone', 'Everyone');

  const LockScope(this.id, this.label);

  /// As stored (`driver_service_locks.scope`).
  final String id;
  final String label;

  static LockScope? parse(Object? v) => values.where((s) => s.id == v).firstOrNull;
}

/// The lock that decides a service for a driver, as their page reads it.
class ServiceLock {
  const ServiceLock({required this.on, this.until, this.scope});

  /// Null when [j] is not a lock.
  static ServiceLock? fromJson(Object? j) {
    if (j is! Map) return null;
    final mode = j['mode'];
    if (mode != 'on' && mode != 'off') return null;
    return ServiceLock(
      on: mode == 'on',
      until: DateTime.tryParse('${j['until'] ?? ''}'),
      scope: LockScope.parse(j['scope']),
    );
  }

  /// Kept on (true) or off (false).
  final bool on;
  final DateTime? until;
  final LockScope? scope;
}

/// What a driver's switch is, when there is no lock: their own choice for
/// that car, else on.
bool effectiveOn({ServiceLock? lock, bool? pref}) => lock?.on ?? pref ?? true;

/// One `driver_service_locks` row.
class LockRule {
  const LockRule({
    required this.id,
    required this.scope,
    required this.serviceKey,
    required this.on,
    this.batchId,
    this.driverId,
    this.partnerType,
    this.fleetId,
    this.country,
    this.state,
    this.city,
    this.until,
    this.note,
    this.createdBy,
    this.createdAt,
    this.updatedBy,
    this.updatedAt,
  });

  factory LockRule.fromRow(Map<String, dynamic> r) {
    String? s(String k) {
      final v = '${r[k] ?? ''}'.trim();
      return v.isEmpty ? null : v;
    }

    return LockRule(
      id: '${r['id']}',
      batchId: s('batch_id'),
      scope: LockScope.parse(r['scope']) ?? LockScope.everyone,
      driverId: s('driver_id'),
      partnerType: s('partner_type'),
      fleetId: s('fleet_id'),
      country: s('region_country'),
      state: s('region_state'),
      city: s('region_city'),
      serviceKey: '${r['service_key'] ?? ''}',
      on: r['mode'] == 'on',
      until: DateTime.tryParse('${r['until'] ?? ''}'),
      note: s('note'),
      createdBy: s('created_by'),
      createdAt: DateTime.tryParse('${r['created_at'] ?? ''}'),
      updatedBy: s('updated_by'),
      updatedAt: DateTime.tryParse('${r['updated_at'] ?? ''}'),
    );
  }

  final String id;
  final String? batchId;
  final LockScope scope;
  final String? driverId;
  final String? partnerType;
  final String? fleetId;
  final String? country;
  final String? state;
  final String? city;
  final String serviceKey;
  final bool on;
  final DateTime? until;
  final String? note;
  final String? createdBy;
  final DateTime? createdAt;
  final String? updatedBy;
  final DateTime? updatedAt;

  LockTarget get target => LockTarget(
    scope: scope,
    driverId: driverId,
    partnerType: partnerType,
    fleetId: fleetId,
    country: country,
    state: state,
    city: city,
  );

  /// Whether it still counts at [now].
  bool activeAt(DateTime now) => until == null || until!.isAfter(now);
}

/// What a lock is matched against for one driver and the car they drive:
/// the car's (else the partner's) partner types and registration region,
/// and the fleets they drive for.
class LockSubject {
  LockSubject({
    required this.driverId,
    Iterable<String> fleetIds = const [],
    Iterable<String> partnerTypes = const [],
    Iterable<String> countries = const [],
    Iterable<String> states = const [],
    Iterable<String> cities = const [],
  }) : fleetIds = fleetIds.toSet(),
       partnerTypes = {for (final t in partnerTypes) partnerServiceKey(t)},
       countries = {for (final c in countries) _place(c)},
       states = {for (final c in states) _place(c)},
       cities = {for (final c in cities) _place(c)};

  final String driverId;
  final Set<String> fleetIds;
  final Set<String> partnerTypes;
  final Set<String> countries;
  final Set<String> states;
  final Set<String> cities;
}

String _place(String s) => s.trim().toLowerCase();

/// How specific [l] is for [s] (higher wins), or null when it does not
/// apply: driver 50, fleet 40, region 30 (+2 a city, +1 a state), partner
/// type 20, everyone 10 (`driver_service_lock_rank`).
int? lockRank(LockRule l, LockSubject s) => switch (l.scope) {
  LockScope.driver => l.driverId == s.driverId ? 50 : null,
  LockScope.fleet => s.fleetIds.contains(l.fleetId) ? 40 : null,
  LockScope.region =>
    l.country != null &&
            s.countries.contains(_place(l.country!)) &&
            (l.state == null || s.states.contains(_place(l.state!))) &&
            (l.city == null || s.cities.contains(_place(l.city!)))
        ? 30 + (l.city != null ? 2 : (l.state != null ? 1 : 0))
        : null,
  LockScope.partnerType => l.partnerType != null && s.partnerTypes.contains(partnerServiceKey(l.partnerType!)) ? 20 : null,
  LockScope.everyone => 10,
};

/// The lock that decides [serviceKey] for [s] at [now]: the most specific,
/// the latest of equals; expired ones count for nothing.
LockRule? winningLock(Iterable<LockRule> locks, LockSubject s, String serviceKey, DateTime now) {
  final key = DriverServiceKey.normalise(serviceKey);
  LockRule? best;
  int? bestRank;
  for (final l in locks) {
    if (DriverServiceKey.normalise(l.serviceKey) != key || !l.activeAt(now)) continue;
    final r = lockRank(l, s);
    if (r == null) continue;
    final later = (l.updatedAt ?? l.createdAt ?? DateTime(0)).isAfter(best?.updatedAt ?? best?.createdAt ?? DateTime(0));
    if (bestRank == null || r > bestRank || (r == bestRank && later)) {
      best = l;
      bestRank = r;
    }
  }
  return best;
}

/// Whether [serviceKey] is on for [s]: the deciding lock, else [pref].
bool serviceOnFor(Iterable<LockRule> locks, LockSubject s, String serviceKey, DateTime now, {bool? pref}) {
  final l = winningLock(locks, s, serviceKey, now);
  return effectiveOn(lock: l == null ? null : ServiceLock(on: l.on, until: l.until, scope: l.scope), pref: pref);
}

// ---- The driver's page: what the server says ----------------------------------------

/// The car the page is about.
class DriverCar {
  const DriverCar({
    required this.id,
    required this.plate,
    this.make = '',
    this.model = '',
    this.color = '',
    this.vehicleType = '',
    this.energy = '',
    this.serviceId,
    this.serviceName,
  });

  factory DriverCar.fromJson(Map j) {
    String s(String k) => '${j[k] ?? ''}'.trim();
    return DriverCar(
      id: s('id'),
      plate: s('plate'),
      make: s('make'),
      model: s('model'),
      color: s('color'),
      vehicleType: s('vehicle_type'),
      energy: s('energy'),
      serviceId: s('service_id').isEmpty ? null : s('service_id'),
      serviceName: s('service_name').isEmpty ? null : s('service_name'),
    );
  }

  final String id;
  final String plate;
  final String make;
  final String model;
  final String color;
  final String vehicleType;
  final String energy;

  /// Its Vehicle Service (the approved one, else the one asked for).
  final String? serviceId;
  final String? serviceName;

  /// "Perodua Bezza · Silver".
  String get title {
    final name = [make, model].where((s) => s.isNotEmpty).join(' ');
    return [if (name.isNotEmpty) name else 'Car', if (color.isNotEmpty) color].join(' · ');
  }
}

/// One Vehicle Service and what holds for this car.
class ServiceFacts {
  const ServiceFacts({
    required this.id,
    required this.name,
    this.typeNames = const [],
    this.parentIds = const [],
    this.description = '',
    this.maxPax,
    this.partnerOk = true,
    this.orderOk = true,
    this.permitMissing = false,
    this.pref,
    this.lock,
    this.on = true,
  });

  factory ServiceFacts.fromJson(Map j) {
    var types = j['types'];
    if (types is String && types.trim().startsWith('[')) {
      try {
        types = jsonDecode(types);
      } catch (_) {}
    }
    return ServiceFacts(
      id: '${j['id'] ?? ''}',
      name: '${j['name'] ?? ''}'.trim(),
      typeNames: [
        for (final t in types is List ? types : (types is String && types.trim().isNotEmpty ? [types] : const []))
          if ('$t'.trim().isNotEmpty) '$t'.trim(),
      ],
      parentIds: serviceParentIds({'parentServices': j['parents']}),
      description: '${j['description'] ?? ''}'.trim(),
      maxPax: _int(j['max_pax']),
      partnerOk: j['partner_ok'] != false,
      orderOk: j['order_ok'] != false,
      permitMissing: j['permit_missing'] == true,
      pref: j['pref'] is bool ? j['pref'] as bool : null,
      lock: ServiceLock.fromJson(j['lock']),
      on: j['on'] != false,
    );
  }

  final String id;
  final String name;

  /// The master services it sits under, by name (`serviceTypes`).
  final List<String> typeNames;
  final List<String> parentIds;
  final String description;
  final int? maxPax;

  /// Its partner types allow it (0257).
  final bool partnerOk;

  /// The car's service may take it (the service order, 0250).
  final bool orderOk;

  /// A required permit for it is missing (0254).
  final bool permitMissing;

  /// The driver's switch for this car, null when never set.
  final bool? pref;
  final ServiceLock? lock;

  /// On now, by the server's rule.
  final bool on;

  String get key => DriverServiceKey.service(name);
}

int? _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}'.trim());

/// A switch that is not a Vehicle Service (street hail, an add-on).
class KeyState {
  const KeyState({this.pref, this.lock, this.on = true});

  factory KeyState.fromJson(Object? j) => j is Map
      ? KeyState(pref: j['pref'] is bool ? j['pref'] as bool : null, lock: ServiceLock.fromJson(j['lock']), on: j['on'] != false)
      : const KeyState();

  final bool? pref;
  final ServiceLock? lock;
  final bool on;
}

/// `driver_services_for`: the car, its partner types, and each service.
class DriverServicesOverview {
  const DriverServicesOverview({
    this.car,
    this.types = const [],
    this.orderEnforced = false,
    this.services = const [],
    this.keys = const {},
  });

  factory DriverServicesOverview.fromJson(Object? j) {
    if (j is! Map || j['vehicle'] is! Map) return const DriverServicesOverview();
    final keys = j['keys'];
    return DriverServicesOverview(
      car: DriverCar.fromJson(j['vehicle'] as Map),
      types: [
        for (final t in (j['types'] is List ? j['types'] as List : const []))
          if ('$t'.trim().isNotEmpty) '$t'.trim(),
      ],
      orderEnforced: j['order_enforced'] == true,
      services: [
        for (final s in (j['services'] is List ? j['services'] as List : const []))
          if (s is Map && '${s['name'] ?? ''}'.trim().isNotEmpty) ServiceFacts.fromJson(s),
      ],
      keys: {
        if (keys is Map)
          for (final e in keys.entries) '${e.key}': KeyState.fromJson(e.value),
      },
    );
  }

  /// Null when the driver has no car in use.
  final DriverCar? car;

  /// The car's partner types (else the partner's), as named.
  final List<String> types;
  final bool orderEnforced;
  final List<ServiceFacts> services;
  final Map<String, KeyState> keys;

  KeyState key(String k) => keys[k] ?? const KeyState();

  /// The car's own service.
  ServiceFacts? get own => car?.serviceId == null ? null : services.where((s) => s.id == car!.serviceId).firstOrNull;

  /// "eHailing · Sedan · Petrol".
  String get carDetails => [
    if (types.isNotEmpty) types.join(', '),
    if (car != null && car!.vehicleType.isNotEmpty) car!.vehicleType,
    if (car != null && car!.energy.isNotEmpty) car!.energy,
  ].join(' · ');
}

/// Whether the driver gets the Services page: a car in use, and partner
/// types that offer at least one ride or delivery service.
bool servicesPageAvailable(DriverServicesOverview? o) =>
    o != null && o.car != null && o.services.any((s) => s.partnerOk);

// ---- Tabs ---------------------------------------------------------------------------

enum ServiceTab {
  transport('Transport'),
  deliveries('Deliveries');

  const ServiceTab(this.label);
  final String label;
}

final _delivery = RegExp(r'deliver|food|mart|parcel|courier|grocer|freight|send|pharmac|shop', caseSensitive: false);

/// Deliveries for a service whose name, or every master service it sits
/// under, is a delivery one (Delivery, Food, Mart, …); else Transport.
ServiceTab serviceTabFor(String name, Iterable<String> typeNames) {
  if (_delivery.hasMatch(name)) return ServiceTab.deliveries;
  final types = typeNames.where((t) => t.trim().isNotEmpty).toList();
  if (types.isNotEmpty && types.every(_delivery.hasMatch)) return ServiceTab.deliveries;
  return ServiceTab.transport;
}

// ---- Why a service is greyed out ------------------------------------------------------

/// Why this car can't take [s], or null when it can. [own] is the car's
/// own service; [regionOk] whether the region offers [s] where the driver
/// is (unknown: true). The car's size and class only grey a service out
/// while the service order applies to every booking ([orderEnforced]),
/// as the server only refuses them then.
String? ineligibleReason(ServiceFacts s, {ServiceFacts? own, bool orderEnforced = false, bool regionOk = true}) {
  if (!s.partnerOk) return 'Not in your partner type';
  if (orderEnforced && !s.orderOk) {
    if (own == null) return "Your car's service isn't approved yet";
    final mine = own.maxPax, theirs = s.maxPax;
    if (mine != null && theirs != null && theirs > mine) return 'This car has $mine seats';
    return 'Needs a ${s.name.trim().toLowerCase()} car';
  }
  if (s.permitMissing) return 'Permit missing';
  if (!regionOk) return 'Not offered in your area';
  return null;
}

// ---- The page's rows ------------------------------------------------------------------

enum ServiceRowKind { service, hail, addOn }

/// One row on the driver's Services page.
class ServiceRow {
  const ServiceRow({
    required this.key,
    required this.title,
    required this.kind,
    this.subtitle = '',
    this.on = true,
    this.reason,
    this.lock,
  });

  /// The switch's key (DriverServiceKey).
  final String key;
  final String title;
  final String subtitle;
  final ServiceRowKind kind;
  final bool on;

  /// Why it is greyed out; null when the car can take it.
  final String? reason;

  /// Set by get.ride: the switch can't be changed.
  final ServiceLock? lock;


  /// Whether the driver may flip it.
  bool get switchable => reason == null && lock == null;

  /// What the switch shows: a greyed-out service is off.
  bool get shownOn => reason == null && on;
}

class ServiceSection {
  const ServiceSection({required this.title, this.hint, required this.rows});
  final String title;
  final String? hint;
  final List<ServiceRow> rows;
}

/// The add-on groups of the "Ride extras I take" page (rideExtraGroups).
typedef AddOnGroup = ({RideOptionKind option, String title, List<RideExtraSwitch> items});

/// Whether the car's partner types take any service on [tab].
bool tabOffered(DriverServicesOverview o, ServiceTab tab) =>
    o.services.any((s) => s.partnerOk && serviceTabFor(s.name, s.typeNames) == tab);

/// The tab the page opens on: Transport, unless only deliveries are offered.
ServiceTab firstTab(DriverServicesOverview o) =>
    !tabOffered(o, ServiceTab.transport) && tabOffered(o, ServiceTab.deliveries) ? ServiceTab.deliveries : ServiceTab.transport;

/// The sections of [tab]: the main services (what the car can do first,
/// then the greyed ones with their reason), and on Transport, street hail
/// and the add-ons (when the partner types take rides). [extrasOff] is the
/// driver's own add-on list (0253); [regionOff] the service ids the region
/// doesn't offer where the driver is.
List<ServiceSection> servicesPageSections(
  DriverServicesOverview o,
  ServiceTab tab, {
  List<AddOnGroup> addOns = const [],
  Set<String> extrasOff = const {},
  Set<String> regionOff = const {},
}) {
  final own = o.own;
  final main = <ServiceRow>[
    for (final s in o.services)
      if (serviceTabFor(s.name, s.typeNames) == tab)
        ServiceRow(
          key: s.key,
          title: s.name,
          subtitle: s.description,
          kind: ServiceRowKind.service,
          on: s.on,
          lock: s.lock,
          reason: ineligibleReason(s, own: own, orderEnforced: o.orderEnforced, regionOk: !regionOff.contains(s.id)),
        ),
  ];
  // What the car can do first, the greyed ones after, each in the catalogue's order.
  final ordered = [...main.where((r) => r.reason == null), ...main.where((r) => r.reason != null)];
  final out = <ServiceSection>[
    ServiceSection(title: 'Main services', rows: ordered),
  ];
  if (tab != ServiceTab.transport || !tabOffered(o, ServiceTab.transport)) return out;

  ServiceRow hail(String key, String title, String subtitle) {
    final k = o.key(key);
    return ServiceRow(key: key, title: title, subtitle: subtitle, kind: ServiceRowKind.hail, on: k.on, lock: k.lock);
  }

  out.add(ServiceSection(
    title: 'Street hail',
    hint: 'Passengers who stop you on the road',
    rows: [
      hail(DriverServiceKey.hailMeter, 'Meter (street hail)', 'Start the meter for a walk-up passenger'),
      hail(DriverServiceKey.hailDestination, 'Street hail with destination', 'Set where they are going and quote the fare first'),
    ],
  ));
  final extras = <ServiceRow>[
    for (final g in addOns)
      for (final i in g.items)
        () {
          final key = DriverServiceKey.extra(i.key);
          final lock = o.key(key).lock;
          final single = g.items.length == 1 && i.label == g.title;
          return ServiceRow(
            key: key,
            title: single ? g.title : i.label,
            subtitle: single ? '' : g.title,
            kind: ServiceRowKind.addOn,
            on: effectiveOn(lock: lock, pref: !extrasOff.contains(i.key)),
            lock: lock,
          );
        }(),
  ];
  if (extras.isNotEmpty) {
    out.add(ServiceSection(title: 'Add-ons', hint: 'Requests that ask for these', rows: extras));
  }
  return out;
}

// ---- Words ----------------------------------------------------------------------------

/// The toast after a switch: "Ride on. You'll get these requests."
String serviceToggleToast(String name, bool on) =>
    on ? "$name on. You'll get these requests." : "$name off. You won't get these requests.";

/// The padlock row's words.
String lockLabel(ServiceLock l) => l.on ? 'Kept on by get.ride' : 'Kept off by get.ride';

/// What tapping a padlock row says.
const lockedServiceMessage = 'Set by get.ride. Contact support to change it.';

/// The page's footer.
const servicesFooter =
    "You only get requests for services that are on. Services greyed out don't fit this car, your partner type or "
    'your permits. Changes apply straight away.';

/// Street hail as the meter checks it before a hire: whether each kind may
/// start, and why not.
class HailGate {
  const HailGate({this.meter = const KeyState(), this.destination = const KeyState()});

  factory HailGate.of(DriverServicesOverview? o) => o == null || o.car == null
      ? const HailGate()
      : HailGate(meter: o.key(DriverServiceKey.hailMeter), destination: o.key(DriverServiceKey.hailDestination));

  final KeyState meter;
  final KeyState destination;

  /// Null when a hire may start ([withDestination]: one with a destination
  /// set); else the title and message to show.
  ({String title, String message})? refusal({bool withDestination = false}) {
    if (!meter.on) return _off('Meter (street hail)', 'start the meter for a walk-up passenger', meter.lock);
    if (withDestination && !destination.on) {
      return _off('Street hail with destination', 'set a destination for a street hail', destination.lock);
    }
    return null;
  }

  /// Null when a destination may be set for a street hail.
  ({String title, String message})? destinationRefusal() =>
      destination.on ? null : _off('Street hail with destination', 'set a destination for a street hail', destination.lock);

  static ({String title, String message}) _off(String name, String what, ServiceLock? lock) => (
    title: '$name is off',
    message: lock != null && !lock.on
        ? 'get.ride keeps $name off for you, so you can\'t $what. Contact support to change it.'
        : "You turned $name off in Services, so you can't $what. Turn it on in Services first.",
  );
}

// ---- Admin: targets, choices and words --------------------------------------------------

/// What an admin sets each service to.
enum LockChoice {
  driver('driver', 'Driver decides'),
  on('on', 'Keep on'),
  off('off', 'Keep off');

  const LockChoice(this.id, this.label);
  final String id;
  final String label;
}

/// Who a lock is for. Several drivers are several [LockScope.driver]
/// targets saved together.
class LockTarget {
  const LockTarget({
    required this.scope,
    this.driverId,
    this.partnerType,
    this.fleetId,
    this.country,
    this.state,
    this.city,
  });

  const LockTarget.everyone() : this(scope: LockScope.everyone);

  final LockScope scope;
  final String? driverId;
  final String? partnerType;
  final String? fleetId;
  final String? country;
  final String? state;
  final String? city;

  /// For `driver_service_locks_set`.
  Map<String, dynamic> toJson() => {
    'scope': scope.id,
    'driver_id': ?driverId,
    'partner_type': ?partnerType,
    'fleet_id': ?fleetId,
    'country': ?country,
    'state': ?state,
    'city': ?city,
  };

  /// The same target as the database compares them.
  String get id => [
    scope.id,
    driverId ?? '',
    partnerType == null ? '' : partnerServiceKey(partnerType!),
    fleetId ?? '',
    (country ?? '').trim().toLowerCase(),
    (state ?? '').trim().toLowerCase(),
    (city ?? '').trim().toLowerCase(),
  ].join('|');

  @override
  bool operator ==(Object other) => other is LockTarget && other.id == id;

  @override
  int get hashCode => id.hashCode;

  /// "Selangor, Malaysia".
  String get regionLabel => [city, state, country].whereType<String>().where((s) => s.trim().isNotEmpty).join(', ');
}

/// The locks of each target, the latest changed first.
List<({LockTarget target, List<LockRule> locks})> groupLocks(Iterable<LockRule> rules) {
  final by = <LockTarget, List<LockRule>>{};
  for (final r in rules) {
    (by[r.target] ??= []).add(r);
  }
  DateTime last(List<LockRule> l) =>
      l.map((r) => r.updatedAt ?? r.createdAt ?? DateTime(0)).reduce((a, b) => a.isAfter(b) ? a : b);
  final out = [for (final e in by.entries) (target: e.key, locks: e.value)]
    ..sort((a, b) => last(b.locks).compareTo(last(a.locks)));
  return out;
}

/// The form's choices for [target] from its saved locks: Keep on / off for
/// each locked service, Driver decides for the rest.
Map<String, LockChoice> choicesFor(LockTarget target, Iterable<LockRule> rules) => {
  for (final r in rules)
    if (r.target == target) DriverServiceKey.normalise(r.serviceKey): r.on ? LockChoice.on : LockChoice.off,
};

/// What the form sends for [keys]: every key, Driver decides where unset
/// (which gives a service back to the drivers).
Map<String, String> lockRulesPayload(Iterable<String> keys, Map<String, LockChoice> choices) => {
  for (final k in keys) DriverServiceKey.normalise(k): (choices[DriverServiceKey.normalise(k)] ?? LockChoice.driver).id,
};

/// A service key in words: the Vehicle Service's name, the street hail
/// modes and the add-ons by their names ([names]: key to name).
String describeServiceKey(String key, Map<String, String> names) {
  final k = DriverServiceKey.normalise(key);
  if (names[k] != null) return names[k]!;
  if (k == DriverServiceKey.hailMeter) return 'Meter (street hail)';
  if (k == DriverServiceKey.hailDestination) return 'Street hail with destination';
  final extra = DriverServiceKey.extraOf(k);
  if (extra != null) {
    if (extra.startsWith('pet:')) return 'Pet: ${extra.substring(4)}';
    if (extra.startsWith('assist:')) return 'Assistance: ${extra.substring(7)}';
    return extra.replaceAll('-', ' ');
  }
  return key;
}

/// "Kept off" / "Kept on", for the admin's list.
String lockModeLabel(bool on) => on ? 'Kept on' : 'Kept off';
