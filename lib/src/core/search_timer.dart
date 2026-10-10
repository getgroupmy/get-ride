// The rider's wait for a driver (Expo `ride-confirm` search): the first
// minute counts down to a "Raise your fare?" prompt, the request runs out
// after [AppConfig.requestExpiry], and a driver's offer stands for
// [counterOfferWindow] from when the rider first saw it. Pure.
import 'dart:math' as math;

/// How long the first search phase lasts before the rider is asked once
/// whether to raise the fare (Expo's 60-second countdown).
const searchPromptAfter = Duration(seconds: 60);

/// What that prompt offers to add (Expo raises by 5).
const searchPromptRaise = 5.0;

/// Time since the request went out, never negative (a device clock behind
/// the server's would otherwise start the search in the future).
Duration searchElapsed(DateTime? createdAt, DateTime now) {
  if (createdAt == null) return Duration.zero;
  final d = now.difference(createdAt);
  return d.isNegative ? Duration.zero : d;
}

/// The first-minute bar: 1 when the search starts, 0 at [searchPromptAfter].
double searchPhaseProgress(Duration elapsed) =>
    (1 - elapsed.inMilliseconds / searchPromptAfter.inMilliseconds).clamp(0.0, 1.0).toDouble();

/// Whether to ask "Raise your fare?" now: the first minute is up, no driver
/// has offered anything, and the rider hasn't been asked on this screen.
bool shouldPromptRaise({required Duration elapsed, required bool offerStanding, required bool alreadyAsked}) =>
    !alreadyAsked && !offerStanding && elapsed >= searchPromptAfter;

/// What is left of the request's life (zero once it has run out).
Duration searchTimeLeft(Duration elapsed, Duration expiry) {
  final left = expiry - elapsed;
  return left.isNegative ? Duration.zero : left;
}

/// `6:05`: minutes and zero-padded seconds, rounding up so it never reads
/// 0:00 while time is left.
String formatCountdown(Duration d) {
  final total = (d.inMilliseconds / 1000).ceil();
  return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
}

/// The offer card's bar: 1 when the offer appears, 0 when its window ends.
double offerProgress(Duration shownFor, Duration window) =>
    math.max(0, 1 - shownFor.inMilliseconds / window.inMilliseconds).toDouble();

/// Whether an offer has been on screen longer than its window; the rider
/// side stops showing it (the bidder's own app withdraws it at the same time).
bool offerLapsed(Duration shownFor, Duration window) => shownFor >= window;

/// Whether a request the rider was waiting on has just run out with nobody
/// taking it ([before] open, [after] expired), wherever that was decided:
/// this screen, another screen, or the server's every-minute job (0139).
bool requestJustExpired(String? before, String after) => before == 'open' && after == 'expired';
