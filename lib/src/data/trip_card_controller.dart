// Keeps the trip card (core/trip_card.dart) on the phone in step with the
// signed-in person's trip: the rider's ride on the go, or the driver's own
// trip. It follows the ride row live, builds the card for its stage, and
// starts, moves and ends the phone's card (data/trip_card_platform.dart):
//   * a new stage is sent at once, a move within a stage at most every
//     [tripCardUpdateEvery];
//   * the done card stays Admin → Display Settings → Trip card's minutes,
//     then goes (0 clears it at once); a cancelled ride's goes at once;
//   * a service switched off there shows no card (and takes one down);
//   * nothing at all on the web or a desktop.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/demo_mode.dart' show isDemoRideId;
import '../core/page_styles.dart';
import '../core/trip_card.dart';
import '../providers.dart';
import 'app_display_repository.dart';
import 'models.dart';
import 'page_styles_repository.dart';
import 'ride_repository.dart';
import 'trip_card_platform.dart';

/// Where the controller finds the trip to show.
abstract class TripCardSource {
  /// The rider's own ride on the go, or null.
  Future<RideRequest?> riderRide();

  /// The driver's trip in progress, or null.
  Future<RideRequest?> driverTrip();

  /// The ride's row, live.
  Stream<RideRequest> watch(String rideId);
}

class RepositoryTripCardSource implements TripCardSource {
  const RepositoryTripCardSource(this._repo);
  final RideRepository _repo;

  @override
  Future<RideRequest?> riderRide() => _repo.ongoingForRider();

  @override
  Future<RideRequest?> driverTrip() => _repo.ongoingForPartner();

  @override
  Stream<RideRequest> watch(String rideId) => _repo.watch(rideId);
}

final tripCardSourceProvider = Provider<TripCardSource>(
  (ref) => RepositoryTripCardSource(ref.watch(rideRepositoryProvider)),
);

/// Admin → Display Settings → Trip card; null until the settings are read.
final tripCardSettingsProvider = Provider<TripCardSettings?>((ref) {
  final blob = ref.watch(displaySettingsBlobProvider).value;
  return blob == null ? null : TripCardSettings.fromDisplay(blob);
});

/// The card's colours from App Page Settings → Trip card ([tripCardSurface]).
TripCardColors tripCardColorsOf(PageStyles styles, Brightness b) {
  final tokens = elementTokens[tripCardSurface]!;
  int c(String key, int fallback) =>
      styles.color(tripCardSurface, SurfaceKind.sheet, tokenNamed(tokens, key), b)?.toARGB32() ?? fallback;
  const d = TripCardColors();
  return TripCardColors(
    background: c('cardBackground', d.background),
    accent: c('cardAccent', d.accent),
    text: c('cardText', d.text),
    muted: c('cardMuted', d.muted),
  );
}

/// The card's colours for a phone in light and in dark mode.
final tripCardColorsProvider = Provider<({TripCardColors light, TripCardColors dark})>((ref) {
  final styles = ref.watch(pageStylesProvider).value ?? PageStyles.none;
  return (light: tripCardColorsOf(styles, Brightness.light), dark: tripCardColorsOf(styles, Brightness.dark));
});

/// The road routes the trip maps fetched, by ride (live_ride_map.dart), so
/// the card's minutes match the map's.
class TripRouteFeed extends Notifier<Map<String, TripRouteFix>> {
  @override
  Map<String, TripRouteFix> build() => const {};

  void put(String rideId, TripRouteFix route) => state = {...state, rideId: route};
}

final tripRouteFeedProvider = NotifierProvider<TripRouteFeed, Map<String, TripRouteFix>>(TripRouteFeed.new);

/// The controller's clock (a test sets its own).
final tripCardClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

class TripCardController extends Notifier<TripCard?> {
  StreamSubscription<RideRequest>? _sub;
  String? _rideId;
  RideRequest? _ride;

  /// Whether the phone is showing the card now.
  bool _shown = false;
  DateTime? _sentAt;
  TripCardStage? _sentStage;
  Timer? _flush;
  Timer? _doneTimer;
  bool _refreshing = false;

  /// The furthest the bar got in each stage of each ride.
  final _furthest = <String, double>{};

  TripCardPlatform get _platform => ref.read(tripCardPlatformProvider);

  @override
  TripCard? build() {
    ref.onDispose(_dispose);
    if (!ref.read(tripCardPlatformProvider).supported) return null;
    ref.listen<String?>(currentUserIdProvider, (before, id) {
      if (before == id) return;
      _finish();
      unawaited(refresh());
    });
    ref.listen(tripCardSettingsProvider, (_, _) => _render(force: true));
    ref.listen(tripCardColorsProvider, (_, _) => _render(force: true));
    ref.listen(tripRouteFeedProvider, (_, _) => _render());
    Future.microtask(refresh);
    return null;
  }

  /// The ride the card follows, if any.
  String? get rideId => _rideId;

  /// Looks for the signed-in person's trip: the driver's own first, else
  /// the rider's. Called at start, at sign-in, when the app comes back and
  /// when a push about a ride arrives. A live trip already followed is kept.
  Future<void> refresh() async {
    if (!_platform.supported || _refreshing) return;
    final live = _ride;
    if (live != null && live.status.isOngoing) return;
    _refreshing = true;
    try {
      if (ref.read(currentUserIdProvider) == null) {
        _finish();
        return;
      }
      final source = ref.read(tripCardSourceProvider);
      RideRequest? found;
      try {
        found = await source.driverTrip() ?? await source.riderRide();
      } catch (_) {
        return;
      }
      if (found != null) follow(found.id, ride: found);
    } finally {
      _refreshing = false;
    }
  }

  /// Follows [rideId] (the trip on screen, or the one [refresh] found),
  /// taking down the card of any other.
  void follow(String rideId, {RideRequest? ride}) {
    if (!_platform.supported || isDemoRideId(rideId)) return;
    if (rideId == _rideId) {
      if (ride != null) _onRide(ride);
      return;
    }
    // An old trip opened from the history leaves the live one's card alone.
    if (ride != null && !ride.status.isOngoing && (_ride?.status.isOngoing ?? false)) return;
    _finish();
    _rideId = rideId;
    _sub = ref.read(tripCardSourceProvider).watch(rideId).listen(_onRide, onError: (Object _) {});
    if (ride != null) _onRide(ride);
  }

  void _onRide(RideRequest r) {
    if (r.id != _rideId) return;
    final before = _ride;
    _ride = r;
    _render(force: before == null || before.status != r.status);
  }

  void _render({bool force = false}) {
    final r = _ride;
    if (r == null) return;
    final settings = ref.read(tripCardSettingsProvider);
    if (settings == null) return;
    final uid = ref.read(currentUserIdProvider);
    final asDriver = uid != null && r.partnerId == uid && r.riderId != uid;
    if (!settings.allows(TripCardService.of(r), asDriver: asDriver)) {
      // Kept following: the admin may switch it back on.
      _hide();
      return;
    }
    final stage = TripCardStage.of(r.status);
    if (stage == null) {
      _finish();
      return;
    }
    final now = ref.read(tripCardClockProvider)();
    if (stage == TripCardStage.done) {
      final until = tripCardDoneUntil(completedAt: r.completedAt, now: now, doneMinutes: settings.doneMinutes);
      if (settings.doneMinutes == 0 || !until.isAfter(now)) {
        _finish();
        return;
      }
      _doneTimer?.cancel();
      _doneTimer = Timer(until.difference(now), _finish);
    }
    final eta = tripEta(r, route: ref.read(tripRouteFeedProvider)[r.id]);
    var card = buildTripCard(r, asDriver: asDriver, now: now, eta: eta, fraction: tripStageFraction(r, kmLeft: eta?.km));
    if (card == null) {
      _hide();
      return;
    }
    final key = '${r.id}:${card.stage.name}';
    final progress = monotonicProgress(_furthest[key], card.progress, sameStage: true);
    _furthest[key] = progress;
    card = card.copyWith(progress: progress);
    state = card;
    if (force || tripCardSendDue(now: now, lastSentAt: _sentAt, lastStage: _sentStage, stage: card.stage)) {
      _flush?.cancel();
      _flush = null;
      unawaited(_send(card, settings, now));
    } else if (_flush == null) {
      // The latest move goes out once the gap has passed.
      final wait = _sentAt!.add(tripCardUpdateEvery).difference(now);
      _flush = Timer(wait.isNegative ? Duration.zero : wait, () {
        _flush = null;
        _render();
      });
    }
  }

  Future<void> _send(TripCard card, TripCardSettings settings, DateTime now) async {
    final colors = ref.read(tripCardColorsProvider);
    final map = card.toPlatform(
      light: colors.light,
      dark: colors.dark,
      clearAfter: Duration(minutes: settings.doneMinutes),
    );
    _sentAt = now;
    _sentStage = card.stage;
    final platform = _platform;
    if (_shown && await platform.update(map)) return;
    final shown = await platform.start(map);
    // Ended or switched to another ride meanwhile: not this card's turn.
    if (_rideId != card.rideId) {
      if (shown) await platform.end(card.rideId);
      return;
    }
    _shown = shown;
  }

  /// Takes the card down but keeps following the ride.
  void _hide() {
    final id = _rideId;
    _flush?.cancel();
    _flush = null;
    _doneTimer?.cancel();
    _doneTimer = null;
    if (_shown && id != null) unawaited(_platform.end(id));
    _shown = false;
    _sentAt = null;
    _sentStage = null;
    if (state != null) state = null;
  }

  /// Takes the card down and stops following the ride.
  void _finish() {
    _hide();
    unawaited(_sub?.cancel());
    _sub = null;
    final id = _rideId;
    if (id != null) _furthest.removeWhere((k, _) => k.startsWith('$id:'));
    _rideId = null;
    _ride = null;
  }

  void _dispose() {
    _flush?.cancel();
    _doneTimer?.cancel();
    unawaited(_sub?.cancel());
  }
}

final tripCardControllerProvider = NotifierProvider<TripCardController, TripCard?>(TripCardController.new);
