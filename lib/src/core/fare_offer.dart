// The rider's own fare offer before booking, where bidding is on at the
// pickup (Expo `ride-confirm` −/+ buttons and `OfferFareSideSheet`). Pure.
//
// - The −/+ buttons move the fare in steps of [fareOfferStep], at most
//   [fareOfferMinAdjust] below and [fareOfferMaxAdjust] above the
//   recommended fare.
// - The keypad takes any whole amount from 70% to 400% of the recommended
//   fare.
// Both must also stay inside that 70–400% band, which the buttons alone
// would not on a short, cheap trip.

const fareOfferStep = 5.0;
const fareOfferMinAdjust = -10.0;
const fareOfferMaxAdjust = 20.0;

typedef FareOfferRange = ({double min, double max});

/// What the keypad accepts for [recommended], in whole currency units.
FareOfferRange fareOfferRange(double recommended) =>
    (min: (recommended * 0.7).roundToDouble(), max: (recommended * 4).roundToDouble());

/// The adjustment after pressing − or + ([step] is ±[fareOfferStep]), or
/// null when that would leave the allowed band (the button does nothing).
double? stepFareAdjustment(double recommended, double adjust, double step) {
  final next = adjust + step;
  if (next < fareOfferMinAdjust || next > fareOfferMaxAdjust) return null;
  final range = fareOfferRange(recommended);
  final fare = recommended + next;
  if (next != 0 && (fare < range.min || fare > range.max)) return null;
  return next;
}

/// Why [typed] can't be offered, or null when it can.
String? fareOfferProblem(double? typed, double recommended, String Function(double) money) {
  if (typed == null || typed <= 0) return 'Enter your fare';
  final range = fareOfferRange(recommended);
  if (typed < range.min) return 'Minimum fare is ${money(range.min)}';
  if (typed > range.max) return 'Maximum fare is ${money(range.max)}';
  return null;
}

/// The fare a request goes out at: the rider's offer only where bidding is
/// on, else the recommended fare. Never below zero.
double offeredFare({required double recommended, required double adjust, required bool biddingOn}) {
  final fare = biddingOn ? recommended + adjust : recommended;
  return fare < 0 ? 0 : fare;
}
