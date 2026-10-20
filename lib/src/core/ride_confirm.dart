/// The confirm-ride screen's rules (Expo `app/ride-confirm.tsx`): where the
/// admin moved its floating parts, how the trip time reads beside the
/// destination, and when a driver's offer is accepted without asking. Pure.
library;

import 'ride_assistance.dart';
import 'ride_bidding.dart';
import 'ride_pets.dart';

/// Admin → Display Settings offsets for the confirm screen's floating parts
/// (Expo `rc*`, `discountBar*`), in logical pixels, and whether the promo
/// bar shows at all.
class ConfirmLayout {
  const ConfirmLayout({
    this.back = (0, 0),
    this.recenter = (0, 0),
    this.disclaimer = (0, 0),
    this.address = (0, 0),
    this.promoBar = true,
    this.promoBarOffset = 0,
    this.promoBarInFront = false,
    this.confirmAddStop = true,
    this.showCoin = true,
    this.showBookForOther = true,
    this.showMyRide = true,
    this.showAutoAccept = true,
  });

  /// (horizontal, vertical) offsets.
  final (double, double) back;
  final (double, double) recenter;
  final (double, double) disclaimer;
  final (double, double) address;
  final bool promoBar;

  /// How far the promo bar sits below its place (Expo moves it down for a
  /// positive value).
  final double promoBarOffset;

  /// Admin → Display → "Discount bar in front": the bar is drawn over the
  /// sheet, whole, instead of tucked behind its top edge.
  final bool promoBarInFront;

  /// Admin → Display → "Ask before adding a stop": a new stop's additional
  /// cost and time are shown with Add or Cancel; off, it is added at once.
  final bool confirmAddStop;

  /// Admin → Display → Ride Confirm Layout: whether the confirm sheet shows
  /// its "Use GET.coin", "Book for someone else", "My Ride" and
  /// "Auto-accept offer" rows (each still only where it applies).
  final bool showCoin;
  final bool showBookForOther;
  final bool showMyRide;
  final bool showAutoAccept;

  static ConfirmLayout fromSettings(Map<String, dynamic> s) {
    double n(String k) {
      final v = s[k];
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v.trim()) ?? 0;
      return 0;
    }

    bool flag(String k, bool d) {
      final v = s[k];
      if (v is bool) return v;
      if (v is num) return v != 0;
      if (v is String) {
        final t = v.trim().toLowerCase();
        if (t == 'false' || t == '0' || t == 'off') return false;
        if (t == 'true' || t == '1' || t == 'on') return true;
      }
      return d;
    }

    return ConfirmLayout(
      back: (n('rcBackHorizontal'), n('rcBackVertical')),
      recenter: (n('rcRecenterHorizontal'), n('rcRecenterVertical')),
      disclaimer: (n('rcDisclaimerHorizontal'), n('rcDisclaimerVertical')),
      address: (n('rcAddressHorizontal'), n('rcAddressVertical')),
      promoBar: flag('discountBar', true),
      promoBarOffset: n('discountBarHeightOffset'),
      promoBarInFront: flag('discountBarInFront', false),
      confirmAddStop: flag('addStopConfirm', true),
      showCoin: flag('confirmShowCoin', true),
      showBookForOther: flag('confirmShowBookForOther', true),
      showMyRide: flag('confirmShowMyRide', true),
      showAutoAccept: flag('confirmShowAutoAccept', true),
    );
  }
}

/// Admin → Display → Ride tracking: how far the recenter button on a trip
/// map is moved, (horizontal, vertical) — the rider's map (`rtRecenter*`) or
/// the driver's (`prRecenter*`). Positive is right / down, as in Expo.
(double, double) tripRecenterOffset(Map<String, dynamic> s, {required bool partner}) {
  double n(String k) {
    final v = s[k];
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim()) ?? 0;
    return 0;
  }

  final p = partner ? 'prRecenter' : 'rtRecenter';
  return (n('${p}Horizontal'), n('${p}Vertical'));
}

/// The trip time after the destination: "~25 min", "~1 hr, 5 min",
/// "~2 hrs" (Expo `formatTotalDuration`). Empty for no time.
String confirmDuration(double? minutes) {
  if (minutes == null || !minutes.isFinite || minutes <= 0) return '';
  final m = minutes.round().clamp(1, 1 << 30);
  if (m < 60) return '~$m min';
  final h = m ~/ 60, rest = m % 60;
  return '~$h hr${h > 1 ? 's' : ''}${rest > 0 ? ', $rest min' : ''}';
}

/// "Auto-accept offer of RM x": a driver's offer at or under the fare the
/// rider booked at is taken without asking; a higher one still asks.
bool shouldAutoAccept({required double? limit, required RideOffer? offer}) {
  if (limit == null || offer == null || !limit.isFinite) return false;
  return offer.amount <= limit + 0.005;
}

/// What the rider asks for from the Options sheet beside "Find a driver".
class RideOptions {
  const RideOptions({
    this.childSeat = false,
    this.childSeats = 1,
    this.morePassengers = false,
    this.pet = false,
    this.pets = const [],
    this.assistance,
  });

  final bool childSeat;

  /// How many child safety seats, while [childSeat] is on: 1, or up to the
  /// admin's most (Admin → Display Settings → Ride Options).
  final int childSeats;

  /// More than [standardSeats] riding.
  final bool morePassengers;

  /// A pet rides along (inDrive's "Pet with me").
  final bool pet;

  /// Which pets, from the Your pets sheet: none until it is done, and
  /// cleared when "Pet with me" is turned off.
  final List<RidePet> pets;

  /// "Assistance required": the help picked on its sheet, with the rider's
  /// note; null while it is off.
  final RideAssistance? assistance;

  static const standardSeats = 4;

  bool get any => childSeat || morePassengers || pet || assistance != null;

  /// The passengers the request carries: one, or more than four.
  int get passengers => morePassengers ? standardSeats + 1 : 1;

  /// Spelled out for the driver, ahead of the note. The pets' summary goes
  /// after "Pet with me", and the help's names after "Assistance:", so a
  /// driver app that doesn't read `pets` or `assistance` still knows what
  /// is coming. The rider's own assistance note is never in it: an open
  /// request's note is for every nearby driver.
  List<String> get labels => labelsNamed();

  /// [labels] under the admin's own names for the options (Display Settings
  /// → Ride Options), by option id ('child-seat', 'more-passengers', 'pet',
  /// 'assistance'); an option not in [names] keeps the built-in wording.
  List<String> labelsNamed([Map<String, String> names = const {}]) {
    final seat = names['child-seat'];
    return [
      if (childSeat)
        seat == null
            ? (childSeats > 1 ? '$childSeats child safety seats' : 'Child safety seat')
            : (childSeats > 1 ? '$seat: $childSeats' : seat),
      if (morePassengers) names['more-passengers'] ?? 'More than $standardSeats passengers',
      if (pet) pets.isEmpty ? names['pet'] ?? 'Pet with me' : '${names['pet'] ?? 'Pet with me'}: ${petSummary(pets)}',
      if (assistance != null && !assistance!.isEmpty)
        assistanceNoteLabel(assistance!.items, prefix: names['assistance'] ?? 'Assistance'),
    ];
  }

  RideOptions copyWith({
    bool? childSeat,
    int? childSeats,
    bool? morePassengers,
    bool? pet,
    List<RidePet>? pets,
    RideAssistance? assistance,
    bool clearAssistance = false,
  }) => RideOptions(
    childSeat: childSeat ?? this.childSeat,
    childSeats: childSeats ?? this.childSeats,
    morePassengers: morePassengers ?? this.morePassengers,
    pet: pet ?? this.pet,
    pets: pets ?? this.pets,
    assistance: clearAssistance ? null : (assistance ?? this.assistance),
  );

  @override
  bool operator ==(Object other) =>
      other is RideOptions &&
      other.childSeat == childSeat &&
      other.childSeats == childSeats &&
      other.morePassengers == morePassengers &&
      other.pet == pet &&
      samePets(other.pets, pets) &&
      other.assistance == assistance;

  @override
  int get hashCode => Object.hash(childSeat, childSeats, morePassengers, pet, Object.hashAll(pets), assistance);
}

/// The note the driver gets: the options the rider asked for, the entrance
/// they set on the pickup (Expo's "Entrance" keypad), then their own words.
/// Null for none.
/// [names]: the admin's own names for the options, by option id.
String? driverNote({
  String entrance = '',
  String note = '',
  RideOptions options = const RideOptions(),
  Map<String, String> names = const {},
}) {
  final parts = [
    ...options.labelsNamed(names),
    if (entrance.trim().isNotEmpty) 'Entrance ${entrance.trim()}',
    if (note.trim().isNotEmpty) note.trim(),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}
