/// Admin → Display Settings → Ride Options: which options the rider's
/// Options sheet shows, in what order and under what name, and the most
/// child safety seats a rider can ask for. Kept in the display settings
/// blob under [RideOptionsConfig.key]. Pure.
library;

import 'ride_assistance.dart';
import 'ride_confirm.dart' show RideOptions;

/// The options on the rider's Options sheet.
enum RideOptionKind {
  childSeat('child-seat', 'Child safety seat'),
  morePassengers('more-passengers', 'More than ${RideOptions.standardSeats} passengers'),
  pet('pet', 'Pet with me'),
  assistance('assistance', 'Assistance required');

  const RideOptionKind(this.id, this.defaultLabel);

  /// As stored.
  final String id;

  /// The name riders see until the admin renames it.
  final String defaultLabel;

  static RideOptionKind? byId(Object? id) {
    for (final k in values) {
      if (k.id == id) return k;
    }
    return null;
  }
}

class RideOptionsConfig {
  const RideOptionsConfig({
    this.order = RideOptionKind.values,
    this.hidden = const {},
    this.labels = const {},
    this.childSeatMax = 1,
  });

  static const key = 'rideOptions';

  /// "Most seats a rider can ask for".
  static const childSeatLimit = 3;

  /// The longest name an admin may give an option.
  static const labelMax = 40;

  /// Every option, in the admin's order.
  final List<RideOptionKind> order;
  final Set<RideOptionKind> hidden;

  /// The admin's own names; none for the built-in one.
  final Map<RideOptionKind, String> labels;

  /// Above 1 the rider picks a number of seats instead of a switch.
  final int childSeatMax;

  static RideOptionsConfig fromSettings(Map<String, dynamic> s) {
    final raw = s[key];
    if (raw is! Map) return const RideOptionsConfig();
    final order = <RideOptionKind>[];
    if (raw['order'] is List) {
      for (final id in raw['order'] as List) {
        final k = RideOptionKind.byId(id);
        if (k != null && !order.contains(k)) order.add(k);
      }
    }
    for (final k in RideOptionKind.values) {
      if (!order.contains(k)) order.add(k);
    }
    final labels = <RideOptionKind, String>{};
    if (raw['labels'] is Map) {
      for (final e in (raw['labels'] as Map).entries) {
        final k = RideOptionKind.byId(e.key);
        final v = e.value is String ? (e.value as String).trim() : '';
        if (k != null && v.isNotEmpty && v.length <= labelMax && v != k.defaultLabel) labels[k] = v;
      }
    }
    final m = raw['childSeatMax'];
    final max = m is num ? m.toInt() : (m is String ? int.tryParse(m.trim()) : null);
    return RideOptionsConfig(
      order: List.unmodifiable(order),
      hidden: {
        if (raw['hidden'] is List)
          for (final id in raw['hidden'] as List) ?RideOptionKind.byId(id),
      },
      labels: labels,
      childSeatMax: (max ?? 1).clamp(1, childSeatLimit),
    );
  }

  Map<String, Object> toJson() => {
    'order': [for (final k in order) k.id],
    'hidden': [for (final k in order) if (hidden.contains(k)) k.id],
    'labels': {for (final e in labels.entries) e.key.id: e.value},
    'childSeatMax': childSeatMax,
  };

  Map<String, Object> toSettings() => {key: toJson()};

  String labelOf(RideOptionKind k) => labels[k] ?? k.defaultLabel;

  /// The admin's own names, by option id, for the driver's note.
  Map<String, String> get renamed => {for (final e in labels.entries) e.key.id: e.value};

  /// The names the options [o] has on were offered under, by option id:
  /// stamped on the ride (`option_names`), so the driver reads it as booked.
  Map<String, String> namesFor(RideOptions o) => {
    for (final k in order)
      if (switch (k) {
        RideOptionKind.childSeat => o.childSeat,
        RideOptionKind.morePassengers => o.morePassengers,
        RideOptionKind.pet => o.pet,
        RideOptionKind.assistance => o.assistance != null,
      })
        k.id: labelOf(k),
  };

  bool isShown(RideOptionKind k) => !hidden.contains(k);

  /// What the sheet shows, in order. "Assistance required" also needs
  /// something in its [catalogue] to pick.
  List<RideOptionKind> shown({AssistanceCatalogue catalogue = const AssistanceCatalogue()}) => [
    for (final k in order)
      if (isShown(k) && (k != RideOptionKind.assistance || catalogue.visible.isNotEmpty)) k,
  ];

  /// Whether any option is shown (the Options sheet always has Comments).
  bool anyShown({AssistanceCatalogue catalogue = const AssistanceCatalogue()}) =>
      shown(catalogue: catalogue).isNotEmpty;

  /// [o] with what is no longer offered dropped: a hidden option is off and
  /// the seats are within the admin's most.
  RideOptions allowed(RideOptions o, {AssistanceCatalogue catalogue = const AssistanceCatalogue()}) {
    final on = shown(catalogue: catalogue).toSet();
    return RideOptions(
      childSeat: o.childSeat && on.contains(RideOptionKind.childSeat),
      childSeats: o.childSeats.clamp(1, childSeatMax),
      morePassengers: o.morePassengers && on.contains(RideOptionKind.morePassengers),
      pet: o.pet && on.contains(RideOptionKind.pet),
      pets: on.contains(RideOptionKind.pet) ? o.pets : const [],
      assistance: on.contains(RideOptionKind.assistance) ? o.assistance : null,
    );
  }

  RideOptionsConfig copyWith({
    List<RideOptionKind>? order,
    Set<RideOptionKind>? hidden,
    Map<RideOptionKind, String>? labels,
    int? childSeatMax,
  }) => RideOptionsConfig(
    order: order ?? this.order,
    hidden: hidden ?? this.hidden,
    labels: labels ?? this.labels,
    childSeatMax: childSeatMax ?? this.childSeatMax,
  );
}

/// Admin → Display Settings → Ride Options → Charges: whether commission is
/// charged on, and promo codes discount, the pet and assistance charges.
/// Both on unless set off (as before: the charges are part of the fare).
/// The server reads the same keys (migration 0248).
class OptionChargeRules {
  const OptionChargeRules({this.commission = true, this.promo = true});

  static const key = 'rideOptionCharges';

  final bool commission;
  final bool promo;

  static OptionChargeRules fromSettings(Map<String, dynamic> s) {
    final raw = s[key];
    if (raw is! Map) return const OptionChargeRules();
    return OptionChargeRules(commission: raw['commission'] != false, promo: raw['promo'] != false);
  }

  Map<String, Object> toSettings() => {
    key: {'commission': commission, 'promo': promo},
  };
}

/// An option's name as the ride was booked with it, when the admin had
/// renamed it; null for the built-in name or none stamped.
String? bookedOptionName(Map<String, String> stamped, RideOptionKind k) {
  final n = stamped[k.id];
  return n == null || n == k.defaultLabel ? null : n;
}
