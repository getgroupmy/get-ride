// What the rider's search sheet says while drivers are found (inDrive's):
// the headline that cycles through the search's stages, and the fare stepper
// a raise is picked on before it is confirmed. Pure.
import 'dart:math' as math;

import 'ride_bidding.dart';

/// One line of the searching headline.
typedef SearchStage = ({String id, String title, String subtitle});

/// The stages inDrive cycles through while a request is out. The first one
/// carries the "All drivers verified" shield.
const searchStages = <SearchStage>[
  (id: 'searching', title: 'Searching for drivers', subtitle: 'All drivers verified'),
  (id: 'offering', title: 'Offering your fare', subtitle: 'Drivers nearby can see your price'),
  (id: 'waiting', title: 'Waiting for responses', subtitle: 'You choose your driver'),
  (id: 'further', title: 'Searching further', subtitle: 'Expanding search area'),
];

/// How long each stage stays up before the next.
const searchStageEvery = Duration(seconds: 5);

/// The stage shown [elapsed] into the search.
SearchStage searchStageAt(Duration elapsed) {
  final i = elapsed.isNegative ? 0 : elapsed.inMilliseconds ~/ searchStageEvery.inMilliseconds;
  return searchStages[i % searchStages.length];
}

double _round2(double v) => (v * 100).roundToDouble() / 100;

/// The search sheet's −/+ keys: [target] moved by [step]. Up is capped like
/// any raise ([raisedFare]); down never goes under the fare already
/// offered ([current]), since a request's fare is only ever raised.
double stepSearchFare({required double current, required double target, required double step, required double quoted}) {
  if (step > 0) return raisedFare(target, step, quoted: quoted);
  return math.max(current, _round2(target + step));
}
