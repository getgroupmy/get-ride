// Booking rules (migration 0107): a rider has one ride of their own on the
// go at a time, and may book any number for other people, one per
// passenger. Pure.
import '../data/models.dart';

/// Who a ride is booked for, when it is not the rider.
typedef BookedFor = ({String name, String phone});

/// What the database answers a second request with.
const duplicateRideError = 'RIDE_REQUEST_DUPLICATE';

/// A request refused because the rider already has one on the go: nothing
/// was stored and nothing was sent to drivers.
class DuplicateRideRequest implements Exception {
  const DuplicateRideRequest({required this.forOthers});
  final bool forOthers;

  @override
  String toString() => forOthers
      ? 'You already have a ride on the go for this passenger.'
      : 'You already have a ride request on the go. Only one can be sent at a time.';
}

bool isDuplicateRideError(Object? message) => '${message ?? ''}'.contains(duplicateRideError);

/// The number as stored: `+` and digits.
String cleanBookForPhone(String raw) {
  final s = raw.trim().replaceAll(RegExp(r'[^\d+]'), '');
  final plus = s.startsWith('+');
  final digits = s.replaceAll('+', '');
  return digits.isEmpty ? '' : '${plus ? '+' : ''}$digits';
}

/// Why the passenger's details can't be booked, or null when they can.
String? bookForProblem(String name, String phone) {
  final n = name.trim();
  if (n.isEmpty) return "Enter the passenger's name.";
  if (n.length > 80) return 'The name is too long.';
  final digits = cleanBookForPhone(phone).replaceAll('+', '');
  if (digits.length < 6 || digits.length > 15) return "Enter the passenger's phone number.";
  return null;
}

/// The details to book with, or null while they are incomplete.
BookedFor? bookedFor(String name, String phone) =>
    bookForProblem(name, phone) == null ? (name: name.trim(), phone: cleanBookForPhone(phone)) : null;

/// The rider's own ride on the go, out of their rides on the go (newest
/// first). Rides booked for others never block a booking of their own.
RideRequest? ownRide(Iterable<RideRequest> onTheGo) => onTheGo.where((r) => !r.isForOthers).firstOrNull;

/// The rides on the go that the rider booked for other people.
List<RideRequest> ridesForOthers(Iterable<RideRequest> onTheGo) => onTheGo.where((r) => r.isForOthers).toList();
