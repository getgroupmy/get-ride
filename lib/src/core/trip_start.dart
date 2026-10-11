// Starting a trip (Phase D0, migration 0152): the driver enters the
// passenger's 4-digit code and the server checks it (start_trip). What the
// server answered, and what the driver is told. Pure.

sealed class TripStartOutcome {
  const TripStartOutcome();
}

class TripStarted extends TripStartOutcome {
  const TripStarted();
}

class TripWrongCode extends TripStartOutcome {
  const TripWrongCode();
}

class TripTooManyTries extends TripStartOutcome {
  const TripTooManyTries(this.wait);
  final Duration wait;
}

/// `start_trip`'s answer: `on_trip`, `wrong_code` or `rate_limited:<seconds>`.
/// Anything else is taken as started: the server only answers otherwise to
/// refuse, and refusing is what the two named answers are for.
TripStartOutcome tripStartOutcome(Object? reply) {
  final s = '${reply ?? ''}'.trim();
  if (s == 'wrong_code') return const TripWrongCode();
  if (s.startsWith('rate_limited:')) {
    final secs = int.tryParse(s.substring('rate_limited:'.length)) ?? 600;
    return TripTooManyTries(Duration(seconds: secs < 1 ? 1 : secs));
  }
  return const TripStarted();
}

/// What the driver is told when the trip didn't start; null when it did.
String? tripStartMessage(TripStartOutcome o) => switch (o) {
  TripStarted() => null,
  TripWrongCode() => 'That code is not correct. Ask the passenger to check it in their app.',
  TripTooManyTries(:final wait) =>
    'Too many wrong codes. Try again in ${(wait.inSeconds / 60).ceil()} min, or ask the passenger to contact support.',
};

/// A code the driver may send: four digits, spaces ignored.
String? cleanTripCode(String? input) {
  final s = (input ?? '').replaceAll(RegExp(r'\s'), '');
  return RegExp(r'^[0-9]{4}$').hasMatch(s) ? s : null;
}
