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

  static ConfirmLayout fromSettings(Map<String, dynamic> s) {
    double n(String k) {
      final v = s[k];
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v.trim()) ?? 0;
      return 0;
    }

    final bar = s['discountBar'];
    return ConfirmLayout(
      back: (n('rcBackHorizontal'), n('rcBackVertical')),
      recenter: (n('rcRecenterHorizontal'), n('rcRecenterVertical')),
      disclaimer: (n('rcDisclaimerHorizontal'), n('rcDisclaimerVertical')),
      address: (n('rcAddressHorizontal'), n('rcAddressVertical')),
      promoBar: bar is bool ? bar : !(bar == 0 || bar == 'false' || bar == '0'),
      promoBarOffset: n('discountBarHeightOffset'),
    );
  }
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

/// The note the driver gets: the entrance the rider set on the pickup
/// (Expo's "Entrance" keypad), then their own words. Null for neither.
String? driverNote({String entrance = '', String note = ''}) {
  final parts = [
    if (entrance.trim().isNotEmpty) 'Entrance ${entrance.trim()}',
    if (note.trim().isNotEmpty) note.trim(),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}
