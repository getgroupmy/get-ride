/// The ride extras a driver takes (Settings → Ride extras I take; migration
/// 0253): each pet type, each kind of help, a child safety seat and more
/// passengers, all on until the driver turns one off. A request carrying an
/// extra the driver turned off is never offered to them (the server keeps
/// it from their feed and pushes). The keys match the server's
/// `ride_extra_keys`. Pure.
library;

import 'ride_assistance.dart';
import 'ride_confirm.dart' show RideOptions;
import 'ride_option_settings.dart';
import 'ride_pets.dart';

abstract final class RideExtraKey {
  static const childSeat = 'child-seat';
  static const morePassengers = 'more-passengers';
  static String pet(String type) => 'pet:${type.trim().toLowerCase()}';
  static String assist(String id) => 'assist:${id.trim().toLowerCase()}';
}

/// One extra on a request: its key, the line the driver reads ("Pet with
/// me: Dog ×2 (M, L)") and its short name ("Dog", for "Stop showing Dog
/// rides").
class RideExtra {
  const RideExtra({required this.key, required this.line, required this.label});

  final String key;
  final String line;
  final String label;

  @override
  bool operator ==(Object other) => other is RideExtra && other.key == key && other.line == line && other.label == label;

  @override
  int get hashCode => Object.hash(key, line, label);
}

/// The extras a request carries, as it was booked: [names] are the names
/// the options were booked under (`option_names`).
List<RideExtra> rideExtrasOf({
  List<RidePet> pets = const [],
  RideAssistance? assistance,
  Map<String, String> names = const {},
  int passengers = 1,
}) {
  String nameOf(RideOptionKind k) => names[k.id] ?? k.defaultLabel;
  final out = <RideExtra>[];
  if (names.containsKey(RideOptionKind.childSeat.id)) {
    out.add(RideExtra(
      key: RideExtraKey.childSeat,
      line: nameOf(RideOptionKind.childSeat),
      label: RideOptionKind.childSeat.defaultLabel,
    ));
  }
  if (names.containsKey(RideOptionKind.morePassengers.id) || passengers > RideOptions.standardSeats) {
    out.add(RideExtra(
      key: RideExtraKey.morePassengers,
      line: nameOf(RideOptionKind.morePassengers),
      label: RideOptionKind.morePassengers.defaultLabel,
    ));
  }
  final petName = nameOf(RideOptionKind.pet);
  for (final e in petsByType(pets).entries) {
    final sizes = [for (final p in e.value) ?p.size];
    out.add(RideExtra(
      key: RideExtraKey.pet(e.key),
      line: '$petName: ${e.key} ×${e.value.length}${sizes.isEmpty ? '' : ' (${sizes.join(', ')})'}',
      label: e.key,
    ));
  }
  final helpName = names[RideOptionKind.assistance.id] ?? 'Assistance';
  for (final i in assistance?.items ?? const <AssistancePick>[]) {
    final key = RideExtraKey.assist(i.id);
    if (out.any((x) => x.key == key)) continue;
    out.add(RideExtra(key: key, line: '$helpName: ${i.label}', label: i.name));
  }
  return out;
}

/// Whether a driver who turned [off] off takes a request with [extras].
bool driverTakes(Set<String> off, Iterable<RideExtra> extras) => !extras.any((x) => off.contains(x.key));

/// A switch on the driver's "Ride extras I take" page.
typedef RideExtraSwitch = ({String key, String label});

/// The switches, by option in the admin's order: a child safety seat, more
/// passengers, each pet type and each kind of help offered. Options the
/// admin hides from riders are left out.
List<({RideOptionKind option, String title, List<RideExtraSwitch> items})> rideExtraGroups(
  RideOptionsConfig config,
  PetConfig pets,
  AssistanceCatalogue help,
) => [
  for (final k in config.order)
    if (config.isShown(k))
      (
        option: k,
        title: config.labelOf(k),
        items: switch (k) {
          RideOptionKind.childSeat => [(key: RideExtraKey.childSeat, label: config.labelOf(k))],
          RideOptionKind.morePassengers => [(key: RideExtraKey.morePassengers, label: config.labelOf(k))],
          RideOptionKind.pet => [for (final t in pets.types) (key: RideExtraKey.pet(t), label: t)],
          RideOptionKind.assistance => [
            for (final i in help.visible) (key: RideExtraKey.assist(i.id), label: i.name),
          ],
        },
      ),
];

/// The feed's line for [n] requests left out; null for none.
String? hiddenExtrasText(int n) => n <= 0
    ? null
    : '$n ${n == 1 ? 'request' : 'requests'} not shown: ${n == 1 ? 'it includes' : 'they include'} an extra you '
          'turned off.';

/// The admin's read-only list: each key turned off, by its name where the
/// catalogue still has it.
List<String> describeExtrasOff(Set<String> off, RideOptionsConfig config, PetConfig pets, AssistanceCatalogue help) {
  final names = <String, String>{
    RideExtraKey.childSeat: config.labelOf(RideOptionKind.childSeat),
    RideExtraKey.morePassengers: config.labelOf(RideOptionKind.morePassengers),
    for (final t in pets.types) RideExtraKey.pet(t): '${config.labelOf(RideOptionKind.pet)}: $t',
    for (final i in help.items) RideExtraKey.assist(i.id): '${config.labelOf(RideOptionKind.assistance)}: ${i.name}',
  };
  return [for (final k in (off.toList()..sort())) names[k] ?? k];
}
