// The trip card: a trip's progress outside the app, on the lock screen. An
// iPhone shows it as a Live Activity (lock screen and Dynamic Island), an
// Android phone as a pinned notification with a progress bar
// (data/trip_card_controller.dart starts, moves and ends it; the native
// sides draw it). Riders see five stages: finding a driver, on the way,
// arrived, on the trip, done. Drivers get their own card for the trip they
// are on. Admin → Display Settings → Trip card switches it per service and
// sets how long the done card stays; App Page Settings sets its colours.
//
// Pure: everything here is built from the ride row, the driver's live
// position and the road route the trip map already fetched.
import 'dart:math' as math;

import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../data/models.dart';
import 'driver_eta.dart';
import 'format.dart';
import 'live_eta.dart';

/// Where the trip is.
enum TripCardStage {
  finding,
  toPickup,
  arrived,
  onTrip,
  done;

  /// The stage a ride in [status] is at; null once there is nothing to show
  /// (cancelled, no driver found).
  static TripCardStage? of(RideStatus status) => switch (status) {
    RideStatus.open => finding,
    RideStatus.accepted => toPickup,
    RideStatus.arrived => arrived,
    RideStatus.onTrip => onTrip,
    RideStatus.completed => done,
    RideStatus.cancelled || RideStatus.expired => null,
  };
}

/// Which service the trip is: a ride, a courier parcel or a freight move.
/// Courier is built on Freight's parts, so it is asked first.
enum TripCardService {
  ride,
  courier,
  freight;

  static TripCardService of(RideRequest r) => r.isCourier
      ? courier
      : r.isFreight
      ? freight
      : ride;
}

/// A button on the card. Each opens the app where that already happens:
/// the ride's call, its chat, the share-trip link, the SOS sheet, the
/// cancel question, or the trip itself (to rate it).
enum TripCardAction {
  call('Call'),
  chat('Chat'),
  share('Share trip'),
  sos('SOS'),
  cancel('Cancel'),
  rate('Rate');

  const TripCardAction(this.label);
  final String label;

  static TripCardAction? parse(String? s) {
    for (final a in values) {
      if (a.name == s) return a;
    }
    return null;
  }
}

/// Android shows at most three buttons on a notification.
const tripCardMaxActions = 3;

/// The card as the phone shows it.
class TripCard {
  const TripCard({
    required this.rideId,
    required this.stage,
    required this.service,
    required this.isDriver,
    required this.chip,
    required this.compact,
    required this.headline,
    this.emphasis,
    this.subline = '',
    this.driverName,
    this.car,
    this.plate,
    this.footTitle,
    this.footText,
    required this.progress,
    this.eta,
    this.minutesLeft,
    this.kmLeft,
    this.actions = const [],
  });

  final String rideId;
  final TripCardStage stage;
  final TripCardService service;

  /// The driver's own card rather than the rider's.
  final bool isDriver;

  /// The short status in the corner ("6 min", "Arrived", "Done").
  final String chip;

  /// What the smallest view shows (the Dynamic Island's right side, the
  /// status bar chip): minutes or the arrival time.
  final String compact;

  /// The big line, and the part of it drawn in the accent colour.
  final String headline;
  final String? emphasis;
  final String subline;

  /// The driver and their car while they come to the pickup (the rider's
  /// card only).
  final String? driverName;
  final String? car;
  final String? plate;

  /// The line under the bar ("How was your ride?" / "Tap to rate Ali").
  final String? footTitle;
  final String? footText;

  /// How far along the trip is, 0 to 1, for the bar and its car.
  final double progress;

  /// When the driver reaches the pickup (on the way) or the drop (on the
  /// trip); null when unknown.
  final DateTime? eta;
  final int? minutesLeft;
  final double? kmLeft;

  final List<TripCardAction> actions;

  bool get isDone => stage == TripCardStage.done;

  TripCard copyWith({double? progress}) => TripCard(
    rideId: rideId,
    stage: stage,
    service: service,
    isDriver: isDriver,
    chip: chip,
    compact: compact,
    headline: headline,
    emphasis: emphasis,
    subline: subline,
    driverName: driverName,
    car: car,
    plate: plate,
    footTitle: footTitle,
    footText: footText,
    progress: progress ?? this.progress,
    eta: eta,
    minutesLeft: minutesLeft,
    kmLeft: kmLeft,
    actions: actions,
  );

  /// What the native side is handed (MethodChannel `getride/trip_card`),
  /// without the values it doesn't have. [clearAfter] is how long the done
  /// card stays (a push may end the trip while the app is closed).
  Map<String, Object?> toPlatform({required TripCardColors light, required TripCardColors dark, Duration? clearAfter}) =>
      <String, Object?>{
        'rideId': rideId,
        'role': isDriver ? 'driver' : 'rider',
        'service': service.name,
        'stage': stage.name,
        'brand': 'GET.ride',
        'chip': chip,
        'compact': compact,
        'headline': headline,
        'emphasis': emphasis,
        'subline': subline,
        'driverName': driverName,
        'car': car,
        'plate': plate,
        'footTitle': footTitle,
        'footText': footText,
        'progress': progress,
        'etaMs': eta?.millisecondsSinceEpoch,
        'minutesLeft': minutesLeft,
        'openUri': tripCardLink(rideId, driver: isDriver).toString(),
        'actions': [
          for (final a in actions)
            {'id': a.name, 'label': a.label, 'uri': tripCardLink(rideId, driver: isDriver, action: a).toString()},
        ],
        'ongoing': !isDone,
        'clearAfterMs': clearAfter?.inMilliseconds,
        'colors': {'light': light.toPlatform(), 'dark': dark.toPlatform()},
      }..removeWhere((_, v) => v == null);

  @override
  bool operator ==(Object other) =>
      other is TripCard &&
      other.rideId == rideId &&
      other.stage == stage &&
      other.headline == headline &&
      other.subline == subline &&
      other.chip == chip &&
      other.progress == progress &&
      other.footText == footText;

  @override
  int get hashCode => Object.hash(rideId, stage, headline, subline, chip, progress, footText);

  @override
  String toString() => 'TripCard($rideId, $stage, "$headline", ${progress.toStringAsFixed(2)})';
}

/// The card's colours (App Page Settings → Trip card), as ARGB.
class TripCardColors {
  const TripCardColors({
    this.background = 0xFF000000,
    this.accent = 0xFF2DABE2,
    this.text = 0xFFFFFFFF,
    this.muted = 0xFFA9B6C0,
  });

  final int background, accent, text, muted;

  Map<String, int> toPlatform() => {'background': background, 'accent': accent, 'text': text, 'muted': muted};

  @override
  bool operator ==(Object other) =>
      other is TripCardColors &&
      other.background == background &&
      other.accent == accent &&
      other.text == text &&
      other.muted == muted;

  @override
  int get hashCode => Object.hash(background, accent, text, muted);
}

/// Admin → Display Settings → Trip card, kept in the display settings blob
/// under [tripCardSettingsKey]. Missing means on, with the done card
/// staying [defaultDoneMinutes].
class TripCardSettings {
  const TripCardSettings({
    this.ride = true,
    this.courier = true,
    this.freight = true,
    this.driver = true,
    this.doneMinutes = defaultDoneMinutes,
  });

  final bool ride, courier, freight;

  /// Drivers get a card of their own (for the services switched on).
  final bool driver;

  /// How long the done card stays after the trip ends; 0 clears it at once.
  final int doneMinutes;

  static const defaultDoneMinutes = 5;
  static const maxDoneMinutes = 60;

  factory TripCardSettings.fromDisplay(Map<String, dynamic> blob) {
    final raw = blob[tripCardSettingsKey];
    final m = raw is Map ? raw : const {};
    bool on(String k) => m[k] is bool ? m[k] as bool : true;
    final done = m['doneMinutes'];
    return TripCardSettings(
      ride: on('ride'),
      courier: on('courier'),
      freight: on('freight'),
      driver: on('driver'),
      doneMinutes: done is num ? done.round().clamp(0, maxDoneMinutes) : defaultDoneMinutes,
    );
  }

  Map<String, Object> toJson() => {
    'ride': ride,
    'courier': courier,
    'freight': freight,
    'driver': driver,
    'doneMinutes': doneMinutes,
  };

  TripCardSettings copyWith({bool? ride, bool? courier, bool? freight, bool? driver, int? doneMinutes}) =>
      TripCardSettings(
        ride: ride ?? this.ride,
        courier: courier ?? this.courier,
        freight: freight ?? this.freight,
        driver: driver ?? this.driver,
        doneMinutes: (doneMinutes ?? this.doneMinutes).clamp(0, maxDoneMinutes),
      );

  /// Whether a card shows for [service], on the driver's phone when [asDriver].
  bool allows(TripCardService service, {required bool asDriver}) {
    if (asDriver && !driver) return false;
    return switch (service) {
      TripCardService.ride => ride,
      TripCardService.courier => courier,
      TripCardService.freight => freight,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is TripCardSettings &&
      other.ride == ride &&
      other.courier == courier &&
      other.freight == freight &&
      other.driver == driver &&
      other.doneMinutes == doneMinutes;

  @override
  int get hashCode => Object.hash(ride, courier, freight, driver, doneMinutes);
}

/// The display settings blob's key for [TripCardSettings].
const tripCardSettingsKey = 'tripCard';

/// [blob] with the trip card settings set to [s].
Map<String, dynamic> withTripCardSettings(Map<String, dynamic> blob, TripCardSettings s) => {
  ...blob,
  tripCardSettingsKey: s.toJson(),
};

/// The road route the trip map last fetched for a ride (live_ride_map.dart):
/// where it goes, its line, and its time and distance.
class TripRouteFix {
  const TripRouteFix({required this.target, required this.points, required this.minutes, required this.km});

  final LatLng target;
  final List<LatLng> points;
  final double minutes;
  final double km;
}

const _distance = Distance();

LatLng? _ll(double? lat, double? lng) => lat == null || lng == null ? null : LatLng(lat, lng);

double _km(LatLng a, LatLng b) => _distance(a, b) / 1000;

/// Where the driver is: their live position, else (on the way) where they
/// accepted.
LatLng? tripDriverAt(RideRequest r) =>
    _ll(r.partnerLiveLat, r.partnerLiveLng) ??
    (r.status == RideStatus.accepted ? _ll(r.partnerAcceptLat, r.partnerAcceptLng) : null);

/// The average speed assumed on the trip when the ride has no time and
/// distance of its own.
const tripFallbackKmh = 30.0;

/// Minutes and kilometres to the driver's next point (the pickup on the way,
/// the drop on the trip): along the trip map's road [route] when it goes
/// there, as the map's ETA pill counts it (live_eta.dart); else in a
/// straight line, at [driverApproachKmh] to the pickup or at the ride's own
/// pace (its booked distance over its booked time) to the drop. Null when
/// the driver or the target is unknown, or the stage has no target.
({double minutes, double km})? tripEta(RideRequest r, {TripRouteFix? route, LatLng? driver}) {
  final pickup = _ll(r.pickupLat, r.pickupLng), drop = _ll(r.dropLat, r.dropLng);
  final target = etaTarget(r.status, pickup: pickup, drop: drop);
  final at = driver ?? tripDriverAt(r);
  if (target == null || at == null) return null;
  if (route != null && route.points.length >= 2 && _distance(route.target, target) < 50) {
    final ahead = routeAhead(route.points, at);
    if (ahead == null) return (minutes: route.minutes, km: route.km);
    return etaAhead(routeMinutes: route.minutes, routeKm: route.km, route: route.points, ahead: ahead.points);
  }
  final straight = _km(at, target);
  if (r.status == RideStatus.accepted) {
    final m = approachMinutes(driverLat: at.latitude, driverLng: at.longitude, pickupLat: target.latitude, pickupLng: target.longitude);
    return (minutes: (m ?? 1).toDouble(), km: straight);
  }
  // On the trip: the straight line stretched to the road by the ride's own
  // booked route.
  final whole = pickup == null ? null : _km(pickup, target);
  final booked = r.distanceKm;
  final factor = booked != null && whole != null && whole > 0.05 ? (booked / whole).clamp(1.0, 2.0) : 1.3;
  final km = straight * factor;
  final mins = r.durationMin;
  final kmh = booked != null && mins != null && booked > 0 && mins > 0 ? booked / mins * 60 : tripFallbackKmh;
  return (minutes: km / kmh * 60, km: km);
}

/// How much of the current stage is done, 0 to 1: on the way, the share of
/// the distance from where the driver accepted to the pickup they have
/// covered; on the trip, the share of the route's kilometres driven.
double tripStageFraction(RideRequest r, {double? kmLeft, LatLng? driver}) {
  switch (r.status) {
    case RideStatus.accepted:
      final pickup = _ll(r.pickupLat, r.pickupLng);
      final from = _ll(r.partnerAcceptLat, r.partnerAcceptLng);
      final at = driver ?? tripDriverAt(r);
      if (pickup == null || from == null || at == null) return 0;
      final start = _km(from, pickup);
      if (start <= 0.02) return 1;
      return (1 - _km(at, pickup) / start).clamp(0.0, 1.0);
    case RideStatus.onTrip:
      final pickup = _ll(r.pickupLat, r.pickupLng), drop = _ll(r.dropLat, r.dropLng);
      final total = r.distanceKm ?? (pickup == null || drop == null ? null : _km(pickup, drop));
      if (total == null || total <= 0 || kmLeft == null) return 0;
      return (1 - kmLeft / total).clamp(0.0, 1.0);
    case RideStatus.completed:
      return 1;
    default:
      return 0;
  }
}

/// Where each stage sits on the one bar: the search near the start, the
/// way to the pickup up to the arrival mark, the trip across the rest.
double tripCardProgress(TripCardStage stage, double fraction) {
  final f = fraction.clamp(0.0, 1.0);
  return switch (stage) {
    TripCardStage.finding => 0.04,
    TripCardStage.toPickup => 0.05 + 0.40 * f,
    TripCardStage.arrived => 0.45,
    TripCardStage.onTrip => 0.5 + 0.5 * f,
    TripCardStage.done => 1.0,
  };
}

/// Progress only moves forward within a stage: a GPS fix that jumps back
/// does not drag the car back along the bar.
double monotonicProgress(double? before, double next, {required bool sameStage}) =>
    sameStage && before != null ? math.max(before, next) : next;

String _first(String? name) {
  final first = (name ?? '').trim().split(RegExp(r'\s+')).first;
  return first.isEmpty ? '' : first;
}

String _clock(DateTime t) => DateFormat('h:mm').format(t.toLocal());

String _parcel(String? size) => switch ((size ?? '').toUpperCase()) {
  'S' => 'Small parcel',
  'M' => 'Medium parcel',
  'L' => 'Large parcel',
  _ => 'Parcel',
};

String _join(Iterable<String?> parts) => [
  for (final p in parts)
    if (p != null && p.trim().isNotEmpty) p.trim(),
].join(' · ');

String _left(int? mins, double? km) => _join([
  if (mins != null) '$mins min',
  if (km != null) '${formatDistance(km)} left',
]);

String _paid(RideRequest r) {
  final amount = r.totalDue ?? r.effectiveFare;
  return _join([if (amount != null) formatMoney(amount, r.currency), r.paymentMode]);
}

/// The card for [ride] at [now], for its rider or, with [asDriver], its
/// driver. [eta] is [tripEta]'s answer; [fraction] how much of the stage is
/// done ([tripStageFraction]). Null when the ride has nothing to show
/// (cancelled, expired, or a driver's card before they took it).
///
/// The courier's delivery code and the trip code are never on it: anyone
/// holding the phone can read a lock screen.
TripCard? buildTripCard(
  RideRequest ride, {
  required bool asDriver,
  required DateTime now,
  ({double minutes, double km})? eta,
  double fraction = 0,
}) {
  final stage = TripCardStage.of(ride.status);
  if (stage == null) return null;
  if (asDriver && stage == TripCardStage.finding) return null;
  final service = TripCardService.of(ride);
  final mins = eta?.minutes.ceil().clamp(1, 24 * 60);
  final at = mins == null ? null : now.add(Duration(minutes: mins));
  final km = eta?.km;
  final driverName = _first(ride.partnerName).isEmpty ? 'Your driver' : _first(ride.partnerName);
  // The person in the car: the passenger booked for, else the rider.
  final rider = _first(ride.passengerName).isEmpty ? 'Passenger' : _first(ride.passengerName);
  final progress = tripCardProgress(stage, fraction);
  final route = '${ride.pickupLabel} to ${ride.dropLabel}';

  TripCard card({
    required String chip,
    String? compact,
    required String headline,
    String? emphasis,
    String subline = '',
    bool withDriver = false,
    String? footTitle,
    String? footText,
    List<TripCardAction> actions = const [],
  }) => TripCard(
    rideId: ride.id,
    stage: stage,
    service: service,
    isDriver: asDriver,
    chip: chip,
    compact: compact ?? chip,
    headline: headline,
    emphasis: emphasis,
    subline: subline,
    driverName: withDriver ? driverName : null,
    car: withDriver ? ride.partnerVehicle : null,
    plate: withDriver ? ride.partnerPlate : null,
    footTitle: footTitle,
    footText: footText,
    progress: progress,
    eta: at,
    minutesLeft: mins,
    kmLeft: km,
    actions: actions.take(tripCardMaxActions).toList(),
  );

  final minChip = mins == null ? null : '$mins min';
  final clock = at == null ? null : formatTime(at);

  if (asDriver) {
    const talk = [TripCardAction.call, TripCardAction.chat, TripCardAction.sos];
    return switch (stage) {
      TripCardStage.toPickup => card(
        chip: minChip ?? 'On the way',
        headline: switch (service) {
          TripCardService.ride => mins == null ? 'Pick up $rider' : 'Pick up $rider in $mins min',
          TripCardService.courier => mins == null ? 'Collect the parcel' : 'Collect the parcel in $mins min',
          TripCardService.freight => mins == null ? 'Go to the loading point' : 'Loading point in $mins min',
        },
        emphasis: minChip,
        subline: _join([ride.pickupLabel, if (km != null) formatDistance(km)]),
        actions: talk,
      ),
      TripCardStage.arrived => card(
        chip: 'Waiting',
        headline: switch (service) {
          TripCardService.ride => 'Waiting for $rider',
          TripCardService.courier => 'Collect the parcel from $rider',
          TripCardService.freight => 'Loading the cargo',
        },
        emphasis: service == TripCardService.freight ? null : rider,
        subline: 'At ${ride.pickupDoor ?? ride.pickupLabel}',
        actions: talk,
      ),
      TripCardStage.onTrip => card(
        chip: clock ?? 'On trip',
        compact: at == null ? 'On trip' : _clock(at),
        headline: clock == null
            ? (service == TripCardService.ride ? 'On the way to the drop-off' : 'On the way to deliver')
            : switch (service) {
                TripCardService.ride => 'Drop-off at $clock',
                TripCardService.courier => 'Delivery at $clock',
                TripCardService.freight => 'Drop-off at $clock',
              },
        emphasis: clock,
        subline: _join([_left(mins, km), ride.dropLabel]),
        actions: talk,
      ),
      TripCardStage.done => card(
        chip: 'Done',
        headline: switch (service) {
          TripCardService.ride => 'Trip complete',
          TripCardService.courier => 'Parcel delivered',
          TripCardService.freight => 'Cargo delivered',
        },
        subline: _paid(ride),
      ),
      TripCardStage.finding => null,
    };
  }

  const coming = [TripCardAction.call, TripCardAction.chat, TripCardAction.share];
  switch (stage) {
    case TripCardStage.finding:
      return card(
        chip: 'Finding',
        headline: switch (service) {
          TripCardService.ride => 'Looking for a driver',
          TripCardService.courier => 'Looking for a courier',
          TripCardService.freight => 'Looking for a van or lorry',
        },
        subline: switch (service) {
          TripCardService.courier => _join([_parcel(ride.parcelSize), ride.service]),
          _ => ride.service ?? (service == TripCardService.freight ? 'Freight' : 'Ride'),
        },
        footTitle: route,
        footText: 'Offers will show here',
        actions: const [TripCardAction.cancel],
      );
    case TripCardStage.toPickup:
      return card(
        chip: minChip ?? 'On the way',
        headline: switch (service) {
          TripCardService.ride => mins == null ? '$driverName is on the way' : '$driverName is $mins min away',
          TripCardService.courier =>
            mins == null ? '$driverName is coming for the parcel' : '$driverName picks up in $mins min',
          TripCardService.freight => mins == null ? '$driverName is coming to load' : '$driverName loads in $mins min',
        },
        emphasis: minChip,
        subline: ride.partnerVehicle ?? '',
        withDriver: true,
        actions: coming,
      );
    case TripCardStage.arrived:
      return switch (service) {
        TripCardService.ride => card(
          chip: 'Arrived',
          compact: 'Here',
          headline: '$driverName has arrived',
          emphasis: 'arrived',
          subline: 'Meet at ${ride.pickupDoor ?? ride.pickupLabel}',
          withDriver: true,
          actions: coming,
        ),
        TripCardService.courier => card(
          chip: 'Arrived',
          compact: 'Here',
          headline: '$driverName is at the pickup',
          emphasis: 'at the pickup',
          subline: 'Hand over the parcel',
          withDriver: true,
          actions: coming,
        ),
        TripCardService.freight => card(
          chip: 'Loading',
          compact: 'Load',
          headline: 'Loading your cargo',
          subline: '$driverName is at the loading point',
          withDriver: true,
          actions: coming,
        ),
      };
    case TripCardStage.onTrip:
      final started = ride.startedAt;
      return switch (service) {
        TripCardService.ride => card(
          chip: 'On trip',
          compact: at == null ? 'On trip' : _clock(at),
          headline: clock == null ? 'You are on your way' : 'You will arrive at $clock',
          emphasis: clock,
          subline: _left(mins, km),
          footTitle: 'Share your trip',
          footText: 'Family can follow you live',
          actions: const [TripCardAction.share, TripCardAction.sos, TripCardAction.chat],
        ),
        TripCardService.courier => card(
          chip: 'On the way',
          compact: at == null ? 'On way' : _clock(at),
          headline: clock == null ? 'Parcel on the way' : 'Delivers at $clock',
          emphasis: clock,
          subline: started == null ? 'Parcel picked up' : 'Parcel picked up at ${formatTime(started)}',
          actions: coming,
        ),
        TripCardService.freight => card(
          chip: 'On the way',
          compact: at == null ? 'On way' : _clock(at),
          headline: clock == null ? 'Cargo on the way' : 'Arrives at $clock',
          emphasis: clock,
          subline: _left(null, km),
          actions: coming,
        ),
      };
    case TripCardStage.done:
      final ended = ride.completedAt;
      return switch (service) {
        TripCardService.ride => card(
          chip: 'Done',
          headline: 'You have arrived',
          subline: _paid(ride),
          footTitle: 'How was your ride?',
          footText: 'Tap to rate $driverName',
          actions: const [TripCardAction.rate],
        ),
        TripCardService.courier => card(
          chip: 'Done',
          headline: 'Parcel delivered',
          subline: _join([
            ride.recipientName == null ? 'Delivered' : 'Received by ${ride.recipientName}',
            if (ended != null) formatTime(ended),
          ]),
          footTitle: 'How was the delivery?',
          footText: 'Tap to rate $driverName',
          actions: const [TripCardAction.rate],
        ),
        TripCardService.freight => card(
          chip: 'Done',
          headline: 'Cargo delivered',
          subline: _paid(ride),
          footTitle: 'How was the move?',
          footText: 'Tap to rate $driverName',
          actions: const [TripCardAction.rate],
        ),
      };
  }
}

/// Whether to send the card to the phone now: always on a new stage,
/// otherwise no more often than [every] (the native card redraws itself
/// for each update, and an update a second wastes battery).
bool tripCardSendDue({
  required DateTime now,
  DateTime? lastSentAt,
  TripCardStage? lastStage,
  required TripCardStage stage,
  Duration every = tripCardUpdateEvery,
}) => lastSentAt == null || lastStage != stage || now.difference(lastSentAt) >= every;

/// The card's updates are at most this often within a stage.
const tripCardUpdateEvery = Duration(seconds: 15);

/// When the done card of a trip that ended at [completedAt] goes: [doneMinutes]
/// after it ended (or after [now] when the end time is unknown).
DateTime tripCardDoneUntil({DateTime? completedAt, required DateTime now, required int doneMinutes}) =>
    (completedAt ?? now).add(Duration(minutes: doneMinutes));

/// The link each part of the card opens: `getride://trip/<ride>`, with the
/// button's action (`?do=call`) and, on a driver's card, `as=driver`.
Uri tripCardLink(String rideId, {required bool driver, TripCardAction? action}) {
  final query = {'do': ?action?.name, if (driver) 'as': 'driver'};
  return Uri(scheme: 'getride', host: 'trip', pathSegments: [rideId], queryParameters: query.isEmpty ? null : query);
}

final _rideIdPattern = RegExp(r'^[A-Za-z0-9-]{1,64}$');

/// Where a card link opens in the app: the trip's chat for Chat, else the
/// trip's page with the button's action to run there (`?card=call`). The
/// driver's trip page for a driver's card. Null for any other link.
String? tripCardLinkLocation(Uri uri) {
  if (uri.scheme.toLowerCase() != 'getride' || uri.host.toLowerCase() != 'trip') return null;
  final segs = [
    for (final s in uri.pathSegments)
      if (s.isNotEmpty) s,
  ];
  if (segs.length != 1 || !_rideIdPattern.hasMatch(segs.single)) return null;
  final id = segs.single;
  final driver = uri.queryParameters['as'] == 'driver';
  final base = driver ? '/drive/trip/$id' : '/ride/$id';
  final action = TripCardAction.parse(uri.queryParameters['do']);
  if (action == null || action == TripCardAction.rate) return base;
  if (action == TripCardAction.chat) return '$base/chat';
  return '$base?card=${action.name}';
}
