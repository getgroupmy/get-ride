/// What the rider's pets and the assistance they ask for add to the fare
/// (Admin → Display Settings → Ride Options → charges, all zero until set).
/// The charges go into the fare itself, as quoted on the vehicle cards and
/// booked, so a promo code and the commission apply to the total as they
/// do to any fare. They are stamped on the ride (`option_charges`,
/// migration 0248) so the driver and admins see what the fare includes.
/// Pure.
library;

import 'option_charge.dart';
import 'ride_assistance.dart';
import 'ride_confirm.dart' show RideOptions;
import 'ride_pets.dart';

/// One line of it: "Pet charge", RM10.
class OptionChargeLine {
  const OptionChargeLine({required this.kind, required this.name, required this.amount});

  /// 'pet' or 'assistance'.
  final String kind;
  final String name;
  final double amount;

  static const petName = 'Pet charge';
  static const assistanceName = 'Assistance charge';

  Map<String, Object> toJson() => {'kind': kind, 'name': name, 'amount': amount};

  static OptionChargeLine? fromJson(Object? v) {
    if (v is! Map) return null;
    final name = v['name'] is String ? (v['name'] as String).trim() : '';
    final a = v['amount'];
    final amount = a is num ? a.toDouble() : (a is String ? double.tryParse(a) : null);
    if (name.isEmpty || amount == null || !amount.isFinite || amount <= 0) return null;
    return OptionChargeLine(kind: v['kind'] is String ? v['kind'] as String : '', name: name, amount: cents(amount));
  }

  @override
  bool operator ==(Object other) =>
      other is OptionChargeLine && other.kind == kind && other.name == name && other.amount == amount;

  @override
  int get hashCode => Object.hash(kind, name, amount);
}

/// What [pets] add to [fare] (the route's fare before any option): each
/// type's charge, per pet or once for the ride, plus each pet's size extra.
double petChargeFor(List<RidePet> pets, double fare, PetConfig config) {
  var total = 0.0;
  for (final e in petsByType(pets).entries) {
    final c = config.chargeFor(e.key);
    if (!c.isZero) total += c.perPet ? c.charge.on(fare) * e.value.length : c.charge.on(fare);
    for (final p in e.value) {
      total += config.sizeExtraFor(p.size);
    }
  }
  return cents(total);
}

/// What the help in [items] adds to [fare]: each item's charge as the
/// admin set it now (the guide dog's is always none). An item the admin
/// has since removed adds nothing.
double assistanceChargeFor(List<AssistancePick> items, double fare, AssistanceCatalogue catalogue) {
  var total = 0.0;
  for (final p in items) {
    total += catalogue.byId(p.id)?.effectiveCharge.on(fare) ?? 0;
  }
  return cents(total);
}

/// The lines [options] add to [fare]; none for nothing charged.
List<OptionChargeLine> rideOptionCharges(
  RideOptions options,
  double fare, {
  PetConfig pets = const PetConfig(),
  AssistanceCatalogue assistance = const AssistanceCatalogue(),
}) {
  final pet = options.pet ? petChargeFor(options.pets, fare, pets) : 0.0;
  final help = options.assistance == null ? 0.0 : assistanceChargeFor(options.assistance!.items, fare, assistance);
  return [
    if (pet > 0) OptionChargeLine(kind: 'pet', name: OptionChargeLine.petName, amount: pet),
    if (help > 0) OptionChargeLine(kind: 'assistance', name: OptionChargeLine.assistanceName, amount: help),
  ];
}

double optionChargesTotal(List<OptionChargeLine> lines) => cents(lines.fold(0.0, (a, l) => a + l.amount));

/// "Pet charge RM10 · Assistance charge RM5", with [money] for each amount;
/// null for none.
String? optionChargesText(List<OptionChargeLine> lines, String Function(double amount) money) =>
    lines.isEmpty ? null : [for (final l in lines) '${l.name} ${money(l.amount)}'].join(' · ');

/// The lines on a ride row (`option_charges`); none for anything else.
List<OptionChargeLine> parseOptionCharges(Object? raw) => [
  if (raw is List)
    for (final e in raw) ?OptionChargeLine.fromJson(e),
];
