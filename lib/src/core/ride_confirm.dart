/// The confirm-ride screen's rules (Expo `app/ride-confirm.tsx`): where the
/// admin moved its floating parts, how the trip time reads beside the
/// destination, and when a driver's offer is accepted without asking. Pure.
library;

import 'ride_bidding.dart';

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
  const RideOptions({this.childSeat = false, this.morePassengers = false, this.pet = false});

  final bool childSeat;

  /// More than [standardSeats] riding.
  final bool morePassengers;

  /// A pet rides along (inDrive's "Pet with me").
  final bool pet;

  static const standardSeats = 4;

  bool get any => childSeat || morePassengers || pet;

  /// The passengers the request carries: one, or more than four.
  int get passengers => morePassengers ? standardSeats + 1 : 1;

  /// Spelled out for the driver, ahead of the note.
  List<String> get labels => [
    if (childSeat) 'Child safety seat',
    if (morePassengers) 'More than $standardSeats passengers',
    if (pet) 'Pet with me',
  ];

  RideOptions copyWith({bool? childSeat, bool? morePassengers, bool? pet}) => RideOptions(
    childSeat: childSeat ?? this.childSeat,
    morePassengers: morePassengers ?? this.morePassengers,
    pet: pet ?? this.pet,
  );

  @override
  bool operator ==(Object other) =>
      other is RideOptions && other.childSeat == childSeat && other.morePassengers == morePassengers && other.pet == pet;

  @override
  int get hashCode => Object.hash(childSeat, morePassengers, pet);
}

/// The note the driver gets: the options the rider asked for, the entrance
/// they set on the pickup (Expo's "Entrance" keypad), then their own words.
/// Null for none.
String? driverNote({String entrance = '', String note = '', RideOptions options = const RideOptions()}) {
  final parts = [
    ...options.labels,
    if (entrance.trim().isNotEmpty) 'Entrance ${entrance.trim()}',
    if (note.trim().isNotEmpty) note.trim(),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}
