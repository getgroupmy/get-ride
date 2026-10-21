/// Airports (Admin → Settings → Airport Areas, migration 0249): the doors a
/// rider picks, the pickup guides, the airport fares and charges, the rules
/// for who gets an airport pickup, and the drivers' waiting queue.
///
/// The server decides everything here that counts (the fare, the charges,
/// who may see and take a pickup, the queue); these are the same rules for
/// what the apps show, and for tests. Pure.
library;

import 'dart:math' as math;

// ---------------------------------------------------------------------------
// Doors (the airport's gates in `multi_gate`)
// ---------------------------------------------------------------------------

/// What a door is used for. Stored as the gate's `values.mode`: `drop`,
/// `pickup` or `both`.
enum DoorKind { drop, pick, both }

DoorKind doorKindOf(Object? mode) => switch ('${mode ?? 'both'}') {
  'pickup' || 'pick' => DoorKind.pick,
  'drop' => DoorKind.drop,
  _ => DoorKind.both,
};

/// The gate's `values.mode` for [k].
String doorMode(DoorKind k) => switch (k) {
  DoorKind.pick => 'pickup',
  DoorKind.drop => 'drop',
  DoorKind.both => 'both',
};

String doorKindLabel(DoorKind k) => switch (k) {
  DoorKind.drop => 'Drop-off',
  DoorKind.pick => 'Pickup',
  DoorKind.both => 'Both',
};

/// Which end of the ride is at the airport.
enum AirportSide { pick, drop }

bool doorServes(DoorKind k, AirportSide side) =>
    k == DoorKind.both ||
    (side == AirportSide.pick ? k == DoorKind.pick : k == DoorKind.drop);

/// One step of a pickup door's how-to guide.
class GuideStep {
  const GuideStep({this.photo, this.text = ''});

  /// The photo's stored link (the `airport-guides` bucket's public form).
  final String? photo;
  final String text;

  static GuideStep? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final p = '${raw['photo'] ?? ''}'.trim();
    return GuideStep(
      photo: p.isEmpty ? null : p,
      text: '${raw['text'] ?? ''}'.trim(),
    );
  }

  Map<String, Object?> toJson() => {'photo': photo, 'text': text};

  GuideStep copyWith({String? photo, bool clearPhoto = false, String? text}) =>
      GuideStep(
        photo: clearPhoto ? null : (photo ?? this.photo),
        text: text ?? this.text,
      );

  @override
  bool operator ==(Object other) =>
      other is GuideStep && other.photo == photo && other.text == text;

  @override
  int get hashCode => Object.hash(photo, text);
}

/// Most steps a guide keeps (the database's limit).
const maxGuideSteps = 20;

/// Longest step text.
const maxGuideText = 500;

class AirportDoor {
  const AirportDoor({
    required this.id,
    required this.airportId,
    required this.name,
    required this.kind,
    this.sortOrder = 9999,
    this.active = true,
    this.lat,
    this.lng,
    this.guide = const [],
    this.group = '',
  });

  final String id;
  final String airportId;
  final String name;
  final DoorKind kind;
  final num sortOrder;
  final bool active;
  final double? lat, lng;
  final List<GuideStep> guide;

  /// The group the door is in (an airport's terminal, a mall's wing):
  /// `values.group`, '' for none. The gate picker shows a wheel of groups
  /// beside the doors when there is more than one.
  final String group;

  /// The same door in [group] (a linked place's name in the door sheet).
  AirportDoor withGroup(String group) => AirportDoor(
        id: id,
        airportId: airportId,
        name: name,
        kind: kind,
        sortOrder: sortOrder,
        active: active,
        lat: lat,
        lng: lng,
        guide: guide,
        group: group,
      );

  /// A `multi_gate` gate row's `values` (the airport's when `parentKey` is
  /// `airport-areas`).
  static AirportDoor fromGate(String id, Map<String, dynamic> v) {
    double? n(Object? x) =>
        x is num ? x.toDouble() : double.tryParse('${x ?? ''}'.trim());
    final name = '${v['name'] ?? ''}'.trim();
    return AirportDoor(
      id: id,
      airportId: '${v['placeId'] ?? ''}',
      name: name.isEmpty ? 'Door' : name,
      kind: doorKindOf(v['mode']),
      sortOrder: n(v['displayPriority']) ?? 9999,
      active: _flag(v['active']),
      lat: n(v['lat']),
      lng: n(v['lon'] ?? v['lng']),
      guide: [
        if (v['guide'] is List)
          for (final s in v['guide'] as List) ?GuideStep.fromJson(s),
      ],
      group: '${v['group'] ?? ''}'.trim(),
    );
  }
}

bool _flag(Object? v, {bool fallback = true}) {
  if (v == null) return fallback;
  if (v is bool) return v;
  if (v is num) return v != 0;
  final s = '$v'.trim().toLowerCase();
  if (s.isEmpty) return fallback;
  return !(s == 'false' || s == '0' || s == 'no' || s == 'off');
}

/// The active doors of [airportId] a rider can choose for [side], in the
/// admin's order.
List<AirportDoor> doorsFor(
  List<AirportDoor> doors,
  String airportId,
  AirportSide side,
) =>
    [
      for (final d in doors)
        if (d.airportId == airportId && d.active && doorServes(d.kind, side)) d,
    ]..sort((a, b) {
      final c = a.sortOrder.compareTo(b.sortOrder);
      return c != 0 ? c : a.name.compareTo(b.name);
    });

/// "How to get there · 3 steps ›", or null without steps.
String? guideLinkLabel(AirportDoor d) {
  final n = d.guide.length;
  if (n == 0) return null;
  return 'How to get there · $n step${n == 1 ? '' : 's'} ›';
}

/// [steps] with step [i] moved one place ([dir] -1 up, +1 down); the same
/// list when it can't move.
List<T> moveStep<T>(List<T> steps, int i, int dir) {
  final j = i + dir;
  if (i < 0 || i >= steps.length || j < 0 || j >= steps.length) return steps;
  final out = [...steps];
  final t = out[i];
  out[i] = out[j];
  out[j] = t;
  return out;
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

enum PickupSource { queue, zone }

enum EmptyAction { wait, decline, nearby }

class AirportCharge {
  const AirportCharge({
    this.on = false,
    this.name = 'Airport fee',
    this.amount = 0,
  });
  final bool on;
  final String name;
  final double amount;

  /// What it adds to a fare: its amount when on, else nothing.
  double get applied => on && amount > 0 ? _cents(amount) : 0;
}

enum BandExtra { extra, all }

enum BandApplies { both, pick, drop }

class BandTier {
  const BandTier({required this.uptoKm, required this.flat});
  final double uptoKm;
  final double flat;

  Map<String, Object> toJson() => {'uptoKm': uptoKm, 'flat': flat};

  @override
  bool operator ==(Object other) =>
      other is BandTier && other.uptoKm == uptoKm && other.flat == flat;

  @override
  int get hashCode => Object.hash(uptoKm, flat);
}

class DistanceBand {
  const DistanceBand({
    this.on = false,
    this.tiers = const [BandTier(uptoKm: 10, flat: 40)],
    this.extra = BandExtra.extra,
    this.applies = BandApplies.both,
  });

  final bool on;

  /// Ascending by [BandTier.uptoKm]; at least one.
  final List<BandTier> tiers;
  final BandExtra extra;
  final BandApplies applies;

  bool appliesTo(AirportSide side) =>
      applies == BandApplies.both ||
      (side == AirportSide.pick
          ? applies == BandApplies.pick
          : applies == BandApplies.drop);

  List<BandTier> get sorted =>
      [...tiers]..sort((a, b) => a.uptoKm.compareTo(b.uptoKm));

  DistanceBand copyWith({
    bool? on,
    List<BandTier>? tiers,
    BandExtra? extra,
    BandApplies? applies,
  }) => DistanceBand(
    on: on ?? this.on,
    tiers: tiers ?? this.tiers,
    extra: extra ?? this.extra,
    applies: applies ?? this.applies,
  );

  Map<String, Object> toJson() => {
    'on': on,
    'tiers': [for (final t in sorted) t.toJson()],
    'extra': extra.name,
    'applies': applies.name,
  };

  static DistanceBand fromJson(Object? raw) {
    if (raw is! Map) return const DistanceBand();
    final tiers = [
      if (raw['tiers'] is List)
        for (final t in raw['tiers'] as List)
          if (t is Map && _n(t['uptoKm']) != null && _n(t['flat']) != null)
            BandTier(uptoKm: _n(t['uptoKm'])!, flat: _n(t['flat'])!),
    ];
    return DistanceBand(
      on: raw['on'] == true,
      tiers: tiers.isEmpty
          ? const [BandTier(uptoKm: 10, flat: 40)]
          : (tiers..sort((a, b) => a.uptoKm.compareTo(b.uptoKm))),
      extra: raw['extra'] == 'all' ? BandExtra.all : BandExtra.extra,
      applies: switch (raw['applies']) {
        'pick' => BandApplies.pick,
        'drop' => BandApplies.drop,
        _ => BandApplies.both,
      },
    );
  }
}

/// A new tier after [tiers]: 10 km and RM 15 more than the last.
List<BandTier> addBandTier(List<BandTier> tiers) {
  final s = [...tiers]..sort((a, b) => a.uptoKm.compareTo(b.uptoKm));
  if (s.isEmpty) return const [BandTier(uptoKm: 10, flat: 40)];
  final last = s.last;
  return [...s, BandTier(uptoKm: last.uptoKm + 10, flat: last.flat + 15)];
}

/// [tiers] without tier [i]; the last one left is never removed.
List<BandTier> removeBandTier(List<BandTier> tiers, int i) =>
    tiers.length <= 1 || i < 0 || i >= tiers.length
    ? tiers
    : ([...tiers]..removeAt(i));

/// Why the tiers can't be saved, or null.
String? bandTiersProblem(List<BandTier> tiers) {
  if (tiers.isEmpty) return 'Add at least one band.';
  final s = [...tiers]..sort((a, b) => a.uptoKm.compareTo(b.uptoKm));
  for (var i = 0; i < s.length; i++) {
    if (s[i].uptoKm <= 0) return 'Each band ends after 0 km.';
    if (s[i].flat < 0) return 'A flat fare is zero or more.';
    if (i > 0 && s[i].uptoKm == s[i - 1].uptoKm) {
      return 'Two bands end at the same distance.';
    }
  }
  return null;
}

class MinFare {
  const MinFare({this.on = false, this.amount = 0});
  final bool on;
  final double amount;
  Map<String, Object> toJson() => {'on': on, 'amount': amount};
  static MinFare fromJson(Object? raw) => raw is Map
      ? MinFare(on: raw['on'] == true, amount: _n(raw['amount']) ?? 0)
      : const MinFare();
}

/// The Fares tab (`airport_settings.fares`).
class AirportFares {
  const AirportFares({
    this.base = const {},
    this.minPick = const MinFare(),
    this.minDrop = const MinFare(),
    this.band = const DistanceBand(),
    this.roundUp = true,
  });

  /// Airport base by service name (compared without case).
  final Map<String, double> base;
  final MinFare minPick, minDrop;
  final DistanceBand band;

  /// Round the total up to a whole amount.
  final bool roundUp;

  double baseFor(String service) {
    final k = service.trim().toLowerCase();
    for (final e in base.entries) {
      if (e.key.trim().toLowerCase() == k) return math.max(0, e.value);
    }
    return 0;
  }

  AirportFares copyWith({
    Map<String, double>? base,
    MinFare? minPick,
    MinFare? minDrop,
    DistanceBand? band,
    bool? roundUp,
  }) => AirportFares(
    base: base ?? this.base,
    minPick: minPick ?? this.minPick,
    minDrop: minDrop ?? this.minDrop,
    band: band ?? this.band,
    roundUp: roundUp ?? this.roundUp,
  );

  Map<String, Object> toJson() => {
    'base': {
      for (final e in base.entries)
        if (e.value > 0) e.key.trim().toLowerCase(): e.value,
    },
    'minPick': minPick.toJson(),
    'minDrop': minDrop.toJson(),
    'band': band.toJson(),
    'roundUp': roundUp,
  };

  static AirportFares fromJson(Object? raw) {
    if (raw is! Map) return const AirportFares();
    final base = <String, double>{};
    if (raw['base'] is Map) {
      for (final e in (raw['base'] as Map).entries) {
        final v = _n(e.value);
        if (v != null) base['${e.key}'.trim().toLowerCase()] = v;
      }
    }
    return AirportFares(
      base: base,
      minPick: MinFare.fromJson(raw['minPick']),
      minDrop: MinFare.fromJson(raw['minDrop']),
      band: DistanceBand.fromJson(raw['band']),
      roundUp: raw['roundUp'] != false,
    );
  }
}

double? _n(Object? v) {
  final d = v is num ? v.toDouble() : double.tryParse('${v ?? ''}'.trim());
  return d == null || !d.isFinite ? null : d;
}

double _cents(double v) => (v * 100).roundToDouble() / 100;

/// One airport's `airport_settings` row.
class AirportSettings {
  const AirportSettings({
    required this.airportId,
    this.dropDoorRequired = true,
    this.pickDoorRequired = true,
    this.restrictPickups = false,
    this.pickupFrom = const {PickupSource.queue},
    this.emptyAction = EmptyAction.wait,
    this.nearbyAfterMin = 5,
    this.queueByService = true,
    this.needDropoff = true,
    this.joinWindowMin = 60,
    this.leaveGraceMin = 3,
    this.backOnDecline = true,
    this.offerSeconds = 30,
    this.dropFee = const AirportCharge(),
    this.pickFee = const AirportCharge(),
    this.fares = const AirportFares(),
    this.guideOn = true,
    this.faresOn = true,
  });

  /// A place's settings before the admin changes any (0258): every tool off.
  const AirportSettings.place(this.airportId)
    : dropDoorRequired = false,
      pickDoorRequired = false,
      restrictPickups = false,
      pickupFrom = const {PickupSource.queue},
      emptyAction = EmptyAction.wait,
      nearbyAfterMin = 5,
      queueByService = true,
      needDropoff = true,
      joinWindowMin = 60,
      leaveGraceMin = 3,
      backOnDecline = true,
      offerSeconds = 30,
      dropFee = const AirportCharge(name: 'Place fee'),
      pickFee = const AirportCharge(name: 'Place fee'),
      fares = const AirportFares(roundUp: false),
      guideOn = false,
      faresOn = false;

  final String airportId;

  /// Riders see the pickup doors' guides (0258; an airport's is always on).
  final bool guideOn;

  /// The area's own fares apply; off: the normal tariff (0258).
  final bool faresOn;
  final bool dropDoorRequired, pickDoorRequired, restrictPickups;
  final Set<PickupSource> pickupFrom;
  final EmptyAction emptyAction;
  final int nearbyAfterMin;
  final bool queueByService, needDropoff;
  final int joinWindowMin, leaveGraceMin;
  final bool backOnDecline;
  final int offerSeconds;
  final AirportCharge dropFee, pickFee;
  final AirportFares fares;

  bool doorRequired(AirportSide side) =>
      side == AirportSide.pick ? pickDoorRequired : dropDoorRequired;
  AirportCharge chargeFor(AirportSide side) =>
      side == AirportSide.pick ? pickFee : dropFee;

  static AirportSettings fromRow(Map<String, dynamic> r) {
    int i(String k, int d) => (_n(r[k]) ?? d).round();
    bool b(String k, bool d) => r[k] is bool ? r[k] as bool : d;
    final from = <PickupSource>{
      if (r['pickup_from'] is List)
        for (final s in r['pickup_from'] as List)
          if (s == 'queue')
            PickupSource.queue
          else if (s == 'zone')
            PickupSource.zone,
    };
    return AirportSettings(
      airportId: '${r['airport_id'] ?? ''}',
      dropDoorRequired: b('drop_door_required', true),
      pickDoorRequired: b('pick_door_required', true),
      restrictPickups: b('restrict_pickups', false),
      pickupFrom: from.isEmpty ? const {PickupSource.queue} : from,
      emptyAction: switch (r['empty_action']) {
        'decline' => EmptyAction.decline,
        'nearby' => EmptyAction.nearby,
        _ => EmptyAction.wait,
      },
      nearbyAfterMin: i('nearby_after_min', 5),
      queueByService: b('queue_by_service', true),
      needDropoff: b('need_dropoff', true),
      joinWindowMin: i('join_window_min', 60),
      leaveGraceMin: i('leave_grace_min', 3),
      backOnDecline: b('back_on_decline', true),
      offerSeconds: i('offer_seconds', 30),
      dropFee: AirportCharge(
        on: b('drop_fee_on', false),
        name: '${r['drop_fee_name'] ?? 'Airport fee'}',
        amount: _n(r['drop_fee_amount']) ?? 0,
      ),
      pickFee: AirportCharge(
        on: b('pick_fee_on', false),
        name: '${r['pick_fee_name'] ?? 'Airport fee'}',
        amount: _n(r['pick_fee_amount']) ?? 0,
      ),
      fares: AirportFares.fromJson(r['fares']),
      guideOn: b('guide_on', true),
      faresOn: b('fares_on', true),
    );
  }

  Map<String, Object?> toRow() => {
    'airport_id': airportId,
    'drop_door_required': dropDoorRequired,
    'pick_door_required': pickDoorRequired,
    'restrict_pickups': restrictPickups,
    'pickup_from': [
      for (final s in PickupSource.values)
        if (pickupFrom.contains(s)) s.name,
    ],
    'empty_action': emptyAction.name,
    'nearby_after_min': nearbyAfterMin,
    'queue_by_service': queueByService,
    'need_dropoff': needDropoff,
    'join_window_min': joinWindowMin,
    'leave_grace_min': leaveGraceMin,
    'back_on_decline': backOnDecline,
    'offer_seconds': offerSeconds,
    'drop_fee_on': dropFee.on,
    'drop_fee_name': dropFee.name.trim().isEmpty
        ? 'Airport fee'
        : dropFee.name.trim(),
    'drop_fee_amount': _cents(dropFee.amount),
    'pick_fee_on': pickFee.on,
    'pick_fee_name': pickFee.name.trim().isEmpty
        ? 'Airport fee'
        : pickFee.name.trim(),
    'pick_fee_amount': _cents(pickFee.amount),
    'fares': fares.toJson(),
    'guide_on': guideOn,
    'fares_on': faresOn,
  };

  AirportSettings copyWith({
    bool? dropDoorRequired,
    bool? pickDoorRequired,
    bool? restrictPickups,
    Set<PickupSource>? pickupFrom,
    EmptyAction? emptyAction,
    int? nearbyAfterMin,
    bool? queueByService,
    bool? needDropoff,
    int? joinWindowMin,
    int? leaveGraceMin,
    bool? backOnDecline,
    int? offerSeconds,
    AirportCharge? dropFee,
    AirportCharge? pickFee,
    AirportFares? fares,
    bool? guideOn,
    bool? faresOn,
  }) => AirportSettings(
    airportId: airportId,
    dropDoorRequired: dropDoorRequired ?? this.dropDoorRequired,
    pickDoorRequired: pickDoorRequired ?? this.pickDoorRequired,
    restrictPickups: restrictPickups ?? this.restrictPickups,
    pickupFrom: pickupFrom ?? this.pickupFrom,
    emptyAction: emptyAction ?? this.emptyAction,
    nearbyAfterMin: nearbyAfterMin ?? this.nearbyAfterMin,
    queueByService: queueByService ?? this.queueByService,
    needDropoff: needDropoff ?? this.needDropoff,
    joinWindowMin: joinWindowMin ?? this.joinWindowMin,
    leaveGraceMin: leaveGraceMin ?? this.leaveGraceMin,
    backOnDecline: backOnDecline ?? this.backOnDecline,
    offerSeconds: offerSeconds ?? this.offerSeconds,
    dropFee: dropFee ?? this.dropFee,
    pickFee: pickFee ?? this.pickFee,
    fares: fares ?? this.fares,
    guideOn: guideOn ?? this.guideOn,
    faresOn: faresOn ?? this.faresOn,
  );

  /// The place's extra charge (0258): one switch, one label, the pickup and
  /// drop-off amounts.
  bool get placeChargeOn => pickFee.on || dropFee.on;

  /// Riders must pick a door at either end (a place's one switch).
  bool get doorsRequired => pickDoorRequired && dropDoorRequired;
}

/// [s] with the place's charge switched [on], its [label] and amounts.
AirportSettings withPlaceCharge(
  AirportSettings s, {
  bool? on,
  String? label,
  double? pickAmount,
  double? dropAmount,
}) {
  final o = on ?? s.placeChargeOn;
  final name = label ?? (s.pickFee.name.trim().isNotEmpty ? s.pickFee.name : s.dropFee.name);
  return s.copyWith(
    pickFee: AirportCharge(on: o, name: name, amount: pickAmount ?? s.pickFee.amount),
    dropFee: AirportCharge(on: o, name: name, amount: dropAmount ?? s.dropFee.amount),
  );
}

/// [current] with [s] switched; at least one source always stays on.
Set<PickupSource> togglePickupSource(
  Set<PickupSource> current,
  PickupSource s,
) {
  if (current.contains(s)) {
    return current.length == 1 ? current : ({...current}..remove(s));
  }
  return {...current, s};
}

/// What the Pickup rules tab says the chosen sources do.
String pickupSourceSummary(Set<PickupSource> from) {
  if (from.length == 2) {
    return 'Both: the queue is offered first, in order; if nobody in it takes the order, any driver in a waiting zone can.';
  }
  return from.contains(PickupSource.queue)
      ? 'Only queued drivers, in queue order.'
      : 'Any driver standing in a waiting zone, nearest first; no queue order.';
}

String emptyActionSummary(EmptyAction a, {String noun = 'airport'}) => switch (a) {
  EmptyAction.wait => 'The request stays open until a driver joins the queue or the rider cancels.',
  EmptyAction.decline => 'The rider is told no $noun driver is free right now and the request closes.',
  EmptyAction.nearby => 'After the time below, drivers outside the $noun get it as a normal request.',
};

// ---------------------------------------------------------------------------
// Fares and charges (as public.airport_quote)
// ---------------------------------------------------------------------------

/// A charge line on a ride (`ride_requests.charges`).
typedef AirportChargeLine = ({String name, double amount});

/// The airport charges of a ride from [pickAirport] to [dropAirport] (each
/// null when that end is not at an airport): the drop-off's, then the
/// pickup's.
List<AirportChargeLine> airportCharges({
  AirportSettings? pickAirport,
  AirportSettings? dropAirport,
}) => [
  if (dropAirport != null && dropAirport.dropFee.applied > 0)
    (name: dropAirport.dropFee.name, amount: dropAirport.dropFee.applied),
  if (pickAirport != null && pickAirport.pickFee.applied > 0)
    (name: pickAirport.pickFee.name, amount: pickAirport.pickFee.applied),
];

typedef QuoteLine = ({String label, double amount, bool charge});

class AirportQuote {
  const AirportQuote({
    required this.lines,
    required this.fare,
    required this.charge,
    required this.total,
    required this.fixed,
    required this.how,
    this.areaId = '',
  });

  /// The airport or place whose fare it is.
  final String areaId;

  final List<QuoteLine> lines;

  /// The ride's fare (the total less the charges): what `ride_requests.fare`
  /// carries.
  final double fare;
  final double charge;
  final double total;

  /// The fare was a zone fare or the band's, not the normal one: no bidding.
  final bool fixed;
  final String how;

  /// The breakdown the server stamps (`ride_requests.airport_fare`) or quotes.
  static AirportQuote? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final total = _n(raw['total']);
    if (total == null) return null;
    return AirportQuote(
      lines: [
        if (raw['lines'] is List)
          for (final l in raw['lines'] as List)
            if (l is Map && _n(l['amount']) != null)
              (
                label: '${l['label'] ?? ''}',
                amount: _n(l['amount'])!,
                charge: l['charge'] == true,
              ),
      ],
      fare: _n(raw['fare']) ?? total,
      charge: _n(raw['charge']) ?? 0,
      total: total,
      fixed: raw['fixed'] == true,
      how: '${raw['how'] ?? ''}',
      areaId: '${raw['airport'] ?? ''}',
    );
  }
}

String _trimNum(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : '${_cents(v)}';

/// The airport fare of a ride from ([AirportSide.pick]) or to
/// ([AirportSide.drop]) an airport, in five steps:
///   1. [zoneFare] when the other end is in a fare zone (its fixed fare for
///      this direction), else the distance band — the first tier the trip
///      fits in; past the last, its flat fare + [perKm] for the km past it
///      ([BandExtra.extra]) or for the whole trip ([BandExtra.all]) — else
///      the [normal] fare;
///   2. + the [service]'s airport base;
///   3. raised to the pickup / drop-off minimum;
///   4. + the ride's [options] (pets, assistance: 0248's option charges,
///      which stay part of the fare);
///   5. + the airport [charges];
///   6. rounded up to a whole amount when [AirportFares.roundUp].
/// [normal] is the route fare without the option charges.
AirportQuote quoteAirportFare({
  required AirportFares fares,
  required AirportSide side,
  required String service,
  required double km,
  required double normal,
  required double perKm,
  ({String name, double amount})? zoneFare,
  List<AirportChargeLine> charges = const [],
  List<({String name, double amount})> options = const [],
}) {
  final d = math.max(0.0, km);
  final lines = <QuoteLine>[];
  double? ride;
  var how = '';
  var fixed = false;
  if (zoneFare != null) {
    ride = zoneFare.amount;
    how =
        'Fixed fare, ${zoneFare.name} ${side == AirportSide.pick ? 'from' : 'to'} the airport';
    fixed = true;
  } else if (fares.band.on &&
      fares.band.appliesTo(side) &&
      fares.band.tiers.isNotEmpty) {
    final tiers = fares.band.sorted;
    for (final t in tiers) {
      if (d <= t.uptoKm) {
        ride = t.flat;
        how = 'Flat fare up to ${_trimNum(t.uptoKm)} km';
        break;
      }
    }
    if (ride == null) {
      final last = tiers.last;
      if (fares.band.extra == BandExtra.all) {
        ride = last.flat + perKm * d;
        how =
            'Flat fare + normal rate for all ${_trimNum((d * 10).roundToDouble() / 10)} km';
      } else {
        ride = last.flat + perKm * (d - last.uptoKm);
        how =
            'Flat fare + normal rate for ${_trimNum(((d - last.uptoKm) * 10).roundToDouble() / 10)} km '
            'past ${_trimNum(last.uptoKm)} km';
      }
    }
    fixed = true;
  }
  if (ride == null) {
    ride = normal;
    how = 'Normal fare';
  }
  final r = _cents(math.max(0, ride));
  lines.add((label: how, amount: r, charge: false));
  final base = _cents(fares.baseFor(service));
  if (base > 0) {
    lines.add((
      label: '${service.trim().isEmpty ? 'Ride' : service.trim()} airport base',
      amount: base,
      charge: false,
    ));
  }
  var sub = _cents(r + base);
  final min = side == AirportSide.pick ? fares.minPick : fares.minDrop;
  if (min.on && min.amount > sub) {
    lines.add((
      label:
          'Raised to the ${side == AirportSide.pick ? 'pickup' : 'drop-off'} minimum',
      amount: _cents(min.amount - sub),
      charge: false,
    ));
    sub = _cents(min.amount);
  }
  // The ride's option charges (pets, assistance; 0248): part of the fare,
  // after the minimum.
  for (final o in options) {
    if (o.amount <= 0) continue;
    sub = _cents(sub + o.amount);
    lines.add((label: o.name, amount: _cents(o.amount), charge: false));
  }
  var charge = 0.0;
  for (final c in charges) {
    charge += c.amount;
    lines.add((label: c.name, amount: c.amount, charge: true));
  }
  charge = _cents(charge);
  final total = _cents(sub + charge);
  // A hair under the next cent counts as on it (floating point).
  final up = fares.roundUp ? (total - 1e-9).ceilToDouble() : total;
  if (up > total + 1e-9) {
    lines.add((label: 'Rounded up', amount: _cents(up - total), charge: false));
  }
  return AirportQuote(
    lines: lines,
    fare: _cents(up - charge),
    charge: charge,
    total: up,
    fixed: fixed,
    how: how,
  );
}

/// The normal tariff's rate per km where there is no card: the built-in
/// TEKSI rate (RM 0.35 per 200 m) with the service's multiplier.
double defaultPerKm(double multiplier) => 1.75 * multiplier;

// ---------------------------------------------------------------------------
// The waiting queue (as airport_on_presence / airport_dispatch)
// ---------------------------------------------------------------------------

/// Whether a driver standing in a waiting zone may join the queue: with a
/// drop-off at this airport not yet used within the join window, or with
/// none needed.
bool canJoinQueue({
  required bool needDropoff,
  required DateTime now,
  DateTime? dropoffAt,
  required int joinWindowMin,
}) {
  if (dropoffAt != null &&
      now.difference(dropoffAt) < Duration(minutes: joinWindowMin)) {
    return true;
  }
  return !needDropoff;
}

/// Minutes left to reach a waiting zone after a drop-off, never below 0.
int minutesLeftToJoin(DateTime dropoffAt, DateTime now, int joinWindowMin) {
  final left = dropoffAt.add(Duration(minutes: joinWindowMin)).difference(now);
  return left.isNegative ? 0 : (left.inSeconds / 60).ceil();
}

/// A place in the queue.
class QueuePlace {
  const QueuePlace({
    required this.driverId,
    required this.placeAt,
    required this.joinedAt,
    this.service = '',
  });
  final String driverId;
  final DateTime placeAt, joinedAt;
  final String service;

  QueuePlace withPlaceAt(DateTime t) => QueuePlace(
    driverId: driverId,
    placeAt: t,
    joinedAt: joinedAt,
    service: service,
  );
}

/// The queue in order: the earliest drop-off (or time sent to the back)
/// first, then who joined first. With [service] (and [byService]), only that
/// service's line (and drivers kept for every service).
List<QueuePlace> queueOrder(
  List<QueuePlace> places, {
  String? service,
  bool byService = true,
}) =>
    [
      for (final p in places)
        if (!byService ||
            service == null ||
            p.service.isEmpty ||
            p.service.toLowerCase() == service.toLowerCase())
          p,
    ]..sort((a, b) {
      final c = a.placeAt.compareTo(b.placeAt);
      if (c != 0) return c;
      final j = a.joinedAt.compareTo(b.joinedAt);
      return j != 0 ? j : a.driverId.compareTo(b.driverId);
    });

/// The queue after [driverId] declined or missed an offer: at the back when
/// [backOnDecline], else as it was.
List<QueuePlace> afterRefusal(
  List<QueuePlace> places,
  String driverId, {
  required bool backOnDecline,
  required DateTime now,
}) {
  if (!backOnDecline) return places;
  var latest = now;
  for (final p in places) {
    if (p.placeAt.isAfter(latest)) latest = p.placeAt;
  }
  final back = latest == now
      ? now
      : latest.add(const Duration(milliseconds: 1));
  return [
    for (final p in places) p.driverId == driverId ? p.withPlaceAt(back) : p,
  ];
}

/// The vehicle services from lowest to highest (`vehicle_service_order`,
/// Admin → Airport Areas → Waiting queue): a driver whose vehicle's service
/// is higher may take a lower one's orders, never the reverse.
class ServiceOrder {
  const ServiceOrder(this.ids);

  /// Vehicle Services entry ids, lowest first.
  final List<String> ids;

  int? rankOf(String? id) {
    final i = id == null ? -1 : ids.indexOf(id);
    return i < 0 ? null : i + 1;
  }

  /// How far above a ride's service [driverService] is (as
  /// `airport_line_gap`): 0 for the same service, or a ride whose service
  /// is not known ([rideService] null); the difference in rank for a higher
  /// one; null when the driver may not take it — a lower or unranked
  /// service, or a vehicle with none.
  int? lineGap(String? driverService, String? rideService) {
    if (driverService == null || driverService.isEmpty) return null;
    if (rideService == null ||
        rideService.isEmpty ||
        driverService == rideService) {
      return 0;
    }
    final d = rankOf(driverService), r = rankOf(rideService);
    if (d == null || r == null || d <= r) return null;
    return d - r;
  }

  bool canTake(String? driverService, String? rideService) =>
      lineGap(driverService, rideService) != null;

  /// [ids] with the id at [from] moved to [to] (a drag in the admin list).
  ServiceOrder moved(int from, int to) {
    if (from < 0 || from >= ids.length) return this;
    final out = [...ids];
    final id = out.removeAt(from);
    out.insert(to.clamp(0, out.length), id);
    return ServiceOrder(out);
  }

  /// The admin's list: the ranked services in order, then any not ranked
  /// yet, in [all]'s order. Ids no longer in [all] are dropped.
  static ServiceOrder arrange(List<String> ranked, List<String> all) =>
      ServiceOrder([
        for (final id in ranked)
          if (all.contains(id)) id,
        for (final id in all)
          if (!ranked.contains(id)) id,
      ]);
}

/// The queued drivers who may take a ride of [rideService], in offer order
/// (as `airport_queue_lineup`): with [byService], the ride's own line first,
/// then each higher service in rank order, and in each line by place; with
/// one queue for every service, by place alone. [QueuePlace.service] is the
/// vehicle's service id.
List<QueuePlace> airportLineup(
  List<QueuePlace> places, {
  required String? rideService,
  required ServiceOrder order,
  bool byService = true,
}) {
  final gaps = <String, int>{};
  final eligible = <QueuePlace>[];
  for (final p in places) {
    final g = order.lineGap(p.service, rideService);
    if (g == null) continue;
    gaps[p.driverId] = g;
    eligible.add(p);
  }
  final placed = queueOrder(eligible, byService: false);
  if (!byService) return placed;
  final rank = {for (var i = 0; i < placed.length; i++) placed[i].driverId: i};
  return placed..sort((a, b) {
    final c = gaps[a.driverId]!.compareTo(gaps[b.driverId]!);
    return c != 0 ? c : rank[a.driverId]!.compareTo(rank[b.driverId]!);
  });
}

/// Who a held pickup of [rideService] is offered to next: the first queued
/// driver (in [airportLineup] order) not yet offered it, else (with zones on)
/// every driver in a zone whose vehicle may take it and who was not offered
/// it yet, nearest first; empty when nobody is left.
({PickupSource? stage, List<String> drivers}) nextOffer({
  required Set<PickupSource> from,
  required List<QueuePlace> queue,
  required List<({String driverId, double km, String service})> inZone,
  required Set<String> alreadyOffered,
  String? riderId,
  String? rideService,
  ServiceOrder order = const ServiceOrder([]),
  bool byService = true,
}) {
  if (from.contains(PickupSource.queue)) {
    for (final p in airportLineup(
      queue,
      rideService: rideService,
      order: order,
      byService: byService,
    )) {
      if (p.driverId != riderId && !alreadyOffered.contains(p.driverId)) {
        return (stage: PickupSource.queue, drivers: [p.driverId]);
      }
    }
  }
  if (from.contains(PickupSource.zone)) {
    final z = [
      for (final d in inZone)
        if (d.driverId != riderId &&
            !alreadyOffered.contains(d.driverId) &&
            order.canTake(d.service, rideService))
          d,
    ]..sort((a, b) => a.km.compareTo(b.km));
    if (z.isNotEmpty) {
      return (
        stage: PickupSource.zone,
        drivers: [for (final d in z) d.driverId],
      );
    }
  }
  return (stage: null, drivers: const []);
}

/// What happens to a pickup nobody can be offered.
enum EmptyOutcome { waits, declined, nearbyLater, nearbyNow }

EmptyOutcome emptyOutcome(EmptyAction a, int nearbyAfterMin) => switch (a) {
  EmptyAction.wait => EmptyOutcome.waits,
  EmptyAction.decline => EmptyOutcome.declined,
  EmptyAction.nearby =>
    nearbyAfterMin <= 0 ? EmptyOutcome.nearbyNow : EmptyOutcome.nearbyLater,
};

/// Why an airport request closed (`ride_requests.cancel_reason`).
const airportNoDriverReason = 'AIRPORT_NO_DRIVER';

const airportNoDriverMessage =
    'No airport driver is free right now. Please try again in a few minutes.';

// ---------------------------------------------------------------------------
// The driver's state (airport_driver_state)
// ---------------------------------------------------------------------------

enum DriverAirportStage { outside, around, dropped, queued, offer, refused }

class DriverAirportState {
  const DriverAirportState({
    this.stage = DriverAirportStage.outside,
    this.code = '',
    this.airport = '',
    this.service = '',
    this.position,
    this.total,
    this.minutesLeft,
    this.zones = const [],
    this.door,
    this.rideId,
    this.outside = false,
    this.graceMin,
    this.reason = '',
    this.place = false,
  });

  /// The queue is a place's (0258), not an airport's: "place" in the words.
  final bool place;
  String get _noun => place ? 'place' : 'airport';

  final DriverAirportStage stage;

  /// Why the driver was refused: `no_dropoff` or `no_service` (a vehicle
  /// without an approved service type).
  final String reason;
  final String code, airport, service;
  final int? position, total, minutesLeft;
  final List<String> zones;
  final String? door, rideId;

  /// Queued but outside the zone (the place is kept for [graceMin]).
  final bool outside;
  final int? graceMin;

  static const outsideState = DriverAirportState();

  static DriverAirportState fromJson(Object? raw) {
    if (raw is! Map) return outsideState;
    String s(String k) => '${raw[k] ?? ''}'.trim();
    int? i(String k) => _n(raw[k])?.round();
    return DriverAirportState(
      stage: switch (raw['state']) {
        'around' => DriverAirportStage.around,
        'dropped' => DriverAirportStage.dropped,
        'queued' => DriverAirportStage.queued,
        'offer' => DriverAirportStage.offer,
        'refused' => DriverAirportStage.refused,
        _ => DriverAirportStage.outside,
      },
      code: s('code'),
      airport: s('airport'),
      service: s('service'),
      position: i('position'),
      total: i('total'),
      minutesLeft: i('minutes_left'),
      zones: [
        if (raw['zones'] is List)
          for (final z in raw['zones'] as List)
            if ('$z'.trim().isNotEmpty) '$z'.trim(),
      ],
      door: s('door').isEmpty ? null : s('door'),
      rideId: s('ride_id').isEmpty ? null : s('ride_id'),
      outside: raw['outside_since'] != null,
      graceMin: i('grace_min'),
      reason: s('reason'),
      place: raw['kind'] == 'place',
    );
  }

  /// The airport's code, else its name.
  String get where =>
      code.isNotEmpty ? code : (airport.isNotEmpty ? airport : 'the $_noun');

  String get _queueName => service.isEmpty ? '$_noun queue' : '$service queue';

  /// The pill on the card.
  String get title => switch (stage) {
    DriverAirportStage.outside => 'Outside the $_noun',
    DriverAirportStage.around => 'At $where',
    DriverAirportStage.dropped => 'Dropped off at $where',
    DriverAirportStage.queued => 'In the $_queueName',
    DriverAirportStage.offer => place ? 'Queue order' : 'Airport order',
    DriverAirportStage.refused => "Can't join the queue",
  };

  /// The card's message.
  String get message => switch (stage) {
    DriverAirportStage.outside => 'Normal orders.',
    DriverAirportStage.around =>
      'Go to the waiting zone to receive $_noun orders.',
    DriverAirportStage.dropped =>
      'Go to the waiting zone within ${minutesLeft ?? 0} min to join the $_queueName.',
    DriverAirportStage.queued =>
      outside
          ? 'You left the waiting zone. Go back within ${graceMin ?? 0} min to keep your place.'
          : 'of ${total ?? 0} waiting · stay in the zone to keep your place',
    DriverAirportStage.offer => door ?? 'Pickup at the $_noun',
    DriverAirportStage.refused =>
      reason == 'no_service'
          ? "Your vehicle has no approved service type yet, so it can't join $_article $_noun queue. "
                'Choose one on your vehicle, or ask support to approve it.'
          : 'Only drivers who dropped off at $where can wait for $_noun orders.',
  };

  String get _article => place ? 'a' : 'an';

  bool get showCard => stage != DriverAirportStage.outside;
}
