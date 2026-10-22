/// Ride Options by place (Admin → Display Settings → Ride Options →
/// Charges and where offered; migration 0253): each option charge, whether
/// an option is offered and the vehicle services it is blocked on, for
/// Default (everywhere) or a country, state, city or suburb. For a pickup
/// the smallest place with its own value wins, walking up suburb → city →
/// state → country → Default; with nothing set anywhere a charge is free and
/// an option is offered on every service. Names, order, show / hide and the
/// commission and promo switches stay one global setting
/// (ride_option_settings.dart). Pure.
library;

import 'option_charge.dart';
import 'partner_type_rules.dart' show RegionScope;
import 'ride_assistance.dart';
import 'ride_option_settings.dart';
import 'ride_pets.dart';

/// The keys a place's charges are kept under.
abstract final class OptionChargeKey {
  static const childSeat = 'child-seat';
  static const morePassengers = 'more-passengers';
  static String pet(String type) => 'pet:$type';
  static String petSize(String size) => 'pet-size:$size';
  static String assist(String id) => 'assist:$id';

  /// A freight option's fixed charge is kept under its own id ('helper-1').
  static String freight(RideOptionKind k) => k.id;

  /// The most a freight sender may declare (core/freight.dart): an amount
  /// up to [freightDeclaredCapMax], over an option charge's most.
  static const freightDeclaredCap = 'freight-declared-cap';

  /// The same for a courier sender (migration 0268).
  static const courierDeclaredCap = 'courier-declared-cap';
  static const freightDeclaredCapMax = 1000000.0;
}

/// A charge set at a place: a fixed amount or a percentage of the fare,
/// and for a pet type whether it is per pet or once per ride. A value of 0
/// is "free here", which still stops the place above from deciding.
class PlaceCharge {
  const PlaceCharge(this.charge, {this.perPet});

  final OptionCharge charge;

  /// Pet types only: per pet, else once per ride.
  final bool? perPet;

  static const free = PlaceCharge(OptionCharge.none);

  Map<String, Object> toJson() => {
    ...charge.toJson(),
    if (perPet != null) 'per': perPet! ? 'pet' : 'ride',
  };

  static PlaceCharge fromJson(Object? raw) => PlaceCharge(
    OptionCharge.fromJson(raw),
    perPet: raw is Map && raw['per'] != null ? raw['per'] != 'ride' : null,
  );

  @override
  bool operator ==(Object other) => other is PlaceCharge && other.charge == charge && other.perPet == perPet;

  @override
  int get hashCode => Object.hash(charge, perPet);
}

/// The place a row is for: Default ([RegionScope.all]) or a country, state,
/// city or suburb, named as the region tables name them.
extension OptionPlaceScope on RegionScope {
  bool get isDefault => isAll;

  /// As stored: 'default', 'country', 'state', 'city' or 'suburb'.
  String get level => const ['default', 'country', 'state', 'city', 'suburb'][path.length];

  /// "Default (everywhere)" or the narrowest name.
  String get placeName => name ?? 'Default (everywhere)';

  /// The place above; null for Default.
  RegionScope? get parent {
    final p = path;
    if (p.isEmpty) return null;
    return RegionScope(
      country: p.length > 1 ? p[0] : '',
      state: p.length > 2 ? p[1] : '',
      city: p.length > 3 ? p[2] : '',
    );
  }

  /// This place and every place above it, smallest first, ending with
  /// Default.
  List<RegionScope> get chain => [
    for (RegionScope? s = this; s != null; s = s.parent) s,
  ];
}

/// One place's own settings (a `ride_option_places` row).
class OptionPlaceSettings {
  const OptionPlaceSettings({
    this.scope = RegionScope.all,
    this.charges = const {},
    this.offered = const {},
    this.blocked = const {},
  });

  final RegionScope scope;

  /// By [OptionChargeKey]; a key present is set here.
  final Map<String, PlaceCharge> charges;

  /// "Offered here", by option; absent uses the place above.
  final Map<RideOptionKind, bool> offered;

  /// The vehicle services (settings entry ids) an option is blocked on
  /// here, by option; absent uses the place above.
  final Map<RideOptionKind, Set<String>> blocked;

  bool get isEmpty => charges.isEmpty && offered.isEmpty && blocked.isEmpty;

  static String _s(Object? v) => v is String ? v.trim() : '';

  static double _amount(Object? v, double max) {
    final n = v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
    return n == null || !n.isFinite || n < 0 ? 0 : (n > max ? max : n);
  }

  static OptionPlaceSettings fromRow(Map<String, dynamic> r) {
    final scope = RegionScope(country: _s(r['country']), state: _s(r['state']), city: _s(r['city']), suburb: _s(r['suburb']));
    final charges = r['charges'], offered = r['offered'], blocked = r['blocked'];
    return OptionPlaceSettings(
      scope: r['level'] == 'default' ? RegionScope.all : scope,
      charges: {
        if (charges is Map)
          for (final e in charges.entries)
            if (e.key is String && e.value is Map)
              e.key as String: e.key == OptionChargeKey.freightDeclaredCap || e.key == OptionChargeKey.courierDeclaredCap
                  ? PlaceCharge(OptionCharge(value: _amount((e.value as Map)['value'], OptionChargeKey.freightDeclaredCapMax)))
                  : PlaceCharge.fromJson(e.value),
      },
      offered: {
        if (offered is Map)
          for (final e in offered.entries)
            if (RideOptionKind.byId(e.key) case final k? when e.value is bool) k: e.value as bool,
      },
      blocked: {
        if (blocked is Map)
          for (final e in blocked.entries)
            if (RideOptionKind.byId(e.key) case final k? when e.value is List)
              k: {for (final s in e.value as List) if (s is String && s.isNotEmpty) s},
      },
    );
  }

  /// The row as written (the place's names and its three maps).
  Map<String, Object?> toRow() => {
    'level': scope.level,
    'country': scope.country.isEmpty ? null : scope.country,
    'state': scope.state.isEmpty ? null : scope.state,
    'city': scope.city.isEmpty ? null : scope.city,
    'suburb': scope.suburb.isEmpty ? null : scope.suburb,
    'charges': {for (final e in charges.entries) e.key: e.value.toJson()},
    'offered': {for (final e in offered.entries) e.key.id: e.value},
    'blocked': {for (final e in blocked.entries) e.key.id: [...e.value]..sort()},
  };

  OptionPlaceSettings copyWith({
    Map<String, PlaceCharge>? charges,
    Map<RideOptionKind, bool>? offered,
    Map<RideOptionKind, Set<String>>? blocked,
  }) => OptionPlaceSettings(
    scope: scope,
    charges: charges ?? this.charges,
    offered: offered ?? this.offered,
    blocked: blocked ?? this.blocked,
  );

  /// [key] set here to [c]; null takes it off (the place above decides).
  OptionPlaceSettings withCharge(String key, PlaceCharge? c) =>
      copyWith(charges: {...charges}..remove(key)..addAll({key: ?c}));

  OptionPlaceSettings withOffered(RideOptionKind k, bool? on) =>
      copyWith(offered: {...offered}..remove(k)..addAll({k: ?on}));

  OptionPlaceSettings withBlocked(RideOptionKind k, Set<String>? services) =>
      copyWith(blocked: {...blocked}..remove(k)..addAll({k: ?services}));

  /// A charge key renamed (a pet type renamed), here.
  OptionPlaceSettings withChargeRenamed(String from, String to) {
    final c = charges[from];
    if (c == null || from == to) return this;
    return copyWith(charges: {...charges}..remove(from)..[to] = c);
  }
}

/// Where a value comes from: the place that sets it; null when nothing in
/// the chain does.
typedef FromPlace<T> = ({T value, RegionScope? from});

/// Every place's settings, and what holds at a place.
class OptionPlaces {
  const OptionPlaces(this.rows);

  static const none = OptionPlaces([]);

  final List<OptionPlaceSettings> rows;

  /// Before migration 0253 (or with the table unreadable): the amounts the
  /// display settings blob held, as Default — as the migration moves them.
  factory OptionPlaces.fromBlob(Map<String, dynamic> s) =>
      OptionPlaces([OptionPlaceSettings(charges: chargesFromBlob(s))]);

  /// The charges a blob held, by key (each pet type's, each size extra,
  /// each help item's but the guide dog's).
  static Map<String, PlaceCharge> chargesFromBlob(Map<String, dynamic> s) {
    final pets = PetConfig.fromSettings(s);
    final help = AssistanceCatalogue.fromSettings(s);
    return {
      for (final e in pets.charges.entries)
        if (!e.value.isZero) OptionChargeKey.pet(e.key): PlaceCharge(e.value.charge, perPet: e.value.perPet),
      for (final e in pets.sizeExtras.entries)
        if (e.value > 0) OptionChargeKey.petSize(e.key): PlaceCharge(OptionCharge(value: e.value)),
      for (final i in help.items)
        if (!i.effectiveCharge.isZero) OptionChargeKey.assist(i.id): PlaceCharge(i.effectiveCharge),
    };
  }

  /// The row for [scope]; an empty one when it has none.
  OptionPlaceSettings at(RegionScope scope) {
    for (final r in rows) {
      if (r.scope.key == scope.key) return r;
    }
    return OptionPlaceSettings(scope: scope);
  }

  FromPlace<T>? _find<T>(RegionScope place, T? Function(OptionPlaceSettings) pick) {
    for (final s in place.chain) {
      final v = pick(at(s));
      if (v != null) return (value: v, from: s);
    }
    return null;
  }

  /// The charge at [key] for a pickup at [place]; free, from nowhere, when
  /// nothing in its chain sets it.
  FromPlace<PlaceCharge> chargeAt(RegionScope place, String key) =>
      _find(place, (r) => r.charges[key]) ?? (value: PlaceCharge.free, from: null);

  /// Whether [k] is offered at [place]; on, from nowhere, unless set.
  FromPlace<bool> offeredAt(RegionScope place, RideOptionKind k) =>
      _find(place, (r) => r.offered[k]) ?? (value: true, from: null);

  /// The services [k] is blocked on at [place]; none unless set.
  FromPlace<Set<String>> blockedAt(RegionScope place, RideOptionKind k) =>
      _find(place, (r) => r.blocked[k]) ?? (value: const <String>{}, from: null);

  /// Whether a rider at [place] booking [serviceId] sees [k].
  bool availableAt(RegionScope place, RideOptionKind k, {String? serviceId}) =>
      offeredAt(place, k).value && (serviceId == null || !blockedAt(place, k).value.contains(serviceId));

  /// What a rider at [place] is offered and pays.
  RideOptionsHere here(RegionScope place) => RideOptionsHere(this, place);

  /// Every row's charge [from] renamed [to] (a pet type renamed).
  List<OptionPlaceSettings> renamedCharge(String from, String to) => [
    for (final r in rows)
      if (r.charges.containsKey(from)) r.withChargeRenamed(from, to),
  ];
}

/// What holds for a rider at one place: the global settings with what is
/// off or blocked here hidden, and the charges here.
class RideOptionsHere {
  const RideOptionsHere(this.places, this.place);

  final OptionPlaces places;
  final RegionScope place;

  /// [base] with the options not offered here, or blocked for [serviceId],
  /// hidden.
  RideOptionsConfig config(RideOptionsConfig base, {String? serviceId}) {
    final off = {
      for (final k in RideOptionKind.values)
        if (!places.availableAt(place, k, serviceId: serviceId)) k,
    };
    return off.isEmpty ? base : base.copyWith(hidden: {...base.hidden, ...off});
  }

  PlaceCharge charge(String key) => places.chargeAt(place, key).value;

  /// [base] with each type's charge and each size's extra here.
  PetConfig pets(PetConfig base) => PetConfig(
    types: base.types,
    sizes: base.sizes,
    maxPerType: base.maxPerType,
    photoRequired: base.photoRequired,
    charges: {
      for (final t in base.types)
        if (charge(OptionChargeKey.pet(t)) case final c when !c.charge.isZero)
          t: PetCharge(charge: c.charge, perPet: c.perPet ?? true),
    },
    sizeExtras: {
      for (final z in base.sizes)
        if (charge(OptionChargeKey.petSize(z)).charge case final c when !c.isZero && !c.isPercent) z: c.value,
    },
  );

  /// [base] with each item's charge here (never the guide dog's).
  AssistanceCatalogue assistance(AssistanceCatalogue base) => AssistanceCatalogue(
    items: [for (final i in base.items) i.copyWith(charge: charge(OptionChargeKey.assist(i.id)).charge)],
  );

  /// For each child safety seat.
  OptionCharge get childSeat => charge(OptionChargeKey.childSeat).charge;

  /// Once for the ride.
  OptionCharge get morePassengers => charge(OptionChargeKey.morePassengers).charge;

  /// A freight option's fixed charge, once for the request.
  OptionCharge freight(RideOptionKind k) => charge(OptionChargeKey.freight(k)).charge;
}

/// One charge line on the admin page: its key, its option and its name.
typedef OptionChargeSlot = ({String key, RideOptionKind option, String label, bool perPetChoice, bool fixedOnly});

/// Every charge the admin can set, by option in the admin's order.
List<OptionChargeSlot> optionChargeSlots(RideOptionsConfig config, PetConfig pets, AssistanceCatalogue help) => [
  for (final k in config.order)
    ...switch (k) {
      RideOptionKind.childSeat => [
        (key: OptionChargeKey.childSeat, option: k, label: 'Each child seat', perPetChoice: false, fixedOnly: false),
      ],
      RideOptionKind.morePassengers => [
        (key: OptionChargeKey.morePassengers, option: k, label: config.labelOf(k), perPetChoice: false, fixedOnly: false),
      ],
      RideOptionKind.pet => [
        for (final t in pets.types)
          (key: OptionChargeKey.pet(t), option: k, label: t, perPetChoice: true, fixedOnly: false),
        for (final z in pets.sizes)
          (key: OptionChargeKey.petSize(z), option: k, label: 'Size $z, extra per pet', perPetChoice: false, fixedOnly: true),
      ],
      RideOptionKind.assistance => [
        for (final i in help.items)
          if (!i.isGuideDog)
            (key: OptionChargeKey.assist(i.id), option: k, label: i.name, perPetChoice: false, fixedOnly: false),
      ],
      // A fixed charge each (the Freight page, 0267).
      RideOptionKind.helperOne || RideOptionKind.helperTwo || RideOptionKind.closedBody || RideOptionKind.rideAlong => [
        (key: OptionChargeKey.freight(k), option: k, label: config.labelOf(k), perPetChoice: false, fixedOnly: true),
      ],
    },
];

/// "RM5", "10% of the fare", "RM5 per pet", "Free".
String describePlaceCharge(PlaceCharge c, String Function(double amount) money) {
  if (c.charge.isZero) return 'Free';
  final base = c.charge.describe(money);
  return switch (c.perPet) {
    true => '$base per pet',
    false => '$base once per ride',
    null => base,
  };
}
